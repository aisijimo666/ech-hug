#!/bin/sh

# ================= 配置 =================
ARGO_DOMAIN="${ARGO_DOMAIN:-}"
ARGO_AUTH="${ARGO_AUTH:-}"
# ⭐ 固定隧道模式：metrics 端口必须与 ECH 端口不同
# ECH 使用 8001（Cloudflare 控制台配置），metrics 改用 8003
ARGO_PORT="${ARGO_PORT:-8003}"
IPS="${IPS:-4}"
OPERA="${OPERA:-0}"
COUNTRY="${COUNTRY:-AM}"

# ================= 工具 =================
get_free_port() {
    random=$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')
    echo $(( ( random % 20000 ) + 10000 ))
}

# ================= 隧道设置（后台运行）=================
setup_tunnel() {
    echo "--- 清理旧二进制 ---"
    rm -f ech-server-linux opera-linux cloudflared-linux

    echo "--- 下载二进制 ---"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)
            ECH_URL="https://github.com/webappstars/ech-hug/releases/download/3.0/ech-tunnel-linux-amd64"
            #ECH_URL="https://github.com/aisijimo666/x-tunnel-smux/releases/download/x-tunnel20260324/x-tunnel-linux-amd64"
            OPERA_URL="https://github.com/Alexey71/opera-proxy/releases/download/v1.16.0/opera-proxy.linux-amd64"
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
            ;;
        i386|i686)
            ECH_URL="https://github.com/webappstars/ech-hug/releases/download/3.0/ech-tunnel-linux-386"
            #ECH_URL="https://github.com/aisijimo666/x-tunnel-smux/releases/download/x-tunnel20260324/x-tunnel-linux-386"
            OPERA_URL="https://github.com/Alexey71/opera-proxy/releases/download/v1.16.0/opera-proxy.linux-386"
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386"
            ;;
        arm64|aarch64)
            ECH_URL="https://github.com/webappstars/ech-hug/releases/download/3.0/ech-tunnel-linux-arm64"
            #ECH_URL="https://github.com/aisijimo666/x-tunnel-smux/releases/download/x-tunnel20260324/x-tunnel-linux-arm64"
            OPERA_URL="https://github.com/Alexey71/opera-proxy/releases/download/v1.16.0/opera-proxy.linux-arm64"
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
            ;;
        * )
            echo "❌ 不支持的架构: $ARCH"
            return 1
            ;;
    esac

    curl -fsSL --retry 2 --connect-timeout 10 --max-time 120 "$ECH_URL" -o ech-server-linux || { echo "❌ 下载 ECH 失败"; return 1; }
    if [ "$OPERA" = "1" ]; then
        curl -fsSL --retry 2 --connect-timeout 10 --max-time 120 "$OPERA_URL" -o opera-linux || { echo "❌ 下载 Opera 失败"; return 1; }
        chmod +x opera-linux
    fi
    curl -fsSL --retry 2 --connect-timeout 10 --max-time 120 "$CLOUDFLARED_URL" -o cloudflared-linux || { echo "❌ 下载 Cloudflared 失败"; return 1; }
    chmod +x ech-server-linux cloudflared-linux

    # ================= 端口 =================
    # ⭐ 固定隧道模式必须使用固定端口（因为 Cloudflare 控制台配置了具体端口）
    if [ -n "$ARGO_AUTH" ]; then
        # 固定隧道：使用固定端口 8001（与 Cloudflare 控制台配置一致）
        WSPORT=8000
        ECHPORT=8001
        echo "WS: $WSPORT  ECH: $ECHPORT (固定端口模式)"
    else
        # 快速隧道：使用随机端口
        WSPORT=${WSPORT:-$(get_free_port)}
        ECHPORT=$((WSPORT + 1))
        echo "WS: $WSPORT  ECH: $ECHPORT"
    fi

    # ================= Opera =================
    if [ "$OPERA" = "1" ]; then
        COUNTRY=$(echo "$COUNTRY" | tr 'a-z' 'A-Z')
        operaport=$(get_free_port)
        echo "启动 Opera Proxy (port:$operaport, country:$COUNTRY)"
        nohup ./opera-linux -country "$COUNTRY" -socks-mode \
            -bind-address "127.0.0.1:$operaport" >/dev/null 2>&1 &
    fi

    # ================= ECH =================
    sleep 1
    ECH_ARGS="./ech-server-linux -l ws://0.0.0.0:$ECHPORT"
    [ -n "$TOKEN" ] && ECH_ARGS="$ECH_ARGS -token $TOKEN"
    [ "$OPERA" = "1" ] && ECH_ARGS="$ECH_ARGS -f socks5://127.0.0.1:$operaport"

    echo "启动 ECH Server..."
    nohup sh -c "$ECH_ARGS" >/dev/null 2>&1 &

    i=0
    while [ $i -lt 15 ]; do
        (bash -c "echo >/dev/tcp/127.0.0.1/$ECHPORT" 2>/dev/null) && break
        sleep 1
        i=$((i+1))
    done

    if [ $i -eq 15 ]; then
        echo "❌ ECH 未监听端口 $ECHPORT"
        return 1
    fi

    # ================= Cloudflared =================
    echo "启动 Cloudflared..."
    CLOUDFLARED_LOG="/tmp/cloudflared.log"
    ARGO_ARGS="--protocol http2"

    # ⭐ 关键区分：固定隧道 vs 快速隧道
    if [ -n "$ARGO_AUTH" ]; then
        # 【固定隧道模式】支持两种认证格式
        # 格式1: JSON credentials file（新版本）
        # 格式2: 单字符串 token（旧版本）
        
        # ⭐ 必须配置域名才能使用固定隧道
        if [ -z "$ARGO_DOMAIN" ]; then
            echo "❌ 固定隧道模式需要配置 ARGO_DOMAIN"
            echo "   请在 Replit Secrets 中添加 ARGO_DOMAIN=你的域名"
            return 1
        fi
        
        # 检测 ARGO_AUTH 是否为 JSON 格式
        if echo "$ARGO_AUTH" | grep -q '^{' 2>/dev/null; then
            # JSON 格式：写入 credentials file
            ARGO_AUTH_FILE="/tmp/argo_auth.json"
            echo "$ARGO_AUTH" > "$ARGO_AUTH_FILE"
            chmod 600 "$ARGO_AUTH_FILE"
            ARGO_ARGS="$ARGO_ARGS --credentials-file $ARGO_AUTH_FILE"
            echo "使用 JSON credentials 格式"
        else
            # Token 格式：直接使用 --token 参数
            ARGO_ARGS="$ARGO_ARGS --token $ARGO_AUTH"
            echo "使用 Token 格式"
        fi
        
        # 固定隧道使用 tunnel run 命令
        # ⭐ 注意：新版本 cloudflared 不再支持 --hostname 参数
        # 域名路由在 Cloudflare Zero Trust 控制台配置，cloudflared 只负责连接隧道
        
        echo "启动 Cloudflared (固定隧道模式)..."
        # ⭐ 添加调试信息
        echo "  Token 格式: $(echo "$ARGO_AUTH" | cut -c1-30)..."
        echo "  目标域名: $ARGO_DOMAIN"
        echo "  ECH 端口: $ECHPORT"
        echo "  网络测试..."
        curl -s -o /dev/null -w "  Cloudflare API: %{http_code}\n" --connect-timeout 5 https://api.cloudflare.com 2>/dev/null || echo "  Cloudflare API: 连接失败"
        
        env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
            nohup ./cloudflared-linux \
            --metrics "127.0.0.1:$ARGO_PORT" \
            tunnel \
            run \
            $ARGO_ARGS \
            --url "127.0.0.1:$ECHPORT" \
            >"$CLOUDFLARED_LOG" 2>&1 &
        CF_PID=$!
        echo "  cloudflared PID: $CF_PID"
        
        # 等待进程启动
        sleep 2
        if ! kill -0 $CF_PID 2>/dev/null; then
            echo "❌ cloudflared 进程启动失败！"
            echo "  查看日志: cat $CLOUDFLARED_LOG"
            return 1
        fi
        echo "  cloudflared 已启动，等待连接..."
    else
        # 【快速隧道模式】使用 tunnel --url
        echo "启动 Cloudflared (快速隧道模式)..."
        env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
            nohup ./cloudflared-linux \
            --metrics "127.0.0.1:$ARGO_PORT" \
            tunnel \
            --url "127.0.0.1:$ECHPORT" \
            $ARGO_ARGS \
            >"$CLOUDFLARED_LOG" 2>&1 &
    fi

    sleep 3

    # ================= 获取域名 =================
    if [ -n "$ARGO_DOMAIN" ]; then
        TUNNEL_DOMAIN="$ARGO_DOMAIN"
    else
        for i in $(seq 1 30); do
            TUNNEL_DOMAIN=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$CLOUDFLARED_LOG" | head -n 1)
            [ -n "$TUNNEL_DOMAIN" ] && break
            TUNNEL_DOMAIN=$(curl -s --connect-timeout 2 --max-time 3 \
                "http://127.0.0.1:$ARGO_PORT/metrics" \
                | grep 'userHostname=' \
                | sed -E 's/.*userHostname="([^"]+)".*/\1/')
            [ -n "$TUNNEL_DOMAIN" ] && break
            sleep 1
        done
    fi

    if [ -z "$TUNNEL_DOMAIN" ]; then
        echo "⚠️  获取隧道域名失败，Node.js 服务仍在运行"
        return 0
    fi

    echo "✓ 隧道域名: $TUNNEL_DOMAIN"

    # ================= 写入页面 =================
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

# ================= main =================
# 清除旧的隧道页面，避免显示过期域名
rm -f ./tunnel_index.html

# 后台运行隧道设置
setup_tunnel &

# 立即启动 Node.js（保证健康检查通过）
echo "--- 启动 Node.js 服务器 ---"
# 使用 pwd 获取当前工作目录（兼容 dash/sh）
exec node "$(pwd)/server.js"
