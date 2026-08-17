<div align="center">

# WildPaqet Tunnel

**Real HTTP/2-covered TLS tunnel with direct-TLS and raw-KCP compatibility**

[![Version](https://img.shields.io/badge/version-9.3--v3-0B6E4F?style=for-the-badge)](https://github.com/infowild/WildPaqet-Tunnel/tree/wild-paqet-v3)
[![License](https://img.shields.io/badge/license-MIT-1B4332?style=for-the-badge)](https://github.com/infowild/WildPaqet-Tunnel)
[![Shell](https://img.shields.io/badge/shell-bash-081C15?style=for-the-badge)](https://github.com/infowild/WildPaqet-Tunnel/blob/wild-paqet-v3/wildpaqet.sh)
[![Platform](https://img.shields.io/badge/platform-Linux-2D6A4F?style=for-the-badge)](https://github.com/infowild/WildPaqet-Tunnel)

[فارسی](README.fa.md) · [Repository](https://github.com/infowild/WildPaqet-Tunnel) · [Core tree](./core) · [v3 install](docs/V3-INSTALL.md)

<br/>

### Stable (main)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/main/wildpaqet.sh)
```

### WildPaqet v3 (this branch)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/wild-paqet-v3/wildpaqet.sh)
```

Then:

```bash
wildpaqet
```

> After first run, menu **0 → 8** builds **WildPaqet Core v3** from source. See [docs/V3-INSTALL.md](docs/V3-INSTALL.md).
</div>

---

## Why WildPaqet?

WildPaqet is a production-oriented tunnel manager for Kharej ↔ Iran deployments. v3 defaults to **real HTTP/2 over TLS 1.3 with smux inside the HTTP/2 body** over normal kernel TCP. Legacy direct TLS and hardened raw socket + KCP remain compatibility modes.

| | |
|---|---|
| **One command** | Install once, run forever with `wildpaqet` |
| **Dual role** | Abroad server + Iran entry (forward / SOCKS5) |
| **Multi tunnel** | Multiple services on one Iran VPS → many Kharej locations |
| **Multi port** | Comma-separated forwards with tcp / udp / both |
| **Safe cleanup** | Full uninstall restores script-owned system changes |

Forked and maintained from [Paqet-Tunnel-Manager](https://github.com/behzadea12/Paqet-Tunnel-Manager).

---

## Architecture

```mermaid
flowchart LR
  U[Users / Panels] --> IR[Iran VPS<br/>wildpaqet client]
  IR -->|HTTP/2 + TLS 1.3 + smux| KH1[Kharej A]
  IR -->|HTTP/2 + TLS 1.3 + smux| KH2[Kharej B]
  IR -->|HTTP/2 + TLS 1.3 + smux| KH3[Kharej C]
  IR -->|HTTP/2 + TLS 1.3 + smux| KH4[Kharej D]
  KH1 --> NET[Internet / Origin services]
  KH2 --> NET
```

- **Kharej**: listens for the tunnel (`role: server`)
- **Iran**: terminates locally and **forwards ports** or exposes **SOCKS5**
- Same **32+ character secret** and **core version** on both sides; Iran trusts each Kharej certificate

---

## Quick Start

### 1) Launch (root)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/wild-paqet-v3/wildpaqet.sh)
```

On first run the manager **auto-installs** the `wildpaqet` system command from this branch.

Then: **0 → 8** to build WildPaqet Core v3 from this branch.

If the distro Go compiler is older than `core/go.mod`, the installer uses Go
toolchain switching or downloads a checksum-verified official compiler under
`/opt/wildpaqet-go`; it does not replace the system Go installation.

### 2) Kharej

1. Option **2** → **v3 HTTP/2-covered TLS**
2. Use the same public certificate name and shared secret on all Kharej servers
3. Enter the DNS name that points at this Kharej server. The wizard reuses a still-valid public certificate for that name, or requests one from Let's Encrypt (HTTP-01 on TCP/80) and then locates the issued files. Self-signed mode is for testing only
4. Copy the `WPQ4` pairing code printed by each server; a code that carries a certificate chain is printed as a block of lines ending with `WPQEND`, and copying every line of it (or the saved `pairing-code.txt` file) keeps it intact

### 3) Iran

1. Option **3** → **v3 HTTP/2-covered TLS**
2. Choose the default **Paste pairing code(s)** option
3. Paste the four codes and submit an empty line; endpoints and the CA bundle are created automatically. A wrapped code may be pasted as a whole block, and a path to a `pairing-code.txt` copied with `scp` is accepted instead of a paste
4. Keep the recommended four outer connections per Kharej (16 total for four endpoints)
5. Enter the shared secret once, then choose Port Forward or SOCKS5

### 4) Daily use

```bash
wildpaqet
```

> If `wildpaqet: command not found`, run the curl launcher once as root, or:
> ```bash
> export PATH="/usr/local/bin:$PATH" && hash -r
> ```

---

## Features

<table>
<tr>
<td width="50%">

### Tunnel ops
- Server / Client wizards
- Multi-port forwarding
- Built-in SOCKS5
- Multi-service (multi-location)
- systemd + optional auto-restart cron

</td>
<td width="50%">

### Ops & safety
- Connection protection (Anti-RST / NOTRACK, raw transport only)
- NAT helpers
- MTU / bulk config tools
- Telegram status bot
- Full uninstall (`YES` confirm)

</td>
</tr>
</table>

---

## Legacy raw-KCP defaults (v3 manager)

| Setting | Server | Client |
|--------|--------|--------|
| KCP mode | `normal` | `normal` |
| Connections | `1` | `1` |
| MTU | `1350` | `1350` |
| TCP preset | `default` | `default` |
| Encryption | `aes-128-gcm` | `aes-128-gcm` |
| Command | `wildpaqet` | `wildpaqet` |

---

## Real HTTP/2 cover transport (9.3-v3)

New `tls.mode: h2` configurations negotiate TLS with visible SNI, ALPN `h2`, and a uTLS ClientHello, then send the standards-required HTTP/2 preface, SETTINGS and DATA frames. Smux remains inside one authenticated, full-duplex HTTP/2 `CONNECT` request. This is not WebSocket and does not falsely advertise HTTP/2 while speaking a private protocol immediately after TLS.

Unknown or unauthenticated HTTP requests receive a normal built-in page or an optional local decoy website. Tunnel authentication is an encrypted HMAC token bound to the opaque cover path, timestamp and random nonce. Replays and timestamps outside the two-minute window fail closed. A publicly trusted certificate is strongly recommended because a self-signed certificate remains visible to an active probe.

Certificate and key files are checked on each new TLS handshake and reloaded after ACME/Certbot replaces them; routine certificate renewal therefore does not require a Paqet restart.

Manager v9.5 uses `WPQ4` pairing codes containing the endpoint, public certificate name, opaque cover path and public certificate. A code that carries a certificate chain does not fit on one terminal line, so it is printed as a block ending with `WPQEND` and reassembled on import; `pairing-code.txt` can be copied with `scp` instead. They contain neither the shared secret nor private key. The cover path is routing metadata, not an authentication secret. All endpoints in one pool must use the same certificate name, cover path and shared secret. The wizard derives the default path from the certificate name and shared secret, so matching Kharej nodes get the same path automatically. Legacy `WPQ3` / `mode: direct` configurations remain supported but do not provide the HTTP/2 cover.

Four outer connections per Kharej endpoint distribute new streams round-robin. A background supervisor rebuilds closed slots. HTTP/2 connections rotate after a jittered lifetime; the replacement enters the pool first and the old connection drains existing streams before closing. Connection startup and smux keepalives are also jittered. Three consecutive dial failures open that endpoint's circuit for 30 seconds, with exponential cooldown capped at five minutes and a single half-open probe.

Use two connections per endpoint for low traffic, four for balanced production traffic, or eight only for high concurrency on a larger Iran VPS. Registered-user count is not a capacity figure: size the Iran host and uplink for simultaneous traffic. A 1-vCPU/1-GB host is suitable for testing; start production sizing around 4 vCPU / 4 GB and verify with a representative load test.

See [the v3 install guide](docs/V3-INSTALL.md) and the [client](core/example/client-tls.yaml.example) / [server](core/example/server-tls.yaml.example) examples.

## Legacy raw wire hardening (8.7-v2)

The tunnel leg between Iran and Kharej used to be easy to single out on the wire. Preset `default` now makes it behave like an ordinary TCP connection:

| Before | Now |
|--------|-----|
| A lone SYN with no answer, then data — worse than no handshake at all | Fail-closed three-way handshake: SYN retries use backoff and no tunnel data is sent without a valid `SYN-ACK` |
| SEQ/ACK were pseudo-random and unrelated to the bytes sent | SEQ counts bytes sent, ACK follows bytes received, timestamps echo the peer |
| A random ACK / fabricated timestamp echo was sent before the peer was ever seen | No ACK or `TSecr` is advertised until the peer's sequence space is actually observed |
| Every packet marked DSCP 46 (`TOS 184`), the expedited-forwarding class used by VoIP | No DSCP mark (`TOS 0`), like normal traffic |
| `IP.id` fixed at 0 on every DF packet — a bulk-tunnel giveaway | Moving `IP.id` (IPv4) / flow label (IPv6), like a real stack |
| Flows just went silent mid-stream | Best-effort `FIN,ACK` teardown on close |
| Packet-count timestamps and no outer loss recovery | Monotonic timestamps plus cumulative ACK and bounded outer TCP retransmission with the original SEQ |
| Tight reconnect loops and a fixed two-second keepalive | Exponential retry jitter and conservative `15s/60s` SMUX keepalive/timeout |

Update **both ends** — the handshake and outer ACK/retransmission behaviour require Iran and Kharej to run the same build. A missing or invalid `SYN-ACK` now fails closed instead of sending data on an unestablished flow.

Set `network.tcp.preset: "legacy"` on both sides to restore the old wire behaviour if you need to compare.

---

## Menu Map

| # | Action |
|---|--------|
| 0 | Install / update core & manager |
| 1 | Dependencies |
| 2 | Configure Kharej server |
| 3 | Configure Iran client |
| 4 | Manage one service |
| 5 | Manage all (NAT, protection, bulk) |
| 6 | Connectivity tests |
| 7 | Optimize (Safe/Auto network + DNS / Mirror) |
| 8 | **Full uninstall** |
| 9 | Telegram bot |
| 10 | Exit |

---

## Update

```bash
wildpaqet
# 0 → 5 Update script
```

Or re-run the curl one-liner.

---

## Uninstall (full cleanup)

```bash
wildpaqet
# option 8 → type YES
```

Removes **all** script/tunnel artifacts: services, cron, core + backups, `$INSTALL_DIR`, the Core v3 source tree, the isolated Go toolchain, configs, `wildpaqet` / legacy links, Telegram bot, script sysctl/limits, managed iptables/NAT rules, tracked UFW/firewalld allowances, `/root/paqet`, `/root/paqet-backups`, state under `/var/lib/wildpaqet`, and temporary build files. The final verifier reports any managed artifact that could not be removed. A separate opt-in prompt can flush untracked legacy/non-WildPaqet NAT rules.

Network optimizer cleanup during uninstall is **snapshot-aware**: it restores the oldest `/var/lib/wildpaqet/netopt/snap-*` as the true pre-WildPaqet baseline, including prior sysctl/limits files, captured runtime sysctl values, and qdisc kinds changed by the optimizer. It then removes the `wildpaqet-qdisc.service` boot unit and snapshot store without forcing `fq_codel`, `cubic`, or `pfifo_fast`. The NAT helper likewise restores a pre-existing `30-ip_forward.conf` instead of deleting user content.

Does **not** remove distro packages (curl, iptables-persistent, golang, …). External third-party BBR installers (if you ran them separately) are left alone.

### Safe/Auto Network Optimizer (menu 7)

WildPaqet **8.6-v2+** ships a rewritten Safe/Auto optimizer for Ubuntu/Debian and RHEL-family hosts:

- Uses **`fq_codel`** only — never `fq` (which caps each kernel flow at ~100 packets and collapses raw-packet Paqet tunnels under load).
- Preserves **`mq`** multi-queue roots; only retargets `fq` leaves under `mq`, or replaces a single-queue `fq` root.
- Enables **BBR** only after `modprobe` + availability check; otherwise keeps/falls back to `cubic`.
- Conservative RAM-scaled buffers (no 256MB max / huge backlog / mega conntrack / forced `rp_filter` / `ip_forward`).
- Snapshots under `/var/lib/wildpaqet/netopt/` before apply; **Rollback** restores the last snapshot (not a blind `cubic`/`pfifo_fast` wipe).
- Remediates live qdisc on **default-route** interfaces only (`eth0`, `enp3s0`, …) — not Docker/VPN virtuals.
- **Do not** re-run old manager “Kernel Optimization” / remote `teddysun/bbr.sh` flows — they can reintroduce `fq`.

Menu: **7 → 1** Apply · **2** Status · **3** Rollback · **4** Reset owned drop-ins · DNS Finder / Mirror Selector.

---

## Troubleshooting

<details>
<summary><b>wildpaqet: command not found</b></summary>

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/wild-paqet-v3/wildpaqet.sh)
# or
ls -l /usr/local/bin/wildpaqet
/usr/local/bin/wildpaqet
export PATH="/usr/local/bin:$PATH" && hash -r
```
</details>

<details>
<summary><b>bad interpreter / No such file or directory</b></summary>

CRLF line endings. Reinstall manager (0 → 5) — installer strips `\r`.
</details>

<details>
<summary><b>GLIBC_2.34 not found</b></summary>

Use Ubuntu 22.04+ / Debian 12+, or build paqet from source on that host.
</details>

<details>
<summary><b>bind: address already in use</b></summary>

```bash
ss -tuln | grep 8443
lsof -i :8443
```
</details>

<details>
<summary><b>Core install fails</b></summary>

Retry option **0 → 8** after checking DNS and outbound HTTPS. If downloads are
blocked in Iran, build with **0 → 8** on a Kharej server and copy that v3 binary
to Iran as described in the error message. Do not use an upstream Paqet release
with a `protocol: tls` configuration.
</details>

---

## Requirements

- Linux VPS (Ubuntu / Debian / CentOS-like)
- Root privileges
- `libpcap`, `iptables`, `curl`
- Matching **paqet** core on both ends

---

## Credits

- [paqet](https://github.com/hanselime/paqet) — hanselime  
- [Paqet-Tunnel-Manager](https://github.com/behzadea12/Paqet-Tunnel-Manager) — original manager  

---

## License

MIT — aligned with upstream projects.

<div align="center">

**WildPaqet** · by [InfoWild](https://github.com/infowild)

`bash <(curl -fsSL https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/wild-paqet-v3/wildpaqet.sh)`

</div>
