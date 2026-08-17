#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export WILDPAQET_LIB_ONLY=1
source "$repo_root/wildpaqet.sh"

test "$SCRIPT_VERSION" = "9.12.1-v3"
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
