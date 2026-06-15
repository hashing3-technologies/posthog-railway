FROM caddy:2-alpine@sha256:77c07d5ebfa5be9fd6c820d2094ae662c9e7eeb9bf98346b7f639900263ee2a2

ENTRYPOINT [ \
    "sh", \
    "-c", \
    "set -x && echo \"${CADDYFILE}\" > /etc/caddy/Caddyfile && echo \"${CADDY_EXTRA_CONFIG}\" >> /etc/caddy/Caddyfile && exec caddy run -c /etc/caddy/Caddyfile" \
    ]
