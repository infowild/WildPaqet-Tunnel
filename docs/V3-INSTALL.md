# WildPaqet v3 installation

v3 uses direct TLS 1.3 over normal kernel TCP. It does not use HTTP or WebSocket. The legacy raw KCP/pcap transport remains available from the configuration wizard.

## Build and install

Run the v3 manager as root, then choose `0 → 8` to build this branch on every Iran and Kharej host:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/wild-paqet-v3/wildpaqet.sh)
wildpaqet
```

Do not use an older release binary with a `protocol: tls` configuration.

## Four Kharej servers

On each Kharej host:

1. Choose `2 → v3 direct TLS`.
2. Use TCP port `443` when it is free.
3. For a private self-signed certificate, use that server's public IP as its certificate name.
4. Use the same 32+ character shared secret on all four servers.
5. Keep each generated private key on its own server.

Copy each generated `server.crt` to the Iran server and build a trust bundle:

```bash
install -d -m 700 /etc/paqet/tls
cat kharej-1.crt kharej-2.crt kharej-3.crt kharej-4.crt > /etc/paqet/tls/kharej-ca-bundle.crt
chmod 600 /etc/paqet/tls/kharej-ca-bundle.crt
```

On Iran:

1. Choose `3 → v3 direct TLS`.
2. Enter all four `IP:port` endpoints in one comma-separated line.
3. Enter the CA bundle path. Leave server name/SNI empty for the generated private certificates.
4. Enter the same shared secret.

The client creates one outer connection per endpoint by default and distributes new streams round-robin. After three consecutive failures, an endpoint circuit opens for 30 seconds; cooldown grows up to five minutes, and only one half-open probe is allowed.

## Security model

- TLS is restricted to TLS 1.3. Visible ALPN uses the common `h2` value instead of a project-specific fingerprint.
- The server certificate is verified against the configured CA bundle or system trust store.
- SNI is disabled by default for private CA-bundle deployments. Public certificates can enable it explicitly with `send_server_name: true`.
- A post-TLS HMAC authentication frame uses a timestamp and random nonce.
- Timestamps outside a two-minute window and reused nonces are rejected before smux starts.
- Authentication and ALPN negotiation fail closed.

Keep the Iran and Kharej clocks synchronized with systemd-timesyncd, chrony, or another NTP client. Do not expose the shared secret in tickets or screenshots.

## Firewall

v3 uses normal kernel TCP. Do not install the pcap transport's `NOTRACK` or TCP RST-drop rules on the TLS port. The v3 wizard only opens an ordinary TCP input rule.
