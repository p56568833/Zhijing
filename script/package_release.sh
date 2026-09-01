#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Zhijing"
DISPLAY_NAME="知境"
BUNDLE_ID="com.zhijing.app"
APP_VERSION="0.3.3"
BUILD_NUMBER="7"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$OUTPUT_DIR/$DISPLAY_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
DMG_PATH="$OUTPUT_DIR/Zhijing-$APP_VERSION-universal.dmg"
STAGING_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.build/ModuleCache"

cd "$ROOT_DIR"
swift build -c release --arch arm64 --arch x86_64
BUILD_BINARY="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
rm -f "$DMG_PATH"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$ROOT_DIR/Assets/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
chmod +x "$APP_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleDisplayName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSMultipleInstancesProhibited</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Markdown 文稿</string>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>LSHandlerRank</key>
      <string>Owner</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>net.daringfireball.markdown</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key>
      <string>SRT 字幕文件</string>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>com.zhijing.srt</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key>
      <string>纯文本文稿</string>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>com.zhijing.txt</string>
      </array>
    </dict>
  </array>
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key>
      <string>net.daringfireball.markdown</string>
      <key>UTTypeDescription</key>
      <string>Markdown 文稿</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.plain-text</string>
      </array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array>
          <string>md</string>
          <string>markdown</string>
        </array>
        <key>public.mime-type</key>
        <string>text/markdown</string>
      </dict>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key>
      <string>com.zhijing.srt</string>
      <key>UTTypeDescription</key>
      <string>SRT 字幕文件</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.plain-text</string>
      </array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <string>srt</string>
        <key>public.mime-type</key>
        <string>application/x-subrip</string>
      </dict>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key>
      <string>com.zhijing.txt</string>
      <key>UTTypeDescription</key>
      <string>纯文本文稿</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.plain-text</string>
      </array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <string>txt</string>
        <key>public.mime-type</key>
        <string>text/plain</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

cp -R "$APP_BUNDLE" "$STAGING_DIR/$DISPLAY_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create \
  -volname "$DISPLAY_NAME $APP_VERSION" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

lipo -info "$APP_BINARY"
shasum -a 256 "$DMG_PATH"
