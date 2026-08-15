<div align="center">

# WildPaqet Tunnel

**Raw-packet KCP tunnel manager for restricted networks**

[![Version](https://img.shields.io/badge/version-8.3--v2-0B6E4F?style=for-the-badge)](https://github.com/infowild/WildPaqet-Tunnel/tree/wild-paqet-v2)
[![License](https://img.shields.io/badge/license-MIT-1B4332?style=for-the-badge)](https://github.com/infowild/WildPaqet-Tunnel)
[![Shell](https://img.shields.io/badge/shell-bash-081C15?style=for-the-badge)](https://github.com/infowild/WildPaqet-Tunnel/blob/wild-paqet-v2/wildpaqet.sh)
[![Platform](https://img.shields.io/badge/platform-Linux-2D6A4F?style=for-the-badge)](https://github.com/infowild/WildPaqet-Tunnel)

[فارسی](README.fa.md) · [Repository](https://github.com/infowild/WildPaqet-Tunnel) · [Core tree](./core) · [v2 install](docs/V2-INSTALL.md)

<br/>

### Stable (main)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/main/wildpaqet.sh)
```

### WildPaqet v2 (this branch — recommended for testing)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/wild-paqet-v2/wildpaqet.sh)
```

Then:

```bash
wildpaqet
```

> After first run, menu **0 → 8** builds **WildPaqet Core v2** from source (wire realism + mimic handshake + multi-addr). See [docs/V2-INSTALL.md](docs/V2-INSTALL.md).
</div>

---

## Why WildPaqet?

WildPaqet is a production-oriented manager for the [paqet](https://github.com/hanselime/paqet) core: a **raw socket + KCP** tunnel built for Kharej ↔ Iran deployments.

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
  IR -->|KCP raw tunnel| KH1[Kharej A]
  IR -->|KCP raw tunnel| KH2[Kharej B]
  KH1 --> NET[Internet / Origin services]
  KH2 --> NET
```

- **Kharej**: listens for the tunnel (`role: server`)
- **Iran**: terminates locally and **forwards ports** or exposes **SOCKS5**
- Same **secret key** + same **core version** on both sides

---

## Quick Start

### 1) Launch (root)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/wild-paqet-v2/wildpaqet.sh)
```

On first run the manager **auto-installs** the `wildpaqet` system command from this branch.

Then: **0 → 8** to build WildPaqet Core v2 (or **0 → 1** after a `core-v*` release).

### 2) Kharej

1. Option **2** → Server  
2. Name, listen port, secret key  
3. KCP `fast`, conn `4`, MTU `1350`, encryption `aes-128-gcm`

### 3) Iran

1. Option **3** → Client  
2. Kharej IP + port + secret  
3. conn `1`, MTU `1350`  
4. Port Forward (`443,8443,...`) or SOCKS5

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
- Connection protection (Anti-RST / NOTRACK)
- NAT helpers
- MTU / bulk config tools
- Telegram status bot
- Full uninstall (`YES` confirm)

</td>
</tr>
</table>

---

## Defaults (v7.1)

| Setting | Server | Client |
|--------|--------|--------|
| KCP mode | `fast` | `fast` |
| Connections | `4` | `1` |
| MTU | `1350` | `1350` |
| TCP preset | `default` | `default` |
| Encryption | `aes-128-gcm` | `aes-128-gcm` |
| Command | `wildpaqet` | `wildpaqet` |

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
| 7 | Optimize (BBR / DNS / Mirror) |
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

Removes **all** script/tunnel artifacts: services, cron, core + backups, `$INSTALL_DIR`, Core v2 source clone, configs, `wildpaqet` / legacy links, Telegram bot, script sysctl/limits, Paqet iptables protection, `/root/paqet`, `/root/paqet-backups`, and `/tmp/paqet*`. Optionally flushes the NAT table.

Does **not** remove distro packages (curl, iptables-persistent, golang, …) or external BBR kernel installs.

---

## Troubleshooting

<details>
<summary><b>wildpaqet: command not found</b></summary>

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/main/wildpaqet.sh)
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

Put the archive in `/root/paqet/` and use option **0 → 2** (local file).  
Releases: https://github.com/hanselime/paqet/releases
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

`bash <(curl -fsSL https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/main/wildpaqet.sh)`

</div>
