#!/bin/bash
set -e

# 獲取一個隨機端口
get_free_port() {
    echo $(( ( RANDOM % 20000 ) + 10000 ))
}

# 執行核心服務啟動邏輯
quicktunnel() {
    # --- START: 插入的 DNS 設定程式碼 ---
    echo "--- 正在強制設定 DNS 為 1.1.1.1/1.0.0.1 ---"
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 1.0.0.1" >> /etc/resolv.conf
    # --- END: 插入的 DNS 設定程式碼 ---

    echo "--- 正在下載服務二進制文件 ---"

    local ARCH
    ARCH=$(uname -m)

    local ECH_URL=""
    local OPERA_URL=""
    local CLOUDFLARED_URL=""

    case "$ARCH" in
        x86_64 | x64 | amd64 )
            ECH_URL="https://github.com/webappstars/ech-hug/releases/download/3.0/ech-tunnel-linux-amd64"
            OPERA_URL="https://github.com/Snawoot/opera-proxy/releases/latest/download/opera-proxy.linux-amd64"
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
            ;;
        i386 | i686 )
            ECH_URL="https://github.com/webappstars/ech-hug/releases/download/3.0/ech-tunnel-linux-386"
            OPERA_URL="https://github.com/Snawoot/opera-proxy/releases/latest/download/opera-proxy.linux-386"
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386"
            ;;
        armv8 | arm64 | aarch64 )
            ECH_URL="https://github.com/webappstars/ech-hug/releases/download/3.0/ech-tunnel-linux-arm64"
            OPERA_URL="https://github.com/Snawoot/opera-proxy/releases/latest/download/opera-proxy.linux-arm64"
            CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
            ;;
        * )
            echo "當前架構 $ARCH 沒有适配。退出。"
            exit 1
            ;;
    esac

    # 下载（失败则退出）
    curl -fL "$ECH_URL" -o ech-server-linux
    curl -fL "$OPERA_URL" -o opera-linux
    curl -fL "$CLOUDFLARED_URL" -o cloudflared-linux

    chmod +x cloudflared-linux ech-server-linux opera-linux

    local COUNTRY_UPPER="${COUNTRY^^}"

    echo "--- 啟動服務 ---"

    # 1. 啟動 Opera Proxy (如果 $OPERA=1)
    if [ "$OPERA" = "1" ]; then
        operaport=$(get_free_port)
        echo "啟動 Opera Proxy (port: $operaport, country: $COUNTRY_UPPER)..."
        nohup ./opera-linux \
            -country "$COUNTRY_UPPER" \
            -socks-mode \
            -bind-address "127.0.0.1:$operaport" \
            > /dev/null 2>&1 &
        OPERA_PID=$!
    fi

    # 2. 啟動 ECH Server (處理 WSPORT)
    sleep 1

    if [ -z "$WSPORT" ]; then
        wsport=$(get_free_port)
        echo "WSPORT 環境變數未設置，自動選取端口: $wsport"
    else
        wsport="$WSPORT"
        echo "使用自定義的 WSPORT 端口: $wsport"
    fi

    # 用数组拼 ECH 参数（更稳）
    ECH_ARGS=(./ech-server-linux -l "ws://0.0.0.0:$wsport")

    if [ -n "$TOKEN" ]; then
        ECH_ARGS+=(-token "$TOKEN")
        echo "ECH Server 已設置 token（不在前台顯示）"
    else
        echo "ECH Server 未設置 token"
    fi

    if [ "$OPERA" = "1" ]; then
        ECH_ARGS+=(-f "socks5://127.0.0.1:$operaport")
    fi

    echo "啟動 ECH Server (port: $wsport)..."
    nohup "${ECH_ARGS[@]}" > /dev/null 2>&1 &
    ECH_PID=$!

    # 3. 啟動 Cloudflared Tunnel
    metricsport=$(get_free_port)
    echo "啟動 Cloudflared Tunnel (metrics port: $metricsport)..."

    # update 失败不致命（需要致命可改成：./cloudflared-linux update || exit 1）
    ./cloudflared-linux update > /dev/null 2>&1 || true

    nohup ./cloudflared-linux \
        --edge-ip-version "$IPS" \
        --protocol http2 \
        tunnel --url "127.0.0.1:$wsport" \
        --metrics "0.0.0.0:$metricsport" \
        > /dev/null 2>&1 &
    CF_PID=$!

    # 獲取 Argo Hostname
    while true; do
        echo "正在嘗試獲取 Argo 域名..."
        RESP=$(curl -s "http://127.0.0.1:$metricsport/metrics" || true)

        if echo "$RESP" | grep -q 'userHostname='; then
            echo "獲取成功，正在解析..."
            DOMAIN=$(echo "$RESP" | grep 'userHostname="' | sed -E 's/.*userHostname="https?:\/\/([^"]+)".*/\1/')

            echo "--- 服務啟動成功 ---"
            if [ -z "$TOKEN" ]; then
                echo "未設置 token, 連接為: $DOMAIN:443"
            else
                echo "已設置 token, 連接為: $DOMAIN:443 （token 不顯示）"
            fi
            echo "您可以透過日誌或 Docker inspect 查找連接信息。"
            break
        else
            echo "未獲取到 userHostname，5秒後重試..."
            sleep 5
        fi
    done

    echo "--- 保持容器運行 ---"
    tail -f /dev/null
}

# 根據傳入的參數執行對應模式
if [ "$1" == "1" ]; then
    # 檢查並處理 Opera 模式的設定
    if [ "$OPERA" = "1" ]; then
        echo "已啟用 Opera 前置代理。"
        COUNTRY=${COUNTRY:-AM}
        COUNTRY=${COUNTRY^^}
        if [ "$COUNTRY" != "AM" ] && [ "$COUNTRY" != "AS" ] && [ "$COUNTRY" != "EU" ]; then
            echo "錯誤：請設置正確的 OPERA_COUNTRY (AM/AS/EU)。目前值: $COUNTRY"
            exit 1
        fi
    elif [ "$OPERA" != "0" ]; then
        echo "錯誤：OPERA 變數只能是 0 (不啟用) 或 1 (啟用)。目前值: $OPERA"
        exit 1
    fi

    # 檢查並處理 IP 模式的設定
    if [ "$IPS" != "4" ] && [ "$IPS" != "6" ]; then
        echo "錯誤：IPS 變數只能是 4 或 6。目前值: $IPS"
        exit 1
    fi

    quicktunnel
else
    echo "使用非預期模式啟動。請參閱 Dockerfile。"
    exit 1
fi
