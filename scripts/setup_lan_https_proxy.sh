#!/bin/bash
# 为局域网访问生成本机 HTTPS 反向代理配置。
#
# 服务端刻意只监听 127.0.0.1，而且会话 Cookie 带 `Secure`——所以"把监听地址改成
# 0.0.0.0"得到的是一个能连上但登录不进去的服务（LAN IP 不是安全上下文，浏览器
# 不会存 Secure cookie）。唯一被支持的远程路径是：本机反向代理终止 TLS，再转发
# 到回环服务。
#
# 这个脚本只生成证书与配置，不启动任何东西、不改系统设置。
#
#   scripts/setup_lan_https_proxy.sh [--https-port 8443] [--server-port 8098] [--out <目录>]
#
# 生成完成后按输出的两个环境变量启动 MediaLibServer，再启动代理。

set -euo pipefail

HTTPS_PORT=8443
SERVER_PORT=8098
OUT_DIR="$HOME/Library/Application Support/MediaLib/lan-proxy"

while [ $# -gt 0 ]; do
  case "$1" in
    --https-port) HTTPS_PORT="$2"; shift 2 ;;
    --server-port) SERVER_PORT="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

command -v openssl >/dev/null 2>&1 || { echo "error: 需要 openssl" >&2; exit 2; }

# 取当前活动网卡的 IPv4。Wi-Fi 通常是 en0，有线/雷电网卡可能是 en1。
LAN_IP=""
for interface in en0 en1 en2; do
  candidate=$(ipconfig getifaddr "$interface" 2>/dev/null || true)
  if [ -n "$candidate" ]; then LAN_IP="$candidate"; break; fi
done
if [ -z "$LAN_IP" ]; then
  echo "error: 没有找到局域网 IPv4 地址；请确认已连接网络。" >&2
  exit 1
fi
HOST_NAME="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"
CERT="$OUT_DIR/medialib-lan.crt"
KEY="$OUT_DIR/medialib-lan.key"

if [ -f "$CERT" ] && [ -f "$KEY" ]; then
  echo "复用已有证书: $CERT"
else
  echo "生成自签名证书（SAN 覆盖 IP 与主机名，否则 Safari/iOS 会直接拒绝）…"
  # IP 必须同时进 SAN 的 IP 字段：只写 DNS 名的证书在用 IP 访问时无效。
  openssl req -x509 -newkey rsa:2048 -sha256 -days 825 -nodes \
    -keyout "$KEY" -out "$CERT" \
    -subj "/CN=MediaLIB LAN ($LAN_IP)" \
    -addext "subjectAltName=IP:$LAN_IP,IP:127.0.0.1,DNS:$HOST_NAME.local,DNS:localhost" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" 2>/dev/null
  chmod 600 "$KEY"
fi

PUBLIC_ORIGIN="https://$LAN_IP:$HTTPS_PORT"

# --- Caddy ---------------------------------------------------------------
# 转发头必须逐字精确。`HTTPRequestSecurityPolicy` 的规则是：
#   * Host 必须等于公开 Origin 的 host:port  → 保留原始 Host（Caddy 默认行为）
#   * 必须有且只有一个 `X-Forwarded-Proto: https`
#   * 出现 `X-Forwarded-Host` 或 `Forwarded` 一律 403 → Caddy 默认会加前者，必须删
#   * `X-Forwarded-For` 若出现，必须是单个 IPv4 → IPv6 客户端会被 403，因此这里
#     直接删掉它。代价是逐客户端限速退化为按代理计数（见脚本末尾说明）。
cat > "$OUT_DIR/Caddyfile" <<CADDY
{
	admin off
	auto_https off
}

$PUBLIC_ORIGIN {
	tls $CERT $KEY

	reverse_proxy 127.0.0.1:$SERVER_PORT {
		header_up X-Forwarded-Proto https
		header_up -X-Forwarded-Host
		header_up -X-Forwarded-For
		header_up -Forwarded

		# 媒体是长连接的 Range 流，默认的短超时会把播放切断。
		transport http {
			read_timeout 0
			write_timeout 0
		}
	}
}
CADDY

# --- nginx ---------------------------------------------------------------
cat > "$OUT_DIR/medialib-lan.nginx.conf" <<NGINX
# nginx -c "$OUT_DIR/medialib-lan.nginx.conf"
worker_processes 1;
error_log $OUT_DIR/nginx-error.log;
pid $OUT_DIR/nginx.pid;
events { worker_connections 256; }
http {
    access_log off;
    server {
        listen $HTTPS_PORT ssl;
        server_name $LAN_IP;
        ssl_certificate     $CERT;
        ssl_certificate_key $KEY;

        location / {
            proxy_pass http://127.0.0.1:$SERVER_PORT;
            # 保留原始 Host；补 XFP；确保不出现 X-Forwarded-Host / Forwarded /
            # X-Forwarded-For，三者任一出现或格式不符都会被服务端 403。
            proxy_set_header Host \$http_host;
            proxy_set_header X-Forwarded-Proto https;
            proxy_set_header X-Forwarded-Host "";
            proxy_set_header X-Forwarded-For "";
            proxy_set_header Forwarded "";

            proxy_http_version 1.1;
            proxy_buffering off;          # Range 流式转发，不要整段缓冲
            proxy_read_timeout 1h;
            proxy_send_timeout 1h;
            client_max_body_size 16m;
        }
    }
}
NGINX

cat <<INFO

已生成到：$OUT_DIR
  证书    medialib-lan.crt / medialib-lan.key（SAN: IP:$LAN_IP, DNS:$HOST_NAME.local）
  Caddy   Caddyfile
  nginx   medialib-lan.nginx.conf

1) 用这两个环境变量启动服务端（缺任何一个都会退回纯回环）：

   MEDIALIB_SERVER_PUBLIC_ORIGIN="$PUBLIC_ORIGIN"
   MEDIALIB_SERVER_TRUSTED_PROXIES="127.0.0.1"

   也可以在 App 的「设置 → 服务模式」里填同样两项。

2) 启动代理（二选一）：

   caddy run --config "$OUT_DIR/Caddyfile"
   nginx -c "$OUT_DIR/medialib-lan.nginx.conf"

   都没装的话：brew install caddy

3) 局域网设备访问 $PUBLIC_ORIGIN
   首次会提示证书不受信任：把 medialib-lan.crt 传到设备并信任它。
   iOS 需要"安装描述文件"后再到「设置 → 通用 → 关于本机 → 证书信任设置」里手动启用。

注意：配置里删掉了 X-Forwarded-For。服务端只接受单个 IPv4 格式的该头，
IPv6 客户端会被 403——那看起来就跟"还是访问不了"一样。代价是逐客户端限速
会退化为按代理地址计数；在家庭局域网可接受，公网暴露前必须重新处理。
INFO
