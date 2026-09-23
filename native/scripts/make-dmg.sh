#!/bin/bash
# 生成带 Applications 快捷方式的安装 dmg（发版用；日常测试只跑 make-app.sh 即可）
# 用法：scripts/make-dmg.sh  → ../dist/release/Sotto-<版本>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/make-app.sh

VERSION=$(grep -A1 CFBundleShortVersionString build/Sotto.app/Contents/Info.plist | grep string | sed -E 's/.*<string>(.*)<\/string>.*/\1/')
STAGING=build/dmg-staging

rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R build/Sotto.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

mkdir -p ../dist/release
hdiutil create -volname Sotto -srcdir "$STAGING" -ov -format UDZO "../dist/release/Sotto-$VERSION.dmg"
echo "dmg 完成: ../dist/release/Sotto-$VERSION.dmg"
