# WildPaqet v2 — install & test on a server

Branch: **`wild-paqet-v2`**  
Manager: **`8.6-v2`**  
Core tree: **`./core`** (real 3-way handshake + tracked SEQ/ACK + no DSCP mark + moving IP.id + FIN teardown + multi-addr)

> Push this branch to GitHub before using the one-liner on a VPS.

## 1) One-line install (manager shortcut)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/wild-paqet-v2/wildpaqet.sh)
```

After install, the system command points at this branch:

```bash
wildpaqet
```

Emergency reinstall of the command only:

```bash
curl -fsSL https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/wild-paqet-v2/wildpaqet.sh \
  -o /usr/local/bin/wildpaqet && chmod +x /usr/local/bin/wildpaqet
```

## 2) Install Core v2 binary

In the manager menu: **0 → Install/Update**

| Option | Use when |
|--------|----------|
| **8** Build from source | Best for first tests (clones `wild-paqet-v2`, builds `./core`) |
| **1** Download release | After you tag `core-v*` and CI publishes assets |
| **2** Local tar.gz | Offline / copied build |

Both **Iran** and **Kharej** must run the **same Core v2** binary (`paqet version` should show WildPaqet Core). The hardened handshake only completes when **both ends** run this build — upgrade in pairs.

> **Build from Iran often stalls.** Option **8** needs Go `1.25`; from inside Iran the toolchain download frequently hangs. Prefer building on a **Kharej** server, then copy the binary over:
>
> ```bash
> # On Kharej (already built): serve the binary briefly
> cd /usr/local/bin && python3 -m http.server 8899
>
> # On Iran: pull to a temp file, then swap it in atomically (no ETXTBSY)
> curl -fsSL http://<KHAREJ_IP>:8899/paqet -o /tmp/paqet.new
> chmod +x /tmp/paqet.new && mv -f /tmp/paqet.new /usr/local/bin/paqet
> systemctl list-units --type=service --state=running 'paqet-*' --no-legend \
>   | awk '{print $1}' | xargs -r systemctl restart
> paqet version
> ```
>
> Never `curl -o /usr/local/bin/paqet` or `cp` straight onto a **running** binary — you get `curl: (23) Failure writing output` / `Text file busy` (`ETXTBSY`). Always write `/tmp/paqet.new` then `mv -f`. The manager's option **8** and release install now do this swap for you.

## 3) Recommended test topology

1. **Kharej** — option **2** (Server): listen port e.g. `8888`, copy secret  
2. **Iran** — option **3** (Client): Kharej IP + port + secret  
   - Optional backups: `IP2:8888,IP3:8888`  
3. New YAML includes:

```yaml
network:
  tcp:
    preset: "default"   # hardened wire: real handshake + tracked SEQ/ACK + TOS 0
                        # ("restrictive" is an alias; "legacy" restores pre-hardening behaviour)
```

4. Confirm:

```bash
paqet version
systemctl status paqet-<name>
journalctl -u paqet-<name> -f
```

Look for client log: `connected to ...` and (if mimic) successful dial without handshake errors.

## 4) Publish a core release (optional)

```bash
git tag core-v2.0.0
git push origin wild-paqet-v2
git push origin core-v2.0.0
```

GitHub Actions workflow `.github/workflows/build-core.yml` builds linux amd64/arm64 and attaches assets to the tag.

## 5) Rollback to main manager (7.1)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/infowild/WildPaqet-Tunnel/main/wildpaqet.sh)
```

Or inside menu **0 → 6 Switch version → main-7.1**.

## 6) Safe/Auto Network Optimizer (menu 7)

After tunnels are up, on **both** Iran and Kharej (especially if you ever ran an older optimize that set `fq`):

```bash
wildpaqet
# 7 → 1  Apply Safe/Auto
# 7 → 2  Status (must show default_qdisc=fq_codel and no live fq warning)
```

Key rules in **8.6-v2+** (same Safe/Auto rules as 8.4, plus hardened wire defaults):

| Topic | Behavior |
|-------|----------|
| qdisc | `fq_codel` only — never `fq` |
| multi-queue NIC | keep `mq` root; fix `fq` leaves only |
| iface scope | default-route NICs (`eth0` / `enp3s0` / …), not Docker/VPN |
| rollback | restores `/var/lib/wildpaqet/netopt/snap-*` |
| legacy | remote `teddysun/bbr.sh` removed from the menu |

Do **not** re-apply old “full kernel optimization” profiles from earlier managers; they used oversized buffers and often `fq`.

## 7) Tunnel protection (Anti-RST + NOTRACK)

The raw pcap flow has no kernel socket, so the local kernel would answer inbound
segments — and emit outbound — with `RST`, and conntrack would fill up. **8.6-v2**
applies protection automatically:

- **Server** (option 2): `NOTRACK` + RST-drop on the **listen port**, both directions.
- **Client** (option 3): `NOTRACK` + RST-drop for the **primary server addr and every
  `server.addrs[]` failover peer**, applied at create time (before the service starts).

Re-apply or audit any time from **menu → Connection Protection → Apply** (idempotent).
After changing `server.addrs[]`, re-run Apply so new backups are covered.

## 8) When the Iran entry IP gets filtered

Filtering happens **from inside Iran** while the box is still reachable from abroad
(`check-host.net` shows Iran nodes red, foreign nodes green). Two independent surfaces
can burn an IP:

1. **VLESS / X-UI entry** your users connect to — high-volume, TLS-SNI/pattern exposed.
2. **The tunnel leg** Iran↔Kharej — hardened here (real handshake, tracked SEQ/ACK,
   no DSCP mark, moving IP.id, FIN teardown) but still not invisible.

Recovery playbook:

1. **Rotate the Iran IP** (and DNS if you point a domain at it).
2. Give users a **domain**, not a raw IP, so an IP swap needs **no client reconfig**.
3. Re-point the domain, restart services, re-run **Connection Protection → Apply**.
4. Upgrade the tunnel binary on **both** ends (§2) so the leg stays hardened.

Hardening the tunnel reduces burn from surface (2); it does **not** protect a noisy
VLESS entry on the same IP — separate the entry IP from the tunnel IP where possible.
