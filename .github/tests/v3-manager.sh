#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export WILDPAQET_LIB_ONLY=1
source "$repo_root/wildpaqet.sh"

test "$SCRIPT_VERSION" = "9.10-v3"
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

echo 'v3-manager-pool-and-refresh: PASS'
