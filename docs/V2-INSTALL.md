# WildPaqet v2 — install & test on a server

Branch: **`wild-paqet-v2`**  
Manager: **`8.0-v2`**  
Core tree: **`./core`** (wire realism + mimic handshake + multi-addr)

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

Both **Iran** and **Kharej** must run the **same Core v2** binary (`paqet version` should show WildPaqet Core).

## 3) Recommended test topology

1. **Kharej** — option **2** (Server): listen port e.g. `8888`, copy secret  
2. **Iran** — option **3** (Client): Kharej IP + port + secret  
   - Optional backups: `IP2:8888,IP3:8888`  
3. New YAML includes:

```yaml
network:
  tcp:
    preset: "restrictive"   # track_seq + mimic handshake
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
