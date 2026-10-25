#!/bin/bash
# Builds KeyGlance.app (arm64; --universal adds x86_64), generates the icon and optionally installs it.
# Usage: ./build.sh [--install] [--universal]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/KeyGlance.app"
BUNDLE_ID="com.hushixiong.KeyGlance"
SDK="$(xcrun --show-sdk-path)"
SWIFTC="swiftc"
TARGET_MIN="26.0"

echo "==> SDK: $SDK"
echo "==> Swift: $($SWIFTC --version | head -1)"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/obj"

# ---------- icon (Icon Composer package -> Assets.car) ----------
if [ ! -f "$ROOT/Resources/Assets.car" ]; then
  echo "==> Building icon"
  "$SWIFTC" -O "$ROOT/Tools/makeicon.swift" -o "$BUILD/makeicon"
  "$BUILD/makeicon" "$BUILD/AppIcon.icon"
  mkdir -p "$BUILD/iconout"
  xcrun actool "$BUILD/AppIcon.icon" \
    --compile "$BUILD/iconout" \
    --platform macosx \
    --minimum-deployment-target 26.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$BUILD/iconout/partial.plist" > /dev/null
  cp "$BUILD/iconout/Assets.car" "$ROOT/Resources/Assets.car"
  cp "$BUILD/iconout/AppIcon.icns" "$ROOT/Resources/AppIcon.icns"
fi
cp "$ROOT/Resources/Assets.car" "$APP/Contents/Resources/Assets.car"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# ---------- sources ----------
SRC=("$ROOT"/Sources/*.swift)
build_arch() {
  local arch="$1"
  echo "==> Compiling $arch"
  "$SWIFTC" -swift-version 5 -O -whole-module-optimization \
    -target "$arch-apple-macos$TARGET_MIN" -sdk "$SDK" \
    -module-name KeyGlance \
    "${SRC[@]}" \
    -o "$BUILD/obj/KeyGlance-$arch" \
    -framework AppKit -framework SwiftUI -framework Combine -framework ServiceManagement -framework ApplicationServices
}
# Apple-silicon only: an arm64-only binary is what keeps Finder's Get Info
# from offering "Open using Rosetta" and makes the app smaller. Pass
# --universal to also embed an x86_64 slice (for Intel Macs).
build_arch arm64
cp "$BUILD/obj/KeyGlance-arm64" "$APP/Contents/MacOS/KeyGlance"
if [ "${UNIVERSAL:-0}" = "1" ] || [[ " $* " == *" --universal "* ]]; then
  build_arch x86_64
  lipo -create "$BUILD/obj/KeyGlance-arm64" "$BUILD/obj/KeyGlance-x86_64" \
    -output "$APP/Contents/MacOS/KeyGlance"
fi
chmod +x "$APP/Contents/MacOS/KeyGlance"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# ---------- sign ----------
codesign --force --options runtime --sign - --timestamp=none "$APP" 2>/dev/null || codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "==> Signature OK"

# refresh Launch Services so the icon shows up
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true

echo "==> Built $APP"

if [[ " $* " == *" --install "* ]]; then
  echo "==> Installing to /Applications"
  osascript -e 'tell application "KeyGlance" to quit' >/dev/null 2>&1 || true
  pkill -x KeyGlance 2>/dev/null || true
  sleep 0.4
  rm -rf "/Applications/KeyGlance.app"
  ditto "$APP" "/Applications/KeyGlance.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/KeyGlance.app" >/dev/null 2>&1 || true
  echo "==> Installed /Applications/KeyGlance.app"
fi
