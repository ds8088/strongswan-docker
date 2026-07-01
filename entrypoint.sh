#!/bin/sh
set -eu

CONFIG_DIR="${CONFIG_DIR:-/config}"
CERTS_DIR="${CONFIG_DIR}/certs"
VICI_SOCKET="${VICI_SOCKET:-/run/charon.vici}"

# split_chain splits a certificate into multiple certificates (see README.md).
split_chain() {
    src="$1"
    tmp="$(mktemp -d)" # We need a temporary directory to hold the certificates.

    # A small AWK snippet that splits the chain into one file per each block.
    awk -v dir="$tmp" '
        /-----BEGIN CERTIFICATE-----/ { out = sprintf("%s/block-%03d.pem", dir, ++n) }
        out { print > out }
    ' "$src"

    # Glob-expand the directory.
    set -- "$tmp"/block-*.pem
    if [ ! -e "$1" ]; then
        echo "warning: no certificates found in ${src}"
        rm -rf "$tmp"
        return
    fi

    # Finally, copy all certificates that we've found.
    count=$#
    idx=0
    for block in "$@"; do
        idx=$((idx + 1))
        if [ "$idx" -eq 1 ]; then
            # idx=1: this is a leaf certificate.
            cp "$block" /etc/swanctl/x509/server.pem
        elif [ "$idx" -eq "$count" ]; then
            # idx=count: this is the root CA, do nothing.
            :
        else
            # Otherwise, it's an intermediate CA.
            cp "$block" "$(printf '/etc/swanctl/x509ca/chain-%02d.pem' "$idx")"
        fi
    done

    rm -rf "$tmp"
}

# install_certs sets up certificates.
install_certs() {
    # Clear the directories.
    rm -f /etc/swanctl/x509/*.pem /etc/swanctl/x509ca/*.pem

    # Install certificate (or a chain, which will require splitting).
    if [ -f "${CERTS_DIR}/cert.crt" ]; then
        echo "installing certificate (splitting full chain)"
        split_chain "${CERTS_DIR}/cert.crt"
    fi

    # Single-file CA.
    if [ -f "${CERTS_DIR}/ca.crt" ]; then
        echo "installing CA certificate"
        cp "${CERTS_DIR}/ca.crt" /etc/swanctl/x509ca/ca.pem
    fi

    # Directory of CA files.
    if [ -d "${CERTS_DIR}/ca" ]; then
        for ca in "${CERTS_DIR}"/ca/*; do
            [ -e "$ca" ] || continue
            echo "installing CA certificate $(basename "$ca")"
            cp "$ca" "/etc/swanctl/x509ca/$(basename "$ca")"
        done
    fi

    # Private key.
    if [ -f "${CERTS_DIR}/key.key" ]; then
        echo "installing private key"
        cp "${CERTS_DIR}/key.key" /etc/swanctl/private/server.pem
        chmod u=rw,g=,o= /etc/swanctl/private/server.pem
    fi
}

# install_config copies configuration files from a mounted volume.
install_config() {
    # Apply nftables rules
    if [ -f "${CONFIG_DIR}/rules.nft" ]; then
        echo "applying nftables rules"
        nft -f "${CONFIG_DIR}/rules.nft"
    fi

    # Install strongSwan config
    if [ -f "${CONFIG_DIR}/strongswan.conf" ]; then
        echo "installing strongswan.conf"
        cp "${CONFIG_DIR}/strongswan.conf" /etc/strongswan.conf
    fi

    # Install swanctl config
    if [ -f "${CONFIG_DIR}/swanctl.conf" ]; then
        echo "installing swanctl.conf"
        cp "${CONFIG_DIR}/swanctl.conf" /etc/swanctl/swanctl.conf
    fi

    # Install certificates
    install_certs
}

# watch_config watches for config/cert changes and reloads strongSwan.
watch_config() {
    while inotifywait -r -e create,modify,moved_to "${CONFIG_DIR}" >/dev/null 2>&1; do
        echo "config change detected, reinstalling config and reloading strongSwan"
        install_config
        swanctl --load-all --noprompt || echo "swanctl --load-all returned a non-zero exit code"
    done
}

# handle_signal traps SIGTERM and SIGINT.
handle_signal() {
    echo "stopping charon"
    kill -TERM "$CHARON_PID" 2>/dev/null || true
    kill "$WATCHER_PID" 2>/dev/null || true
}

# Install config files
install_config

# Start charon
echo "starting charon"
/usr/lib/strongswan/charon &
CHARON_PID=$!

trap handle_signal TERM INT

# Wait until it actually starts
echo "waiting for VICI socket at ${VICI_SOCKET}"
elapsed=0
while [ ! -S "$VICI_SOCKET" ]; do
    sleep 1
    elapsed=$((elapsed + 1))
    [ "$elapsed" -lt "10" ] || exit 1
done

# Load configuration
echo "loading swanctl configuration"
swanctl --load-all --noprompt || echo "swanctl --load-all returned a non-zero exit code"

# Start watching for config changes
watch_config &
WATCHER_PID=$!

echo "strongSwan is running, PID ${CHARON_PID}"

wait "$CHARON_PID"
wait "$CHARON_PID"
echo "charon exited"
