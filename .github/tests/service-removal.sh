#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_dir=$(mktemp -d /tmp/wildpaqet-service-remove.XXXXXX)
trap 'rm -rf -- "$test_dir"' EXIT

export WILDPAQET_LIB_ONLY=1
export WILDPAQET_CONFIG_DIR="$test_dir/config"
export WILDPAQET_SERVICE_DIR="$test_dir/systemd"
export WILDPAQET_STATE_DIR="$test_dir/state"
export WILDPAQET_FIREWALL_STATE_FILE="$test_dir/state/firewall.rules"
source "$repo_root/wildpaqet.sh"

mkdir -p "$CONFIG_DIR/tls/ci-remove" "$SERVICE_DIR/paqet-ci-remove.service.d" "$STATE_DIR"
printf 'role: "server"\nlisten:\n  addr: ":24443"\n' > "$CONFIG_DIR/ci-remove.yaml"
printf 'public pairing data\n' > "$CONFIG_DIR/tls/ci-remove/pairing-code.txt"
printf '[Service]\nExecStart=/bin/false\n' > "$SERVICE_DIR/paqet-ci-remove.service"
printf '[Service]\nEnvironment=TEST=1\n' > "$SERVICE_DIR/paqet-ci-remove.service.d/test.conf"

calls=()
systemctl() {
    calls+=("systemctl $*")
    return 0
}
remove_cronjob() {
    calls+=("cron $*")
    return 0
}
cleanup_paqet_iptables_from_configs() {
    calls+=("iptables $*")
    return 0
}
cleanup_managed_firewall_for_config() {
    calls+=("firewall $*")
    return 0
}
save_iptables() {
    return 0
}

remove_service_artifacts "paqet-ci-remove.service" "ci-remove"

test ! -e "$CONFIG_DIR/ci-remove.yaml"
test ! -e "$CONFIG_DIR/tls/ci-remove"
test ! -e "$SERVICE_DIR/paqet-ci-remove.service"
test ! -e "$SERVICE_DIR/paqet-ci-remove.service.d"
printf '%s\n' "${calls[@]}" | grep -qx "cron paqet-ci-remove"
printf '%s\n' "${calls[@]}" | grep -qx "iptables $CONFIG_DIR/ci-remove.yaml"
printf '%s\n' "${calls[@]}" | grep -qx "firewall $CONFIG_DIR/ci-remove.yaml"
printf '%s\n' "${calls[@]}" | grep -qx "systemctl stop paqet-ci-remove.service"
printf '%s\n' "${calls[@]}" | grep -qx "systemctl disable paqet-ci-remove.service"
printf '%s\n' "${calls[@]}" | grep -qx "systemctl daemon-reload"
printf '%s\n' "${calls[@]}" | grep -qx "systemctl reset-failed paqet-ci-remove.service"

if remove_service_artifacts "paqet-../../unsafe.service" "../../unsafe"; then
    echo "unsafe service name was accepted" >&2
    exit 1
fi

echo 'service-removal: PASS'
