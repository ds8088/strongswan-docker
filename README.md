# strongswan-docker

This is a Docker image for running strongSwan (the IKE daemon) from Alpine stable repos.

The image entrypoint script supports automatic reloading of configuration and certificate files.

## Purpose

The gist: strongSwan does not have an official Docker image.

There are a few alternative community images but most of them are either:

- tailored to a specific use-case;
- use wild and wacky iptables rules, usually hardcoded;
- or are abandoned.

This is my attempt to create an image that replicates my own use-case:
a stable and recent version of strongSwan, set up on Alpine Linux,
without being opinionated on firewall rules and configuration,
and with automatic reloading so that cert-manager in my k8s cluster
can simply update the Secret and the pod's entrypoint script will reload strongSwan.

It also uses nftables instead of iptables, which, apparently, is still
a rare sight to behold.

## Configuration

A single volume mounted at `/config` with the following files:

- `/config/strongswan.conf`: strongSwan configuration file
- `/config/swanctl.conf`: swanctl configuration file
- `/config/rules.nft`: nftables rules in nft format
- `/config/certs/cert.crt`: strongSwan certificate
- `/config/certs/key.key`: strongSwan private key
- `/config/certs/ca.crt`: single CA certificate (optional)
- `/config/certs/ca/`: directory of CA certificates (optional)

Configuration files should preferably use the new strongswan.conf-style syntax.

### Certificates

`certs/cert.crt` may contain a full certificate chain, including the root.

If so, the entrypoint script splits it on load:

- the first block is considered to be the leaf certificate.
  It is installed into `x509`;
- the intermediate CA certificates are written to their own files
  to the `x509ca` directory (one cert - one file);
- the final block is assumed to be the root CA and is simply elided.

CA certificates can also be supplied directly without splitting anything:

- `certs/ca.crt`: a single CA certificate, installed into `x509ca`;
- `certs/ca/`: a directory with CA files, copied into `x509ca`.

These copying/splitting operations are additive and all run on every reload.

## Automatic reloading

The entrypoint watches the configuration directory for changes (through `inotify`).

If a change is detected, let's say a Secret got changed and Kubernetes
replaced the volume's files, the updated files are reinstalled to their locations,
and `swanctl --load-all` command is issued.

This effectively reloads strongSwan on any configuration changes, including certificates,
without resorting to third-party tools such as Reloader.

## Other

strongSwan requires several capabilities:

- `NET_ADMIN`: SA and policy management;
- `NET_BIND_SERVICE`: for binding to 500/udp and 4500/udp;
- `NET_RAW`: IKE packets (I think DPD also requires NET_RAW).

Bare AH/ESP (not wrapped in an UDP stream) is not supported.
