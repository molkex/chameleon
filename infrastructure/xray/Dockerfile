# Minimal Xray container — binary + geo data, reads /etc/xray/config.json
FROM ghcr.io/xtls/xray-core:latest AS source

FROM alpine:3.21
COPY --from=source /usr/local/bin/xray /usr/local/bin/xray
COPY --from=source /usr/local/share/xray/geoip.dat /usr/local/bin/geoip.dat
COPY --from=source /usr/local/share/xray/geosite.dat /usr/local/bin/geosite.dat
RUN mkdir -p /etc/xray

ENTRYPOINT ["xray", "run", "-config", "/etc/xray/config.json"]
