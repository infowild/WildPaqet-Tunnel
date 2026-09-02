#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export WILDPAQET_LIB_ONLY=1
source "$repo_root/wildpaqet.sh"

test "$SCRIPT_VERSION" = "9.15-v3"
v3_validate_cover_path '/api/v1/cover/events'
if v3_validate_cover_path '/api/../admin'; then
	echo "unsafe cover path was accepted" >&2
	exit 1
fi

test "$(v3_total_outer_connections 1 4)" = "4"
test "$(v3_total_outer_connections 4 4)" = "16"
test "$(v3_total_outer_connections 16 16)" = "256"
if v3_total_outer_connections 0 4 >/dev/null; then
    echo "zero endpoints were accepted" >&2
    exit 1
fi
if v3_total_outer_connections 4 17 >/dev/null; then
    echo "too many per-endpoint connections were accepted" >&2
    exit 1
fi

systemctl_calls=()
systemctl_active=1
systemctl() {
    systemctl_calls+=("$*")
    if [ "${1:-} ${2:-}" = "is-active --quiet" ]; then
        [ "$systemctl_active" -eq 1 ]
        return
    fi
    return 0
}

enable_and_refresh_service paqet-usa
printf '%s\n' "${systemctl_calls[@]}" | grep -qx 'enable paqet-usa'
printf '%s\n' "${systemctl_calls[@]}" | grep -qx 'restart paqet-usa'
if printf '%s\n' "${systemctl_calls[@]}" | grep -qx 'start paqet-usa'; then
    echo "active service was started instead of restarted" >&2
    exit 1
fi

systemctl_calls=()
systemctl_active=0
enable_and_refresh_service paqet-new
printf '%s\n' "${systemctl_calls[@]}" | grep -qx 'enable paqet-new'
printf '%s\n' "${systemctl_calls[@]}" | grep -qx 'start paqet-new'
if printf '%s\n' "${systemctl_calls[@]}" | grep -qx 'restart paqet-new'; then
    echo "inactive service was restarted instead of started" >&2
    exit 1
fi

parse_dir=$(mktemp -d /tmp/wildpaqet-v3-parse.XXXXXX)
cleanup_parse() { rm -rf -- "$parse_dir"; }
trap cleanup_parse EXIT
cat > "$parse_dir/germany.yaml" <<'EOF'
role: "client"
transport:
  protocol: "tls"
  conn: 4
  tls:
    mode: "h2"
    server_name: "dl.wilduser.org"
EOF
test "$(config_transport_protocol "$parse_dir/germany.yaml")" = "tls"
test "$(config_tls_mode "$parse_dir/germany.yaml")" = "h2"
yaml_set_transport_conn "$parse_dir/germany.yaml" 2
grep -qE '^[[:space:]]*conn: 2$' "$parse_dir/germany.yaml"

cat > "$parse_dir/forward-client.yaml" <<'EOF'
role: "client"
log:
  level: "info"
forward:
  - listen: "0.0.0.0:8080"
    target: "127.0.0.1:8080"
    protocol: "tcp"
server:
  addr: "203.0.113.10:443"
transport:
  protocol: "tls"
  conn: 4
EOF
mapfile -t fwd < <(yaml_list_forward_entries "$parse_dir/forward-client.yaml")
test "${#fwd[@]}" -eq 1
test "$fwd" = "8080|127.0.0.1:8080|tcp"
yaml_rewrite_forward_entries "$parse_dir/forward-client.yaml" \
    "8080|127.0.0.1:8080|tcp" "8443|127.0.0.1:8443|udp"
mapfile -t fwd < <(yaml_list_forward_entries "$parse_dir/forward-client.yaml")
test "${#fwd[@]}" -eq 2

cat > "$parse_dir/tcp-only.yaml" <<'EOF'
role: "client"
forward:
  - listen: "0.0.0.0:9090"
    target: "127.0.0.1:9090"
    protocol: "tcp"
EOF
mapfile -t fwd < <(yaml_list_forward_entries "$parse_dir/tcp-only.yaml")
entries=("${fwd[@]}")
enable_forward_port_tcp_udp entries 9090 "127.0.0.1:9090"
yaml_rewrite_forward_entries "$parse_dir/tcp-only.yaml" "${entries[@]}"
mapfile -t fwd < <(yaml_list_forward_entries "$parse_dir/tcp-only.yaml")
test "${#fwd[@]}" -eq 2
printf '%s\n' "${fwd[@]}" | grep -q '|tcp$'
printf '%s\n' "${fwd[@]}" | grep -q '|udp$'

echo 'v3-manager-pool-and-refresh: PASS'

# ------------------------------------------------------------------
# v3 throughput tuning keys
#
# Every one of these windows bounds in-flight bytes to window/RTT. Go's HTTP/2
# server defaults both receive windows to 1 MiB while its transport defaults the
# reverse direction to 4 MiB, which is why upload ran at a quarter of download;
# and on smux v2 streambuf is a per-stream limit that v1 did not have at all.
# A LAN-sized value here silently caps a single flow however fast the link is.
# ------------------------------------------------------------------
fail() { echo "FAIL: $*" >&2; exit 1; }

tuning_dir=$(mktemp -d /tmp/wildpaqet-v3-tuning.XXXXXX)
cleanup_tuning() { rm -rf -- "$tuning_dir"; }
trap 'cleanup_parse; cleanup_tuning' EXIT

# --- per-RAM sizing -------------------------------------------------
test "$(v3_default_smuxbuf 1024)"  = "4194304" || fail "1 GB host smuxbuf"
test "$(v3_default_streambuf 1024)" = "2097152" || fail "1 GB host streambuf"
test "$(v3_default_smuxbuf 4096)"  = "8388608" || fail "4 GB host smuxbuf"
test "$(v3_default_streambuf 4096)" = "4194304" || fail "4 GB host streambuf"

# Capture first: piping into `grep -q` lets grep exit on the first match and
# SIGPIPE the producer, which `set -o pipefail` then reports as a failure.
emitted_large=$(v3_emit_tuning_keys '    ' 4096)
emitted_small=$(v3_emit_tuning_keys '    ' 1024)
grep -qx '    smuxbuf: 8388608'  <<<"$emitted_large" || fail "emit smuxbuf"
grep -qx '    streambuf: 4194304' <<<"$emitted_large" || fail "emit streambuf"
grep -qx '    smux_version: 2'    <<<"$emitted_large" || fail "emit smux_version"
grep -qx '    smuxbuf: 4194304'   <<<"$emitted_small" || fail "emit small-host smuxbuf"

# --- the numbers must actually clear a WAN path ----------------------
# 2 MiB over a 100 ms path is ~168 Mbps: that was the 9.13-v3 regression.
test "$(v3_window_mbps 2097152 100)" -lt 200  || fail "sanity: 2 MiB window"
test "$(v3_window_mbps "$(v3_default_streambuf 4096)" 100)" -ge 300 \
    || fail "default streambuf caps a single flow below 300 Mbps at 100 ms"
# The other half of the trade: whatever one bulk transfer has outstanding also
# sits ahead of every other stream on the same outer connection, so an oversized
# window buys latency, not speed.
test "$(v3_window_queue_ms "$(v3_default_streambuf 4096)" 100)" -le 400 \
    || fail "default streambuf parks over 400 ms of queue on a 100 Mbps link"
# The optimizer holds the outer TCP receive window at 8 MiB to keep window
# scale 7; going past it here would only move the stall one layer down.
test "$(v3_default_streambuf 4096)" -le 8388608 \
    || fail "streambuf exceeds the outer TCP window the optimizer allows"
test "$(v3_default_streambuf 4096)" -le "$(v3_default_smuxbuf 4096)" \
    || fail "streambuf exceeds smuxbuf; smux rejects that pairing"

# --- migration ------------------------------------------------------
v3_host_ram_mb() { echo 4096; }

cat > "$tuning_dir/iran.yaml" <<'EOF'
role: "client"
server:
  addr: "203.0.113.10:443"
transport:
  protocol: "tls"
  conn: 16
  tls:
    mode: "h2"
    server_name: "tunnel.example.com"
    secret: "0123456789abcdef0123456789abcdef"
    alpn: "h2"
    cover_path: "/api/v1/events"
    keepalive: 15
EOF

# Written by manager 9.13-v3, which sized the buffers for a LAN by mistake.
cat > "$tuning_dir/stale.yaml" <<'EOF'
role: "server"
transport:
  protocol: "tls"
  tls:
    mode: "h2"
    alpn: "h2"
    smuxbuf: 4194304
    streambuf: 2097152
    smux_version: 2
EOF

# Written by the first 9.14-v3 attempt: sized purely for throughput.
cat > "$tuning_dir/stale14.yaml" <<'EOF'
role: "server"
transport:
  protocol: "tls"
  tls:
    mode: "h2"
    alpn: "h2"
    smuxbuf: 16777216
    streambuf: 8388608
    smux_version: 2
EOF

# Values the operator chose: never overwritten.
cat > "$tuning_dir/custom.yaml" <<'EOF'
role: "server"
transport:
  protocol: "tls"
  tls:
    mode: "h2"
    alpn: "h2"
    smuxbuf: 33554432
    streambuf: 16777216
    smux_version: 2
EOF

# tls block followed by another top-level section.
cat > "$tuning_dir/mixed.yaml" <<'EOF'
role: "client"
transport:
  protocol: "tls"
  tls:
    mode: "h2"
    alpn: "h2"
    keepalive: 15
network:
  tcp:
    preset: "default"
EOF

# Legacy direct mode keeps smux v1 for wire compatibility with older peers.
cat > "$tuning_dir/legacy.yaml" <<'EOF'
role: "client"
transport:
  protocol: "tls"
  tls:
    mode: "direct"
    alpn: "h2"
EOF

cat > "$tuning_dir/kcp.yaml" <<'EOF'
role: "client"
transport:
  protocol: "kcp"
EOF

changed=$(v3_migrate_all_configs "$tuning_dir")
test "$changed" = "4" || fail "expected 4 migrated configs (iran, stale, stale14, mixed), got $changed"

grep -qx '    smuxbuf: 8388608' "$tuning_dir/iran.yaml"   || fail "iran smuxbuf"
grep -qx '    streambuf: 4194304' "$tuning_dir/iran.yaml"  || fail "iran streambuf"
grep -qx '    smux_version: 2' "$tuning_dir/iran.yaml"     || fail "iran smux_version"

grep -qx '    smuxbuf: 8388608' "$tuning_dir/stale.yaml"  || fail "9.13 smuxbuf not upgraded"
grep -qx '    streambuf: 4194304' "$tuning_dir/stale.yaml" || fail "9.13 streambuf not upgraded"
grep -qx '    smuxbuf: 8388608' "$tuning_dir/stale14.yaml"  || fail "9.14 smuxbuf not corrected"
grep -qx '    streambuf: 4194304' "$tuning_dir/stale14.yaml" || fail "9.14 streambuf not corrected"

grep -qx '    smuxbuf: 33554432' "$tuning_dir/custom.yaml"  || fail "operator smuxbuf overwritten"
grep -qx '    streambuf: 16777216' "$tuning_dir/custom.yaml" || fail "operator streambuf overwritten"

# The keys belong inside the tls block, not after the next section.
awk '/^[[:space:]]*tls:/ { in_tls=1; next }
     in_tls && /^[^[:space:]]/ { exit }
     in_tls && $1 == "smux_version:" { found=1 }
     END { exit(found ? 0 : 1) }' "$tuning_dir/mixed.yaml" \
    || fail "tuning keys landed outside the tls block"
grep -qx 'network:' "$tuning_dir/mixed.yaml" || fail "mixed.yaml lost its network section"

grep -q 'smux_version' "$tuning_dir/legacy.yaml" && fail "direct-mode config was migrated to smux v2"
grep -q 'smux_version' "$tuning_dir/kcp.yaml" && fail "KCP config was given TLS tuning keys"

changed=$(v3_migrate_all_configs "$tuning_dir")
test "$changed" = "0" || fail "migration is not idempotent: $changed files changed on a second run"

# The retired sysctl key must still be cleanable on already-optimized hosts.
owned_keys=$(optimizer_owned_sysctl_keys)
retired_keys=$(optimizer_retired_sysctl_keys)
grep -qx 'net.ipv4.ip_local_port_range' <<<"$owned_keys" \
    || fail "port range no longer owned for cleanup"
grep -qF 'net.ipv4.ip_local_port_range|10000 65535|32768 60999' <<<"$retired_keys" \
    || fail "retired key mapping missing"

echo 'v3-manager-tuning-and-migration: PASS'
