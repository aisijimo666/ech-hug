#!/usr/bin/env bash
set -u

ARGO_DOMAIN="${ARGO_DOMAIN:-}"
ARGO_AUTH="${ARGO_AUTH:-}"
ARGO_PORT="${ARGO_PORT:-8003}"
IPS="${IPS:-4}"
OPERA="${OPERA:-0}"
COUNTRY="${COUNTRY:-AM}"
APP_PORT="${PORT:-8080}"

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$WORKDIR" || exit 1

get_free_port() {
    local random
    if [ -r /dev/urandom ]; then
        random=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' ')
    fi
    if [ -z "${random:-}" ]; then
        random=$(( ($$ * 1103515245 + 12345) & 65535 ))
    fi
    echo $(( (random % 20000) + 10000 ))
}

check_port() {
    local host="$1"
    local port="$2"
    (echo >/dev/tcp/"$host"/"$port") >/dev/null 2>&1
}

setup_tunnel() {
    echo "=== [Tunnel] 开始初始化 ==="
    echo "[Tunnel] uname -a: $(uname -a 2>&1 || true)"

    rm -f ech-server-linux opera-linux cloudflared-linux

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)
            ECH_URL="https://github.com/webappstars/ech-hug/releases/download/3.0/ech-tunnel-linux-amd64"
            OPERA_URL="https://github.com/Alexey71/opera-proxy/releases/download/v1.16.0/opera-proxy.linux-amd64"
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
            ;;
        i386|i686)
            ECH_URL="https://github.com/webappstars/ech-hug/releases/download/3.0/ech-tunnel-linux-386"
            OPERA_URL="https://github.com/Alexey71/opera-proxy/releases/download/v1.16.0/opera-proxy.linux-386"
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386"
            ;;
        arm64|aarch64)
            ECH_URL="https://github.com/webappstars/ech-hug/releases/download/3.0/ech-tunnel-linux-arm64"
            OPERA_URL="https://github.com/Alexey71/opera-proxy/releases/download/v1.16.0/opera-proxy.linux-arm64"
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
            ;;
        *)
            echo "[Tunnel] ❌ 不支持的架构: $ARCH"
            return 1
            ;;
    esac

    if ! command -v curl >/dev/null 2>&1; then
        echo "[Tunnel] ❌ 缺少 curl 命令"
        return 1
    fi

    echo "[Tunnel] 下载 ECH: $ECH_URL"
    if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 120 "$ECH_URL" -o ech-server-linux; then
        echo "[Tunnel] ❌ 下载 ECH 失败"
        return 1
    fi

    if [ "$OPERA" = "1" ]; then
        echo "[Tunnel] 下载 Opera: $OPERA_URL"
        if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 120 "$OPERA_URL" -o opera-linux; then
            echo "[Tunnel] ❌ 下载 Opera 失败"
            return 1
        fi
        chmod +x opera-linux || true
    fi

    echo "[Tunnel] 下载 Cloudflared: $CLOUDFLARED_URL"
    if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 120 "$CLOUDFLARED_URL" -o cloudflared-linux; then
        echo "[Tunnel] ❌ 下载 Cloudflared 失败"
        return 1
    fi

    chmod +x ech-server-linux cloudflared-linux || true
    ls -lh ech-server-linux cloudflared-linux || true

    if [ -n "$ARGO_AUTH" ]; then
        WSPORT=8000
        ECHPORT=8001
        echo "[Tunnel] WS: $WSPORT  ECH: $ECHPORT (固定端口模式)"
    else
        WSPORT=${WSPORT:-$(get_free_port)}
        ECHPORT=$((WSPORT + 1))
        echo "[Tunnel] WS: $WSPORT  ECH: $ECHPORT"
    fi

    if [ "$OPERA" = "1" ]; then
        COUNTRY=$(echo "$COUNTRY" | tr 'a-z' 'A-Z')
        operaport=$(get_free_port)
        echo "[Tunnel] 启动 Opera Proxy (port:$operaport, country:$COUNTRY)"
        ./opera-linux -country "$COUNTRY" -socks-mode -bind-address "127.0.0.1:$operaport" 2>&1 | sed 's/^/[Opera] /' &
    fi

    sleep 1
    ECH_ARGS="./ech-server-linux -l ws://0.0.0.0:$ECHPORT"
    [ -n "${TOKEN:-}" ] && ECH_ARGS="$ECH_ARGS -token $TOKEN"
    [ "$OPERA" = "1" ] && ECH_ARGS="$ECH_ARGS -f socks5://127.0.0.1:$operaport"

    echo "[Tunnel] 启动 ECH Server: $ECH_ARGS"
    bash -c "$ECH_ARGS" 2>&1 | sed 's/^/[ECH] /' &
    ECH_PID=$!

    i=0
    while [ $i -lt 15 ]; do
        check_port "127.0.0.1" "$ECHPORT" && break
        sleep 1
        i=$((i + 1))
    done

    if [ $i -eq 15 ]; then
        echo "[Tunnel] ❌ ECH 未监听端口 $ECHPORT (PID=$ECH_PID)"
        return 1
    fi
    echo "[Tunnel] ✓ ECH 已监听 127.0.0.1:$ECHPORT"

    CLOUDFLARED_LOG="/tmp/cloudflared.log"
    : > "$CLOUDFLARED_LOG"
    ARGO_ARGS="--protocol http2"

    if [ -n "$ARGO_AUTH" ]; then
        if [ -z "$ARGO_DOMAIN" ]; then
            echo "[Tunnel] ❌ 固定隧道模式需要配置 ARGO_DOMAIN"
            return 1
        fi

        if echo "$ARGO_AUTH" | grep -q '^{' 2>/dev/null; then
            ARGO_AUTH_FILE="/tmp/argo_auth.json"
            echo "$ARGO_AUTH" > "$ARGO_AUTH_FILE"
            chmod 600 "$ARGO_AUTH_FILE" || true
            ARGO_ARGS="$ARGO_ARGS --credentials-file $ARGO_AUTH_FILE"
        else
            ARGO_ARGS="$ARGO_ARGS --token $ARGO_AUTH"
        fi

        echo "[Tunnel] 启动 Cloudflared (固定隧道模式)..."
        env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
            ./cloudflared-linux --metrics "127.0.0.1:$ARGO_PORT" tunnel run $ARGO_ARGS --url "127.0.0.1:$ECHPORT" \
            >"$CLOUDFLARED_LOG" 2>&1 &
        CF_PID=$!
    else
        echo "[Tunnel] 启动 Cloudflared (快速隧道模式)..."
        env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
            ./cloudflared-linux --metrics "127.0.0.1:$ARGO_PORT" tunnel --url "127.0.0.1:$ECHPORT" $ARGO_ARGS \
            >"$CLOUDFLARED_LOG" 2>&1 &
        CF_PID=$!
    fi

    sleep 3
    if ! kill -0 "$CF_PID" 2>/dev/null; then
        echo "[Tunnel] ❌ cloudflared 进程已退出，日志如下："
        cat "$CLOUDFLARED_LOG" 2>/dev/null || true
        return 1
    fi

    if [ -n "$ARGO_DOMAIN" ]; then
        TUNNEL_DOMAIN="$ARGO_DOMAIN"
    else
        for _ in $(seq 1 30); do
            TUNNEL_DOMAIN=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$CLOUDFLARED_LOG" 2>/dev/null | head -n 1 || true)
            [ -n "$TUNNEL_DOMAIN" ] && break
            TUNNEL_DOMAIN=$(curl -s --connect-timeout 2 --max-time 3 \
                "http://127.0.0.1:$ARGO_PORT/metrics" 2>/dev/null \
                | grep 'userHostname=' \
                | sed -E 's/.*userHostname="([^"]+)".*/\1/' || true)
            [ -n "$TUNNEL_DOMAIN" ] && break
            sleep 1
        done
    fi

    if [ -z "$TUNNEL_DOMAIN" ]; then
        echo "[Tunnel] ⚠️ 未能获取到 trycloudflare.com 域名，cloudflared 日志："
        cat "$CLOUDFLARED_LOG" 2>/dev/null || true
        return 0
    fi

    echo "[Tunnel] ✓ 隧道域名: $TUNNEL_DOMAIN"

    cat > ./tunnel_index.html <<EOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<title>Tunnel Ready</title>
</head>
<body style="background:#020617;color:#e5e7eb;display:flex;align-items:center;justify-content:center;height:100vh">
<div>
<h1>🚀 Tunnel 已就绪</h1>
<p>$TUNNEL_DOMAIN</p>
</div>
</body>
</html>
EOF
}

rm -f ./tunnel_index.html
setup_tunnel 2>&1 | sed 's/^/[Setup] /' &

echo "--- 启动 Node.js 服务器 (PORT=${APP_PORT}) ---"
export PORT="$APP_PORT"
exec node "$WORKDIR/server.js"
