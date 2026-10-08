#!/bin/bash
# 编译 release 并打包成 dist/MoBar.app
#
#   ./build-app.sh              只编当前架构，开发用，快
#   ./build-app.sh --universal  出 arm64 + x86_64 通用二进制，发布用
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="MoBar"
DIST="dist"
APP="$DIST/$APP_NAME.app"
UNIVERSAL=0
[[ "${1:-}" == "--universal" ]] && UNIVERSAL=1

# 签名身份。自签证书（./create-signing-identity.sh 生成一次）的 designated requirement
# 是证书指纹，重建后辅助功能授权和登录项都继续有效；机器上没有这个身份就退回 ad-hoc。
SIGN_IDENTITY="${MOBAR_SIGN_IDENTITY:-MoBar Local Signing}"

# SwiftPM 的 --arch 双架构要走 xcbuild，只装命令行工具时不可用，
# 所以这里分别按 triple 编两遍再 lipo 合并。
ARM_TRIPLE="arm64-apple-macosx13.0"
X86_TRIPLE="x86_64-apple-macosx13.0"

mkdir -p "$DIST"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ $UNIVERSAL -eq 1 ]]; then
	echo "==> swift build -c release ($ARM_TRIPLE)"
	swift build -c release --triple "$ARM_TRIPLE"
	echo "==> swift build -c release ($X86_TRIPLE)"
	swift build -c release --triple "$X86_TRIPLE"

	ARM_BIN="$(swift build -c release --triple "$ARM_TRIPLE" --show-bin-path)/$APP_NAME"
	X86_BIN="$(swift build -c release --triple "$X86_TRIPLE" --show-bin-path)/$APP_NAME"
	for bin in "$ARM_BIN" "$X86_BIN"; do
		[[ -x "$bin" ]] || { echo "构建产物不存在: $bin" >&2; exit 1; }
	done

	echo "==> lipo 合并"
	lipo -create -output "$APP/Contents/MacOS/$APP_NAME" "$ARM_BIN" "$X86_BIN"
else
	echo "==> swift build -c release"
	swift build -c release
	BIN="$(swift build -c release --show-bin-path)/$APP_NAME"
	[[ -x "$BIN" ]] || { echo "构建产物不存在: $BIN" >&2; exit 1; }
	cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
fi

echo "==> 组装 $APP"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if compgen -G "Resources/*.icns" > /dev/null; then
	cp Resources/*.icns "$APP/Contents/Resources/"
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$SIGN_IDENTITY\""; then
	echo "==> 用 \"$SIGN_IDENTITY\" 签名"
	codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP" >/dev/null
else
	echo "==> 没有 \"$SIGN_IDENTITY\" 证书，退回 ad-hoc 签名"
	echo "    ad-hoc 的 DR 是 cdhash，重建后要重新给辅助功能授权；想换成固定身份跑 ./create-signing-identity.sh"
	codesign --force --sign - --timestamp=none "$APP" >/dev/null
fi

echo
echo "打包完成: $APP  ($(lipo -archs "$APP/Contents/MacOS/$APP_NAME"))"
echo
echo "试跑（前台，Ctrl-C 退出，带调试输出）:"
echo "  MOBAR_DEBUG=1 $APP/Contents/MacOS/$APP_NAME"
echo
echo "安装到应用目录:"
echo "  cp -R $APP /Applications/"
echo
echo "开机自启：系统设置 > 通用 > 登录项 里添加 /Applications/$APP_NAME.app"
