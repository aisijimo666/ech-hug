FROM caddy:2.8-alpine

WORKDIR /app

# 安装 bash / curl 以及常用依赖
RUN apk add --no-cache \
    bash \
    curl \
    ca-certificates \
    tzdata \
    coreutils \
 && update-ca-certificates

# 静态页与 Caddy 配置
COPY tunnel_index.html /srv/tunnel_index.html


# 启动脚本
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

# 默认环境变量（按需覆盖）
ENV IPS=4 OPERA=0

# 由 start.sh 负责启动 ech/cloudflared/opera 前台守护
CMD ["bash", "/app/start.sh"]
