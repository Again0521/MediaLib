#!/usr/bin/env bash
# 在登录钥匙串中确保存在一个“稳定的本地自签名代码签名证书”，并把它的名字打印到 stdout。
#
# 背景：临时(ad-hoc, `codesign --sign -`)签名的 App 每次构建甚至每次启动都会让 macOS 把它当成
# 新身份，导致系统照片(Photos)/通知等 TCC 授权无法持久化，用户每次打开都要重新授权。
# 用一个固定身份(固定 CN 的自签名证书)签名后，TCC 授权会按“证书指定要求”持久保存，
# 跨重新打包/重新安装都只需授权一次。
#
# 该脚本是幂等的：证书已存在时直接复用，不会重复创建。
# 失败时返回非 0，并且不打印身份名——调用方应据此回退到 ad-hoc 签名。
#
# 可选环境变量：
#   LOCAL_CODESIGN_NAME      证书 CN，默认 "Movilune Local Codesign"
#   LOGIN_KEYCHAIN_PASSWORD  登录钥匙串密码；提供后可免去 codesign 首次使用时的钥匙串授权弹窗。
set -euo pipefail

IDENTITY_NAME="${LOCAL_CODESIGN_NAME:-Movilune Local Codesign}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# 老系统可能仍是 login.keychain（无 -db 后缀）。
if [[ ! -f "$KEYCHAIN" && -f "$HOME/Library/Keychains/login.keychain" ]]; then
  KEYCHAIN="$HOME/Library/Keychains/login.keychain"
fi

log() { printf '%s\n' "$*" >&2; }

# 已经有同名代码签名身份就直接复用。
# 注意：自签名证书未被信任，`find-identity -v`(仅“有效”)看不到它，但 codesign 仍可用它签名，
# 因此这里用不带 -v 的列表（包含未受信任身份）来判断是否已存在。
if security find-identity -p codesigning 2>/dev/null | grep -qF "$IDENTITY_NAME"; then
  printf '%s\n' "$IDENTITY_NAME"
  exit 0
fi

if ! command -v openssl >/dev/null 2>&1; then
  log "ensure_local_signing_identity: 未找到 openssl，无法创建自签名证书。"
  exit 1
fi

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

P12_PASS="medialib-local"

cat > "$WORK/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions    = v3_codesign
prompt             = no
[dn]
CN = ${IDENTITY_NAME}
[v3_codesign]
basicConstraints   = critical,CA:FALSE
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
CNF

log "ensure_local_signing_identity: 正在创建本地自签名代码签名证书「${IDENTITY_NAME}」…"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -config "$WORK/openssl.cnf" >/dev/null 2>&1
openssl pkcs12 -export -legacy \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$IDENTITY_NAME" -out "$WORK/identity.p12" \
  -passout "pass:${P12_PASS}" >/dev/null 2>&1 \
  || openssl pkcs12 -export \
       -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
       -name "$IDENTITY_NAME" -out "$WORK/identity.p12" \
       -passout "pass:${P12_PASS}" >/dev/null 2>&1

# 导入私钥+证书，并授权 codesign 使用该私钥。
if ! security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
      -T /usr/bin/codesign -T /usr/bin/security >/dev/null 2>&1; then
  log "ensure_local_signing_identity: 导入证书到钥匙串失败。"
  exit 1
fi

# 设置分区列表，避免 codesign 首次使用私钥时弹出钥匙串授权框；需要登录钥匙串密码。
if [[ -n "${LOGIN_KEYCHAIN_PASSWORD:-}" ]]; then
  security set-key-partition-list -S apple-tool:,apple: -s \
    -k "$LOGIN_KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 || true
else
  log "ensure_local_signing_identity: 提示——首次用该证书签名时，钥匙串可能弹一次授权框，"
  log "  请点「始终允许」(Always Allow)。或在运行前设置 LOGIN_KEYCHAIN_PASSWORD 环境变量免弹窗。"
fi

if security find-identity -p codesigning 2>/dev/null | grep -qF "$IDENTITY_NAME"; then
  printf '%s\n' "$IDENTITY_NAME"
  exit 0
fi

log "ensure_local_signing_identity: 证书创建后仍不可用于代码签名。"
exit 1
