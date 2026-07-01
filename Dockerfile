FROM alpine:3.23

RUN apk add --no-cache strongswan nftables inotify-tools

RUN mkdir -p \
    /etc/swanctl/conf.d \
    /etc/swanctl/private \
    /etc/swanctl/x509ca \
    /etc/swanctl/x509

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# /config/strongswan.conf: strongSwan config
# /config/swanctl.conf: swanctl config
# /config/rules.nft: nftables rule file
# /config/certs/cert.crt: strongSwan certificate (or full certificate chain)
# /config/certs/key.key: strongSwan private key
# /config/certs/ca.crt: single CA certificate (optional)
# /config/certs/ca/: directory of CA certificates (optional)

VOLUME ["/config"]

EXPOSE 500/udp 4500/udp

ENTRYPOINT ["/entrypoint.sh"]
