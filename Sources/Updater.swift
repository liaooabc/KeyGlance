import AppKit
import Combine
import Foundation

/// 键览自己的更新。唯一可信来源是仓库的 latest release：tag 就是版本号，附件是 zip
/// （将来换成 dmg 也能装）。和 Sparkle 那套精简版一样，装新版不覆盖正在运行的包：
/// 下载 → 解开验包（bundle id + 版本号）→ 拷到暂存区 → 交给一个小脚本，等本进程退出后
/// 「备份旧包 → 放新包 → 重新打开」，失败就回滚。
@MainActor
final class Updater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(version: String)
        case available(version: String, downloadURL: String?, pageURL: String, notes: String)
        case downloading(version: String, progress: Double)
        case installing(version: String)
        case failed(message: String)
    }

    static let shared = Updater()
    static let repo = "liaooabc/KeyGlance"
    static let releasesPage = "https://github.com/\(repo)/releases"
    static let latestPage = "https://github.com/\(repo)/releases/latest"

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastCheckDate: Date?

    private let lastCheckKey = "lastUpdateCheck"

    private init() {
        lastCheckDate = UserDefaults.standard.object(forKey: lastCheckKey) as? Date
    }

    // MARK: - 当前版本

    var currentVersion: String {
        // 调试用：KEYGLANCE_FAKE_VERSION=1.0.0 假装本机是旧版，看「有新版本」长什么样
        if let fake = ProcessInfo.processInfo.environment["KEYGLANCE_FAKE_VERSION"], !fake.isEmpty {
            return Version.normalized(fake)
        }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    var versionLine: String { "\(currentVersion)（\(currentBuild)）" }

    var pendingVersion: String? {
        if case let .available(version, _, _, _) = phase { return version }
        return nil
    }

    var isChecking: Bool { phase == .checking }

    var isBusy: Bool {
        switch phase {
        case .downloading, .installing: return true
        default: return false
        }
    }

    // MARK: - 检查

    /// 启动时调用：距上次检查不到一天就不打扰。
    func checkIfStale() {
        if let last = lastCheckDate, Date().timeIntervalSince(last) < 24 * 3600 { return }
        check(automatic: true)
    }

    func check(automatic: Bool = false) {
        guard !isChecking, !isBusy else { return }
        phase = .checking

        Task { [weak self] in
            guard let self else { return }
            let result = await Self.fetchLatestRelease()
            switch result {
            case .failure(let error):
                // 自动检查失败就安静着，别把几个小时前的网络错误留在设置里
                self.phase = automatic ? .idle : .failed(message: error.message)
            case .success(let release):
                self.lastCheckDate = Date()
                UserDefaults.standard.set(Date(), forKey: self.lastCheckKey)

                guard Version.isNewer(release.version, than: self.currentVersion) else {
                    self.phase = .upToDate(version: release.version)
                    return
                }
                self.phase = .available(version: release.version,
                                        downloadURL: release.downloadURL,
                                        pageURL: release.pageURL,
                                        notes: release.notes)
                if SettingsStore.shared.automaticallyInstallsUpdates, release.downloadURL != nil {
                    self.install()
                }
            }
        }
    }

    private struct Release {
        let version: String
        let pageURL: String
        let downloadURL: String?
        let notes: String
    }

    private struct FetchError: Error { let message: String }

    private static func fetchLatestRelease() async -> Result<Release, FetchError> {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            return .failure(FetchError(message: "更新地址不正确。"))
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("KeyGlance/\(Updater.shared.currentVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(FetchError(message: "检查失败（没有收到响应）。"))
            }
            if http.statusCode == 403 || http.statusCode == 429 {
                return .failure(FetchError(message: "GitHub 接口被限流了，过一会儿再试。"))
            }
            if http.statusCode == 404 {
                return .failure(FetchError(message: "仓库里还没有发布版本。"))
            }
            guard http.statusCode == 200 else {
                return .failure(FetchError(message: "检查失败（HTTP \(http.statusCode)）。"))
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = object["tag_name"] as? String else {
                return .failure(FetchError(message: "检查失败（拿不到发布信息）。"))
            }

            let version = Version.normalized(tag)
            let page = object["html_url"] as? String ?? latestPage
            let notes = (object["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let assets = object["assets"] as? [[String: Any]] ?? []

            func assetURL(suffix: String) -> String? {
                assets.first { (($0["name"] as? String) ?? "").lowercased().hasSuffix(suffix) }
                    .flatMap { $0["browser_download_url"] as? String }
            }
            // 首选 zip，其次 dmg；两个都没有就只给发布页
            let download = assetURL(suffix: ".zip") ?? assetURL(suffix: ".dmg")
            return .success(Release(version: version, pageURL: page, downloadURL: download, notes: notes))
        } catch {
            return .failure(FetchError(message: "网络不可用（\(error.localizedDescription)）"))
        }
    }

    // MARK: - 安装

    func install() {
        guard case let .available(version, url, _, _) = phase, let url, !isBusy else { return }
        phase = .downloading(version: version, progress: 0)

        Task { [weak self] in
            guard let self else { return }
            do {
                let archive = try await Self.download(url) { ratio in
                    Task { @MainActor in
                        if case let .downloading(v, _) = self.phase {
                            self.phase = .downloading(version: v, progress: ratio)
                        }
                    }
                }
                self.phase = .installing(version: version)
                try self.stageAndHandOff(archive: archive, expectedVersion: version)
                // 脚本在等本进程退出，给它一点时间接手再退
                try? await Task.sleep(nanoseconds: 300_000_000)
                NSApp.terminate(nil)
            } catch {
                let message = (error as? UpdateError)?.message ?? error.localizedDescription
                self.phase = .failed(message: message)
                Self.presentFailure(message)
            }
        }
    }

    /// 解包 → 校验 → 拷到暂存区 → 写替换脚本 → 起脚本（脚本先等我们退出）
    private func stageAndHandOff(archive: URL, expectedVersion: String) throws {
        let fm = FileManager.default
        let runningApp = URL(fileURLWithPath: Bundle.main.bundlePath)

        // Gatekeeper 的「随机路径」运行（AppTranslocation）替换不了，直接说清楚
        if runningApp.path.contains("AppTranslocation") {
            throw UpdateError("这个 App 是从压缩包或磁盘映像里直接运行的，没法自动替换。请先把「键览」拖进「应用程序」再试。")
        }
        // 目标目录不可写就别等到退出后才失败（那时候 App 已经没了）
        let targetDir = runningApp.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: targetDir.path) else {
            throw UpdateError("没有权限写入 \(targetDir.path)。请把「键览」放进「应用程序」，或用下面的「打开下载页」手动安装。")
        }

        let work = fm.temporaryDirectory.appendingPathComponent("kg-unpack-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let lower = archive.path.lowercased()
        var newApp: URL?
        if lower.hasSuffix(".zip") {
            try Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, work.path])
            newApp = Self.findApp(in: work)
        } else if lower.hasSuffix(".dmg") {
            let mount = work.appendingPathComponent("mnt", isDirectory: true)
            try fm.createDirectory(at: mount, withIntermediateDirectories: true)
            try Self.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                              "-mountpoint", mount.path, archive.path])
            defer { try? Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
            newApp = Self.findApp(in: mount)
        }
        guard let newApp else {
            throw UpdateError("下载到的安装包里没有找到 App，可能下到了错误的文件。")
        }

        // 包身份 + 版本都要对得上才敢装
        guard let bundle = Bundle(url: newApp),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError("下载到的 App 不是键览（bundle id 对不上），已中止。")
        }
        let gotVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard Version.compare(gotVersion, expectedVersion) != .orderedAscending else {
            throw UpdateError("下载到的是 \(gotVersion)，不是 \(expectedVersion)，已中止。")
        }

        // 暂存（拷出来，压缩包就可以删了）
        let stagingDir = Self.supportDir.appendingPathComponent("Update", isDirectory: true)
        try? fm.removeItem(at: stagingDir)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let staging = stagingDir.appendingPathComponent("新版.app")
        try Self.run("/usr/bin/ditto", [newApp.path, staging.path])
        try? fm.removeItem(at: archive)

        // 替换脚本：等本进程退出 → 备份 → 放新包 → 重新打开；任何一步失败都回滚并重新打开旧的
        let backup = stagingDir.appendingPathComponent("旧版备份.app")
        let script = fm.temporaryDirectory.appendingPathComponent("kg-update-\(UUID().uuidString.prefix(8)).sh")
        let body = """
        #!/bin/bash
        # 键览自动替换脚本（App 退出后执行）
        APP="$1"; NEW="$2"; BACKUP="$3"; PID="$4"
        n=0
        while /bin/kill -0 "$PID" 2>/dev/null; do
          /bin/sleep 0.2
          n=$((n+1)); [ "$n" -gt 150 ] && break
        done
        /bin/sleep 0.6
        /bin/rm -rf "$BACKUP"
        if ! /bin/mv "$APP" "$BACKUP"; then
          /usr/bin/open "$APP" 2>/dev/null
          exit 1
        fi
        if /usr/bin/ditto "$NEW" "$APP"; then
          /usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null
          /usr/bin/open "$APP"
          /bin/rm -rf "$BACKUP" "$NEW"
        else
          /bin/rm -rf "$APP"
          /bin/mv "$BACKUP" "$APP"
          /usr/bin/open "$APP"
          exit 2
        fi
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, runningApp.path, staging.path, backup.path,
                             String(ProcessInfo.processInfo.processIdentifier)]
        try process.run()
    }

    /// 解出来的目录里找 App（兼容「外面还套了一层文件夹」的压缩包）
    private static func findApp(in directory: URL, depth: Int = 0) -> URL? {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let visible = items.filter { !$0.lastPathComponent.hasPrefix("__MACOSX") && !$0.lastPathComponent.hasPrefix(".") }
        if let app = visible.first(where: { $0.pathExtension == "app" }) { return app }
        guard depth < 2 else { return nil }
        for folder in visible where folder.hasDirectoryPath {
            if let found = findApp(in: folder, depth: depth + 1) { return found }
        }
        return nil
    }

    // MARK: - 下载

    private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private var continuation: CheckedContinuation<URL, Error>?
        private var onProgress: ((Double) -> Void)?
        private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

        func fetch(_ url: URL, onProgress: @escaping (Double) -> Void) async throws -> URL {
            self.onProgress = onProgress
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                session.downloadTask(with: url).resume()
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            // 这个方法返回后临时文件就没了，必须当场搬走
            let suffix = downloadTask.response?.suggestedFilename
                .flatMap { ($0 as NSString).pathExtension } ?? "zip"
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("KeyGlance-\(UUID().uuidString.prefix(8)).\(suffix.isEmpty ? "zip" : suffix)")
            do {
                try FileManager.default.moveItem(at: location, to: dest)
                continuation?.resume(returning: dest)
            } catch {
                continuation?.resume(throwing: error)
            }
            continuation = nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error, continuation != nil else { return }
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    private static func download(_ urlString: String, onProgress: @escaping (Double) -> Void) async throws -> URL {
        guard let url = URL(string: urlString) else { throw UpdateError("下载地址不正确。") }
        do {
            let file = try await Downloader().fetch(url, onProgress: onProgress)
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            guard size > 100 * 1024 else { throw UpdateError("下载下来的文件太小（\(size) 字节），可能不是安装包。") }
            return file
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError("下载失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 小工具

    struct UpdateError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("KeyGlance", isDirectory: true)
    }

    fileprivate static func run(_ tool: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) 出错（\(process.terminationStatus)）：\(text)")
        }
    }

    /// 失败一律用系统警告框说清楚原因（这几步都可能被权限、磁盘、网络挡下）
    private static func presentFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "更新没有装成功"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// 发布说明：设置里「发布说明」按钮，长文本用滚动框显示
    func presentReleaseNotes() {
        guard case let .available(version, _, page, notes) = phase else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "键览 \(version) 发布说明"
        alert.informativeText = notes.isEmpty ? "这个版本没有附带说明。" : ""

        if !notes.isEmpty {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 220))
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
            scroll.drawsBackground = false
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false
            text.drawsBackground = false
            text.font = .systemFont(ofSize: 11.5)
            text.textColor = .labelColor
            text.string = notes
            text.textContainerInset = NSSize(width: 2, height: 6)
            scroll.documentView = text
            alert.accessoryView = scroll
        }

        alert.addButton(withTitle: "打开 GitHub")
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: page) {
            NSWorkspace.shared.open(url)
        }
    }
}
