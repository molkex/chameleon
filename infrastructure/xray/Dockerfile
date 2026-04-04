# Minimal Xray container — just the binary, reads /etc/xray/config.json
FROM ghcr.io/xtls/xray-core:latest AS source

FROM alpine:3.21
COPY --from=source /usr/local/bin/xray /usr/local/bin/xray
RUN mkdir -p /etc/xray

ENTRYPOINT ["xray", "run", "-config", "/etc/xray/config.json"]
