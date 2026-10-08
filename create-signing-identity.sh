#!/bin/bash
# 创建并导入本地代码签名用的自签证书（登录钥匙串，身份名固定）
#
#   ./create-signing-identity.sh
#
# 为什么要它：ad-hoc 签名（codesign --sign -）的 designated requirement 是 cdhash，
# 每次重新构建都会变，于是辅助功能授权（还有登录项）每次重建都要重新弄一遍。
# 换成一个固定的自签证书后，DR 变成证书指纹，重建不再影响授权。
#
# 证书和私钥留在本机 ~/Library/Application Support/MoBar/signing/；证书已存在就直接复用，
# 所以钥匙串被清空后重跑本脚本拿到的还是同一个身份。导入用的 p12 口令每次随机生成、不落盘。
set -euo pipefail

cd "$(dirname "$0")"

IDENTITY="${MOBAR_SIGN_IDENTITY:-MoBar Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
CERT_DIR="$HOME/Library/Application Support/MoBar/signing"
CERT="$CERT_DIR/mobar.cert.pem"
KEY="$CERT_DIR/mobar.key.pem"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -qF "\"$IDENTITY\""; then
	echo "签名身份 \"$IDENTITY\" 已存在，无需重建"
	exit 0
fi

mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"

if [[ -f "$CERT" && -f "$KEY" ]]; then
	echo "==> 复用已有证书 $CERT"
else
	echo "==> 生成自签代码签名证书（\"$IDENTITY\"，RSA 2048，10 年）"
	# 扩展项写进配置文件而不是命令行 -addext，LibreSSL 也认
	cat > "$CERT_DIR/openssl.cnf" <<EOF
[ req ]
default_md = sha256
prompt = no
distinguished_name = dn
x509_extensions = codesign

[ dn ]
CN = $IDENTITY
O = MoBar Local Signing

[ codesign ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
	openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
		-keyout "$KEY" -out "$CERT" -config "$CERT_DIR/openssl.cnf"
	chmod 600 "$KEY"
fi

echo "==> 导入登录钥匙串（允许 codesign 直接用私钥，不弹密码框）"
P12_PASS="$(openssl rand -hex 16)"
# openssl 3 默认的 p12 加密 macOS 的 security 读不了，这里指定 3DES/SHA1
openssl pkcs12 -export -inkey "$KEY" -in "$CERT" -name "$IDENTITY" \
	-passout "pass:$P12_PASS" -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
	-out "$CERT_DIR/mobar.p12"
security import "$CERT_DIR/mobar.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
	-T /usr/bin/codesign -T /usr/bin/security >/dev/null
rm -f "$CERT_DIR/mobar.p12"

# 自签证书默认不受信任，不标记的话 codesign 看不到这个身份（CSSMERR_TP_NOT_TRUSTED）。
# 只对代码签名策略设信任，不动 ssl / smime 那些。
echo "==> 设为受信任的代码签名证书"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$CERT"

if ! security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -qF "\"$IDENTITY\""; then
	echo "导入后仍找不到可用身份，检查一下 $CERT" >&2
	exit 1
fi

echo
echo "完成：$(security find-identity -v -p codesigning "$KEYCHAIN" | grep -F "\"$IDENTITY\"" | sed 's/^ *//')"
echo "证书与私钥：$CERT_DIR"
echo "现在 ./build-app.sh 会自动用它签名。"
