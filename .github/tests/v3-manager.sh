#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export WILDPAQET_LIB_ONLY=1
source "$repo_root/wildpaqet.sh"

test "$SCRIPT_VERSION" = "9.9-v3"
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

echo 'v3-manager-pool-and-refresh: PASS'
