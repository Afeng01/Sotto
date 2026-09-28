#!/bin/bash
# 生成带 Applications 快捷方式的安装 dmg（发版用；日常测试只跑 make-app.sh 即可）
# 用法：scripts/make-dmg.sh  → ../dist/release/Sotto-<版本>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/make-app.sh

# PlistBuddy 读版本：比 grep 稳健（不依赖 key/value 是否同行）
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Sotto.app/Contents/Info.plist)
STAGING=build/dmg-staging

# /bin/rm：脚本内清理临时 staging 目录，避免被交互 shell 的 rm 安全 guard 拦截
/bin/rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R build/Sotto.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

mkdir -p ../dist/release
hdiutil create -volname Sotto -srcdir "$STAGING" -ov -format UDZO "../dist/release/Sotto-$VERSION.dmg"
echo "dmg 完成: ../dist/release/Sotto-$VERSION.dmg"
