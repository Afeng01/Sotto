#!/bin/bash
# 打包原生 Sotto.app（ad-hoc 签名，未公证）
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/Sotto.app
if [ -e "$APP" ]; then trash "$APP"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Sotto "$APP/Contents/MacOS/Sotto"
# 更新日志：拷进 Resources，设置窗「更新日志」页运行时读 Bundle resource
#（发版只改仓库根部 CHANGELOG.md，不硬编码进 Swift）
cp ../CHANGELOG.md "$APP/Contents/Resources/CHANGELOG.md"

# 图标：复用 resources/icon.png 生成 icns
SRC=../resources/icon.png
ICONSET=build/icon.iconset
if [ -e "$ICONSET" ]; then trash "$ICONSET"; fi
mkdir -p "$ICONSET"
sips -z 16 16     "$SRC" --out "$ICONSET/icon_16x16.png"     >/dev/null
sips -z 32 32     "$SRC" --out "$ICONSET/icon_16x16@2x.png"  >/dev/null
sips -z 32 32     "$SRC" --out "$ICONSET/icon_32x32.png"     >/dev/null
sips -z 64 64     "$SRC" --out "$ICONSET/icon_32x32@2x.png"  >/dev/null
sips -z 128 128   "$SRC" --out "$ICONSET/icon_128x128.png"   >/dev/null
sips -z 256 256   "$SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$SRC" --out "$ICONSET/icon_256x256.png"   >/dev/null
sips -z 512 512   "$SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$SRC" --out "$ICONSET/icon_512x512.png"   >/dev/null
sips -z 1024 1024 "$SRC" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Sotto</string>
    <key>CFBundleIdentifier</key><string>com.luming.sotto.native</string>
    <key>CFBundleName</key><string>Sotto</string>
    <key>CFBundleDisplayName</key><string>呦呦</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>0.2.7</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key><string>呦呦（Sotto）需要访问麦克风进行语音识别</string>
    <key>NSAppleEventsUsageDescription</key><string>呦呦（Sotto）需要向当前应用发送粘贴指令以输出语音文本</string>
</dict>
</plist>
PLIST

# 稳定签名身份「Sotto Dev」：TCC 权限（麦克风/辅助功能）绑定代码签名，
# 固定证书让重编译后权限不再重置；无证书环境回退 ad-hoc
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Sotto Dev' | sed -E 's/^[[:space:]]*[0-9]+[)] ([A-F0-9]+) .*/\1/')
codesign --force --deep -s "${IDENTITY:--}" "$APP" 2>/dev/null || codesign --force --deep -s - "$APP" 2>/dev/null
echo "打包完成: $PWD/$APP"
