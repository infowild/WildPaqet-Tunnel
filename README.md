# WildPaqet-Tunnel | [📄 فارسی](README.fa.md)

Management script for **paqet**: a raw socket, KCP-based tunnel designed for firewall/DPI bypass. Supports **Kharej (external) server** and **Iran client (entry point)** configurations.

This repository is a maintained fork of [Paqet-Tunnel-Manager](https://github.com/behzadea12/Paqet-Tunnel-Manager), updated as **WildPaqet Tunnel Manager v7.1**.

**Repository:** https://github.com/infowild/WildPaqet-Tunnel

---

## Table of Contents

* [Quick Start](#quick-start)
* [Installation Steps](#installation-steps)
  * [Step 1: Setup Server (Kharej)](#step-1-setup-server-kharej--vpn-server)
  * [Step 2: Setup Server (Iran)](#step-2-setup-server-iran--cliententry-point)
* [Advanced Configuration (KCP Modes)](#advanced-configuration-kcp-modes)
* [Network Optimization (Optional)](#network-optimization-optional)
* [Included Tools](#included-tools)
* [Troubleshooting](#troubleshooting-paqet-installation-issues)
* [Requirements](#requirements)
* [Changelog (v7.1)](#changelog-v71)
* [Credits](#credits)
* [License](#license)

---

## Quick Start

Run the script on **both servers** as **root**:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/main/paqet-manager.sh)
```

> **Older manager builds** (if needed):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/main/paqet-manager3-8.sh)
```

Select **option 0**, then **option 1** to install prerequisites / core.

---

## Installation Steps

### Step 1: Setup Server (Kharej – VPN Server)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/main/paqet-manager.sh)
```

1. **Select option 2** (Kharej)
2. Enter a **service name** (e.g. `fanland1`)
3. Enter the **listen port** (e.g. `443` or `8443`)
4. Press Enter to auto-generate the **secret key** (save it)
5. Confirm with **`Y`**
6. Select **KCP mode** (default: `fast`)
7. **conn** → number of KCP connections (default: `4`)
8. **MTU** → default `1350` (or set manually, e.g. `1200`)
9. Select **encryption** (default: `aes-128-gcm`)
10. **pcap sockbuf** / **transport tcpbuf** / **transport udpbuf** → Enter to skip defaults

### Step 2: Setup Server (Iran – Client/Entry Point)

1. **Select option 3** (Iran)
2. Enter a **service name**
3. Enter the **Kharej server IP**
4. Enter the **server port** used between the two servers
5. Enter the **secret key** from the server side
6. Select **KCP mode** (default: `fast`)
7. **conn** → default `1` on client
8. **MTU** → default `1350`
9. Select **encryption** (default: `aes-128-gcm`)
10. Buffer options → Enter to skip
11. Choose traffic type: **Port Forwarding** or **SOCKS5**
12. For forwarding: enter ports (e.g. `333` or `333,394,395`) and protocol per port (`tcp` / `udp` / both)

**Important:** Use the **same paqet core version** on both servers.

### Optional: Install core from a custom URL

1. Run the manager → option **0**
2. Option **3** (Download from custom URL)
3. Paste an archive URL matching your arch (`amd64` / `arm64`)
4. Restart services (option **5** → restart all if needed)

Official core releases: [hanselime/paqet releases](https://github.com/hanselime/paqet/releases)

---

## Advanced Configuration (KCP Modes)

0. **normal** – Normal speed, normal latency, low usage  
1. **fast** – Balanced (recommended for most setups)  
2. **fast2** – Higher speed, lower latency, moderate usage  
3. **fast3** – Max speed, very low latency, high CPU  
4. **manual** – Advanced parameters  

---

## Network Optimization (Optional)

Select **option 7**:

1. **BBR** – TCP congestion control *(recommended on external servers)*
2. **DNS Finder** – Best DNS for Iran *(recommended on Iran servers)*
3. **Mirror Selector** – Fastest APT mirror *(Ubuntu/Debian)*

---

## Included Tools

* [BBR – teddysun/across](https://github.com/teddysun/across/)
* [IranDNSFinder](https://github.com/alinezamifar/IranDNSFinder)
* [DetectUbuntuMirror](https://github.com/alinezamifar/DetectUbuntuMirror)

---

## Troubleshooting: Paqet Installation Issues

### 1) Download / binary not found

1. Download from [paqet releases](https://github.com/hanselime/paqet/releases)
2. Place the archive in `/root/paqet/`
3. Re-run the manager and use **local file** install (option 0 → 2)

### 2) `GLIBC_2.32` / `GLIBC_2.34` not found

Upgrade OS (Ubuntu 22.04+ / Debian 12+), build from source, or use a newer VPS:

```bash
apt install -y golang git
git clone https://github.com/hanselime/paqet.git && cd paqet
go build -o paqet ./cmd/paqet
sudo cp paqet /usr/local/bin/paqet
sudo chmod +x /usr/local/bin/paqet
```

### 3) `bind: address already in use`

```bash
ss -tuln | grep 8443
lsof -i :8443
```

Change the port or stop the conflicting process. Remove duplicate `forward` listen entries in `/etc/paqet/*.yaml` if needed.

### 4) Duplicate `conn:` after bulk edit (fixed in v7.1)

Older v7.0 could append a second `conn` under `transport`. Upgrade to this manager and re-apply connections once, or manually keep a single indented `conn:` under `transport:`.

---

## Requirements

* Linux server (Ubuntu, Debian, CentOS, …)
* Root access
* `libpcap-dev`, `iptables`
* `paqet` core binary

---

## Changelog (v7.1)

* Retargeted manager URLs to `infowild/WildPaqet-Tunnel`
* Fixed bulk **connections** edit creating duplicate `conn` keys
* Safer core install (extract to temp first; keep previous binary backup)
* Aligned defaults: MTU `1350`, client connections `1`, server connections `4`
* Fixed KCP mode menu descriptions
* Kernel backup filenames use timestamp at backup time
* Removed third-party Telegram proxy; official API (+ optional SOCKS5)
* BBR download uses `curl` with TLS verification
* Removed misleading `GOMAXPROCS=0` from systemd unit

---

## Credits

* **[paqet](https://github.com/hanselime/paqet)** – raw packet tunneling by hanselime
* **[Paqet-Tunnel-Manager](https://github.com/behzadea12/Paqet-Tunnel-Manager)** – original manager by behzadea12

---

## License

MIT (as stated by the upstream projects; add a `LICENSE` file to this repo if you want it explicit on GitHub).
