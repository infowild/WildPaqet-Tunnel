# WildPaqet v3 installation

v3.1 uses a real full-duplex HTTP/2 `CONNECT` request over TLS 1.3 on normal kernel TCP. Smux runs inside HTTP/2 DATA frames. It does not use WebSocket. Legacy direct TLS and raw KCP/pcap remain compatibility choices.

## Build and install

Run the v3 manager as root, then choose `0 → 8` to build this branch on every Iran and Kharej host:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/wild-paqet-v3/wildpaqet.sh)
wildpaqet
```

Do not use an older release binary with a `protocol: tls` configuration.

The source installer checks the Go version required by `core/go.mod`. If the
distro compiler is too old, it first tries Go's toolchain switching and then
falls back to a checksum-verified official Go archive under
`/opt/wildpaqet-go`. It does not replace the system Go installation, and the
manager's full uninstall option removes this isolated toolchain.

## Four Kharej servers

On each Kharej host:

1. Choose `2 → v3 HTTP/2-covered TLS`.
2. Use TCP port `443` when it is free.
3. Use a publicly trusted certificate and a DNS name that resolves to the server. A self-signed certificate is retained for testing but is visible to an active probe. The wizard reuses a still-valid public certificate for the domain you enter, or requests one from Let's Encrypt with acme.sh/certbot (HTTP-01 on TCP/80) and then locates the issued files automatically.
4. Use the same certificate name and 32+ character shared secret on all four servers. The wizard then derives the same opaque HTTP/2 cover path automatically. The path is pairing metadata, not an authentication secret.
5. Optionally point `decoy_url` at a real local website such as `http://127.0.0.1:8080`; otherwise a built-in page is served.
6. Keep each private key on its own server.
7. Copy the `WPQ4` pairing code printed by the wizard. A code that carries a certificate chain is longer than a terminal can accept on one line, so it is printed as a block of 120-character lines that ends with `WPQEND`; copy the whole block. It is also saved beside the certificate as `pairing-code.txt`, which can be copied to Iran with `scp` instead.

The core reloads certificate/key files when they change, so Certbot or another ACME client can renew them without a Paqet restart.

For a server configured before manager v9.1, update the manager and choose
`2 → Export pairing code for an existing v3 server`. The pairing code contains
only public bootstrap data; it never
contains the shared secret or `server.key`.

On Iran:

1. Choose `3 → v3 HTTP/2-covered TLS`.
2. Select `Paste pairing code(s)` (the default).
3. Paste one code from each Kharej server, then submit an empty line. A wrapped code is pasted as a whole block including its `WPQEND` line, and the path of a `pairing-code.txt` copied from Kharej is accepted in place of a paste.
4. Choose the outer connections per Kharej. Four is the recommended default.
5. Enter the shared secret once and choose Port Forward or SOCKS5.

The Iran wizard validates each certificate name, expiry, cover path and SHA-256
fingerprint, imports the endpoints, and creates the protected CA bundle
automatically. Manual certificate transfer remains available through the
`Use an existing CA bundle` option:

```bash
install -d -m 700 /etc/paqet/tls
cat kharej-1.crt kharej-2.crt kharej-3.crt kharej-4.crt > /etc/paqet/tls/kharej-ca-bundle.crt
chmod 600 /etc/paqet/tls/kharej-ca-bundle.crt
```

Manager v9.5 creates four outer connections per endpoint by default and distributes new streams round-robin. Four endpoints therefore use `transport.conn: 16`. A background supervisor recreates a closed pool slot without waiting for new user traffic. HTTP/2 connections have jittered startup, keepalive and maximum age. Rotation installs the replacement first and drains existing streams from the old connection. After three consecutive dial failures, an endpoint circuit opens for 30 seconds; cooldown grows up to five minutes, and only one half-open probe is allowed.

Choose two connections per endpoint for low traffic, four for balanced traffic, or eight for high concurrency on a larger Iran VPS. More connections reduce the head-of-line impact of loss on one outer TCP flow, but they do not repair a poor route or create bandwidth. Size the Iran host by simultaneous throughput, not registered users; use a 1-vCPU/1-GB VPS only for testing and load-test production starting around 4 vCPU / 4 GB.

## Security model

- The server enforces TLS 1.3. The client offers a browser-compatible TLS range and negotiates TLS 1.3 with a uTLS ClientHello.
- Visible SNI and ALPN `h2` are followed by the standards-required HTTP/2 preface, SETTINGS and DATA frames.
- The server certificate is verified against the configured CA bundle or system trust store.
- HTTP/2 cover mode requires SNI. A publicly trusted certificate is recommended for active-probe resistance.
- Invalid probes receive a built-in page or optional local decoy website rather than a tunnel-specific close pattern.
- An encrypted HMAC bearer token binds the opaque path, timestamp and random nonce.
- Timestamps outside a two-minute window and reused nonces are rejected before smux starts.
- Authentication and ALPN negotiation fail closed.
- `WPQ4` pairing codes contain no shared secret or private key. The shared secret is entered separately on Iran.

This cover reduces protocol-level fingerprints but cannot guarantee that an IP will never be filtered. Use multiple Iran and Kharej nodes for production availability, and test from the networks you actually serve.

Keep the Iran and Kharej clocks synchronized with systemd-timesyncd, chrony, or another NTP client. Do not expose the shared secret in tickets or screenshots.

## Firewall

v3 uses normal kernel TCP. Do not install the pcap transport's `NOTRACK` or TCP RST-drop rules on the TLS port. The v3 wizard only opens an ordinary TCP input rule.
