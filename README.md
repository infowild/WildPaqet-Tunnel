# WildPaqet-Tunnel | [📄 فارسی](README.fa.md)

Management script for **paqet**: a raw socket, KCP-based tunnel designed for firewall/DPI bypass. Supports **Kharej (external) server** and **Iran client (entry point)** configurations.

This repository is a maintained fork of [Paqet-Tunnel-Manager](https://github.com/behzadea12/Paqet-Tunnel-Manager), updated as **WildPaqet Tunnel Manager v7.1**.

**Repository:** https://github.com/infowild/WildPaqet-Tunnel

---

## Table of Contents

* [Quick Start](#quick-start)
* [Install as system command](#install-as-system-command)
* [Installation Steps](#installation-steps)
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

Run once on **both servers** as **root**:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/main/wildpaqet.sh)
```

> **Older manager builds** (if needed):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/main/paqet-manager3-8.sh)
```

---

## Install as system command

After opening the manager, choose:

1. Option **0** → Install Paqet Binary / Manager  
2. Option **4** → Install script  

The manager is installed to `/usr/local/bin/wildpaqet`.

Then run anytime with:

```bash
wildpaqet
```

---

## Installation Steps

### Step 1: Setup Server (Kharej – VPN Server)

```bash
wildpaqet
# or first run:
bash <(curl -fsSL https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/main/wildpaqet.sh)
```

1. **Select option 2** (Kharej)
2. Enter a **service name** (e.g. `fanland1`)
3. Enter the **listen port** (e.g. `443` or `8443`)
4. Press Enter to auto-generate the **secret key** (save it)
5. Confirm with **`Y`**
6. Select **KCP mode** (default: `fast`)
7. **conn** → default `4` on server
8. **MTU** → default `1350`
9. Select **encryption** (default: `aes-128-gcm`)
10. Buffer options → Enter to skip

### Step 2: Setup Server (Iran – Client/Entry Point)

1. **Select option 3** (Iran)
2. Enter a **service name**
3. Enter the **Kharej server IP**
4. Enter the **server port**
5. Enter the **secret key**
6. Select **KCP mode** (default: `fast`)
7. **conn** → default `1` on client
8. **MTU** → default `1350`
9. Select **encryption**
10. Buffer options → Enter to skip
11. Choose **Port Forwarding** or **SOCKS5**
12. For forwarding: ports (e.g. `333` or `333,394,395`) and protocol per port

**Important:** Use the **same paqet core version** on both servers.

### Optional: Install core from a custom URL

1. `wildpaqet` → option **0** → option **3** (custom URL)
2. Paste an archive URL for your arch
3. Restart services

Official core: [hanselime/paqet releases](https://github.com/hanselime/paqet/releases)

---

## Advanced Configuration (KCP Modes)

0. **normal** – Normal speed, normal latency, low usage  
1. **fast** – Balanced (recommended)  
2. **fast2** – Higher speed, moderate usage  
3. **fast3** – Max speed, high CPU  
4. **manual** – Advanced parameters  

---

## Network Optimization (Optional)

`wildpaqet` → option **7**:

1. **BBR** – recommended on external servers  
2. **DNS Finder** – recommended on Iran servers  
3. **Mirror Selector** – Ubuntu/Debian APT mirrors  

---

## Included Tools

* [BBR – teddysun/across](https://github.com/teddysun/across/)
* [IranDNSFinder](https://github.com/alinezamifar/IranDNSFinder)
* [DetectUbuntuMirror](https://github.com/alinezamifar/DetectUbuntuMirror)

---

## Troubleshooting: Paqet Installation Issues

### 1) Download / binary not found

Place the archive in `/root/paqet/` and use local install (option 0 → 2).

### 2) `GLIBC_2.32` / `GLIBC_2.34` not found

Upgrade OS or build from source:

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

### 4) Duplicate `conn:` after bulk edit (fixed in v7.1)

Upgrade manager and re-apply connections once, or keep a single indented `conn:` under `transport:`.

---

## Requirements

* Linux + root  
* `libpcap-dev`, `iptables`  
* `paqet` core binary  

---

## Changelog (v7.1)

* Command name: **`wildpaqet`** (installed to `/usr/local/bin/wildpaqet`)
* Main script file: **`wildpaqet.sh`**
* New multi-color **WildPaqet** banner + GitHub link
* Retargeted URLs to `infowild/WildPaqet-Tunnel`
* Fixed bulk connections duplicate-`conn` bug
* Safer core install; aligned MTU/conn defaults
* Official Telegram API only (+ optional SOCKS5)
* TLS-verified BBR download; removed `GOMAXPROCS=0`

---

## Credits

* **[paqet](https://github.com/hanselime/paqet)** – by hanselime  
* **[Paqet-Tunnel-Manager](https://github.com/behzadea12/Paqet-Tunnel-Manager)** – original manager by behzadea12  

---

## License

MIT (as stated by the upstream projects; add a `LICENSE` file if you want it explicit on GitHub).
