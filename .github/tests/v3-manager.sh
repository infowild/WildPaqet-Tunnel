#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export WILDPAQET_LIB_ONLY=1
source "$repo_root/wildpaqet.sh"

test "$SCRIPT_VERSION" = "9.13-v3"
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
# Go's HTTP/2 server defaults both receive windows to 1 MiB while its transport
# defaults the reverse direction to 4 MiB, so upload ran at roughly a quarter of
# download on the same RTT. The core now derives the window from smuxbuf, and
# smux v2 makes streambuf meaningful (v1 ignored it). These keys must land in
# new configs and be back-filled into existing ones.
# ------------------------------------------------------------------
tuning_dir=$(mktemp -d /tmp/wildpaqet-v3-tuning.XXXXXX)
cleanup_tuning() { rm -rf -- "$tuning_dir"; }
trap 'cleanup_parse; cleanup_tuning' EXIT

v3_emit_tuning_keys '    ' | grep -qx '    smuxbuf: 4194304'
v3_emit_tuning_keys '    ' | grep -qx '    streambuf: 2097152'
v3_emit_tuning_keys '    ' | grep -qx '    smux_version: 2'

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

# An h2 config whose tls block is followed by another top-level section.
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

# A hand-tuned host must not be overwritten.
cat > "$tuning_dir/tuned.yaml" <<'EOF'
role: "server"
transport:
  protocol: "tls"
  tls:
    mode: "h2"
    alpn: "h2"
    smuxbuf: 8388608
    streambuf: 4194304
    smux_version: 2
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
if [ "$changed" != "2" ]; then
    echo "expected 2 migrated configs, got $changed" >&2
    exit 1
fi

grep -qx '    smuxbuf: 4194304' "$tuning_dir/iran.yaml"
grep -qx '    streambuf: 2097152' "$tuning_dir/iran.yaml"
grep -qx '    smux_version: 2' "$tuning_dir/iran.yaml"

# The keys belong inside the tls block, not after the next section.
if ! awk '/^[[:space:]]*tls:/ { in_tls=1; next }
          in_tls && /^[^[:space:]]/ { exit }
          in_tls && $1 == "smux_version:" { found=1 }
          END { exit(found ? 0 : 1) }' "$tuning_dir/mixed.yaml"; then
    echo "tuning keys were inserted outside the tls block" >&2
    exit 1
fi
grep -qx 'network:' "$tuning_dir/mixed.yaml"

grep -qx '    smuxbuf: 8388608' "$tuning_dir/tuned.yaml"
if grep -q 'smuxbuf: 4194304' "$tuning_dir/tuned.yaml"; then
    echo "hand-tuned smuxbuf was overwritten" >&2
    exit 1
fi

if grep -q 'smux_version' "$tuning_dir/legacy.yaml"; then
    echo "direct-mode config was migrated to smux v2" >&2
    exit 1
fi
if grep -q 'smux_version' "$tuning_dir/kcp.yaml"; then
    echo "KCP config was given TLS tuning keys" >&2
    exit 1
fi

changed=$(v3_migrate_all_configs "$tuning_dir")
if [ "$changed" != "0" ]; then
    echo "migration is not idempotent: $changed files changed on a second run" >&2
    exit 1
fi
