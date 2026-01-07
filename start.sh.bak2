#!/bin/bash
set -e

# HF 必须外部监听 7860
WSPORT=${WSPORT:-7860}
ECHPORT=$((WSPORT + 1))
export WSPORT ECHPORT

# 下载 ech 二进制（按架构）
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|x64|amd64)
    ECH_URL="https://github.com/webappstars/ech-hug/releases/download/3.0/ech-tunnel-linux-amd64"
    ;;
  i386|i686)
    ECH_URL="https://github.com/webappstars/ech-hug/releases/download/3.0/ech-tunnel-linux-386"
    ;;
  armv8|arm64|aarch64)
    ECH_URL="https://github.com/webappstars/ech-hug/releases/download/3.0/ech-tunnel-linux-arm64"
    ;;
  *)
    echo "不支持架构: $ARCH"
    exit 1
    ;;
esac

echo "--- Download ECH ---"
curl -fL "$ECH_URL" -o /app/ech-server-linux
chmod +x /app/ech-server-linux

echo "--- Start ECH (port: $ECHPORT) ---"
ECH_ARGS=(/app/ech-server-linux -l "ws://0.0.0.0:$ECHPORT")
if [ -n "$TOKEN" ]; then
  ECH_ARGS+=(-token "$TOKEN")
  echo "ECH token enabled"
fi

# 后台跑 ECH
nohup "${ECH_ARGS[@]}" > /app/ech.log 2>&1 &
ECH_PID=$!

# 简单存活检查
sleep 1
if ! kill -0 "$ECH_PID" 2>/dev/null; then
  echo "ERROR: ECH 启动失败"
  tail -n 50 /app/ech.log || true
  exit 1
fi

echo "--- Start Caddy (port: $WSPORT) ---"
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
