FROM caddy:2.8-alpine

WORKDIR /app

COPY index.html /srv/index.html
COPY Caddyfile /etc/caddy/Caddyfile
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

ENV IPS=4 OPERA=0

# 不写死端口，因为它由 WSPORT 决定
# EXPOSE 只是声明，可选
EXPOSE 7860

CMD ["/bin/sh", "-c", "/app/start.sh 1 & caddy run --config /etc/caddy/Caddyfile --adapter caddyfile"]
