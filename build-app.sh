#!/bin/bash
# 编译 release 并打包成 dist/MoBar.app
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="MoBar"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "==> swift build -c release"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/$APP_NAME"
if [[ ! -x "$BIN" ]]; then
	echo "构建产物不存在: $BIN" >&2
	exit 1
fi

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 本地自签，让系统把它当同一个身份，TCC 授权和登录项不会每次重置
echo "==> ad-hoc 签名"
codesign --force --sign - --timestamp=none "$APP" >/dev/null

echo
echo "打包完成: $APP"
echo
echo "试跑（前台，Ctrl-C 退出，带调试输出）:"
echo "  MOBAR_DEBUG=1 $APP/Contents/MacOS/$APP_NAME"
echo
echo "安装到应用目录:"
echo "  cp -R $APP /Applications/"
echo
echo "开机自启：系统设置 > 通用 > 登录项 里添加 /Applications/$APP_NAME.app"
