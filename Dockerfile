# Dockerfile
FROM tailscale/tailscale:latest

# jq is used to read 'tailscale status --json' (backend state / existing node identity).
RUN apk add --no-cache bash grep jq

COPY iptables-config.sh /iptables-config.sh
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /iptables-config.sh && \
    chmod +x /entrypoint.sh

# Reports "unhealthy" when Tailscale is not connected (e.g. it needs re-authentication).
HEALTHCHECK --interval=60s --timeout=10s --start-period=120s --retries=3 \
    CMD tailscale status --json | jq -e '.BackendState == "Running"' > /dev/null || exit 1

CMD ["/entrypoint.sh"]
