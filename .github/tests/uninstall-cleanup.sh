#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_dir=$(mktemp -d /tmp/wildpaqet-uninstall-test.XXXXXX)
cleanup_test() {
    case "$test_dir" in
        /tmp/wildpaqet-uninstall-test.*) rm -rf -- "$test_dir" ;;
        *) echo "unsafe temp path: $test_dir" >&2; return 1 ;;
    esac
}
trap cleanup_test EXIT

export WILDPAQET_LIB_ONLY=1
export WILDPAQET_STATE_DIR="$test_dir/state"
export WILDPAQET_SYSCTL_FILE="$test_dir/99-paqet-tunnel.conf"
export WILDPAQET_LIMITS_FILE="$test_dir/99-paqet.conf"
export WILDPAQET_NETOPT_STATE_DIR="$test_dir/state/netopt"
export WILDPAQET_QDISC_SCRIPT="$test_dir/usr-local-lib/fix-qdisc.sh"
export WILDPAQET_FIREWALL_STATE_FILE="$test_dir/state/firewall.rules"
export WILDPAQET_IP_FORWARD_FILE="$test_dir/30-ip_forward.conf"
source "$repo_root/wildpaqet.sh"

# Firewall ownership state is de-duplicated and every owned backend is removed.
record_managed_firewall_rule ufw tcp 443
record_managed_firewall_rule ufw tcp 443
record_managed_firewall_rule firewalld tcp 8443
test "$(wc -l < "$FIREWALL_STATE_FILE" | tr -d ' ')" = "2"

firewall_calls="$test_dir/firewall.calls"
tagged_rule_present=1
ufw() {
    printf 'ufw %s\n' "$*" >> "$firewall_calls"
    [ "$*" != "show added" ] || echo 'ufw allow 443/tcp'
}
firewall-cmd() { printf 'firewall-cmd %s\n' "$*" >> "$firewall_calls"; }
iptables() {
    printf 'iptables %s\n' "$*" >> "$firewall_calls"
    if [[ "$*" == *" -L "* ]] && [ "$tagged_rule_present" -eq 1 ]; then
        echo "1 0 0 ACCEPT all -- * * 0.0.0.0/0 0.0.0.0/0 /* $FIREWALL_COMMENT */"
    elif [[ "$*" == *" -D "* ]]; then
        tagged_rule_present=0
    fi
    return 0
}
cleanup_managed_firewall_rules
test ! -e "$FIREWALL_STATE_FILE"
grep -Fxq 'ufw --force delete allow 443/tcp' "$firewall_calls"
grep -Fxq 'firewall-cmd --permanent --remove-port=8443/tcp' "$firewall_calls"
grep -Fxq 'firewall-cmd --reload' "$firewall_calls"
grep -Eq '^iptables -t (raw|mangle|filter|nat) -D ' "$firewall_calls"

# The NAT helper restores a pre-existing user drop-in and removes a file that
# was absent before WildPaqet instead of leaving ip_forward state behind.
printf '%s\n' '# user-owned' 'net.ipv4.ip_forward=0' > "$IP_FORWARD_FILE"
cp "$IP_FORWARD_FILE" "$test_dir/ip-forward.expected"
write_managed_ip_forwarding_dropin 1
grep -q "$NETOPT_MARKER" "$IP_FORWARD_FILE"
restore_ip_forwarding_dropin
cmp "$test_dir/ip-forward.expected" "$IP_FORWARD_FILE"

rm -f "$IP_FORWARD_FILE"
write_managed_ip_forwarding_dropin 1
test -e "$IP_FORWARD_ABSENT_MARKER"
restore_ip_forwarding_dropin
test ! -e "$IP_FORWARD_FILE"

printf '%s\n' '# user-owned legacy-looking file' 'net.ipv4.ip_forward=1' > "$IP_FORWARD_FILE"
restore_ip_forwarding_dropin
test -e "$IP_FORWARD_FILE"
printf '%s\n' 'net.ipv4.ip_forward=1' > "$IP_FORWARD_FILE"
restore_ip_forwarding_dropin
test ! -e "$IP_FORWARD_FILE"

# Full optimizer cleanup uses the oldest snapshot as the true baseline, keeps
# restored drop-ins, restores the prior fq qdisc kind, and removes state.
old_snap="$NETOPT_STATE_DIR/snap-20260101-000000"
new_snap="$NETOPT_STATE_DIR/snap-20260102-000000"
mkdir -p "$old_snap/sysctl_values" "$old_snap/qdisc" "$new_snap/sysctl_values" "$new_snap/qdisc"
printf '%s\n' '# original sysctl' 'net.core.default_qdisc = fq' > "$old_snap/sysctl.dropin"
printf '%s\n' '# original limits' '* soft nofile 4096' > "$old_snap/limits.dropin"
printf '%s\n' 'qdisc fq 0: root refcnt 2 limit 10000p' > "$old_snap/qdisc/eth0.txt"
printf '%s\n' '# later WildPaqet snapshot' > "$new_snap/sysctl.dropin"
touch -t 202601010000 "$old_snap" 2>/dev/null || true
touch -t 202601020000 "$new_snap" 2>/dev/null || true
printf '%s\n' '# currently managed' > "$SYSCTL_FILE"
printf '%s\n' '# currently managed' > "$LIMITS_FILE"

runtime_calls="$test_dir/runtime.calls"
systemctl() { printf 'systemctl %s\n' "$*" >> "$runtime_calls"; }
sysctl() { printf 'sysctl %s\n' "$*" >> "$runtime_calls"; }
ip() { return 0; }
tc() { printf 'tc %s\n' "$*" >> "$runtime_calls"; }

cleanup_kernel_optimizations_silent
cmp "$old_snap/sysctl.dropin" "$SYSCTL_FILE" 2>/dev/null || grep -Fxq '# original sysctl' "$SYSCTL_FILE"
grep -Fxq '# original limits' "$LIMITS_FILE"
test ! -e "$NETOPT_STATE_DIR"
grep -Fxq 'tc qdisc replace dev eth0 root fq' "$runtime_calls"
if grep -Fq 'net.core.default_qdisc=fq_codel' "$runtime_calls"; then
    echo 'uninstall forced fq_codel instead of restoring the baseline' >&2
    exit 1
fi

grep -Fq 'rm -f /tmp/wildpaqet-core-*' "$repo_root/wildpaqet.sh"
grep -Fq 'verify_full_uninstall_cleanup' "$repo_root/wildpaqet.sh"

echo 'uninstall-cleanup-and-restore: PASS'
