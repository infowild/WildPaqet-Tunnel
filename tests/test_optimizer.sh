#!/usr/bin/env bash
# Fixture tests for Safe/Auto Network Optimizer helpers (no live sysctl/tc mutation).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/wildpaqet.sh"
PASS=0
FAIL=0

assert_eq() {
    local name="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"
        echo "    got:  [$got]"
        echo "    want: [$want]"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local name="$1" hay="$2" needle="$3"
    if [[ "$hay" == *"$needle"* ]]; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name (missing '$needle')"
        echo "    got: [$hay]"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local name="$1" hay="$2" needle="$3"
    if [[ "$hay" != *"$needle"* ]]; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name (unexpected '$needle')"
        FAIL=$((FAIL + 1))
    fi
}

load_optimizer_helpers() {
    NETOPT_MARKER="wildpaqet-managed"
    export NETOPT_MARKER
    local tmp
    tmp=$(mktemp)
    sed -n '/# --- OPTIMIZER_TEST_EXPORT_BEGIN ---/,/# --- OPTIMIZER_TEST_EXPORT_END ---/p' "$SCRIPT" \
        | sed '1d;$d' > "$tmp"
    # shellcheck disable=SC1090
    # shellcheck source=/dev/null
    source "$tmp"
    rm -f "$tmp"
}

parse_default_iface() {
    awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

root_qdisc_kind() {
    awk '/^qdisc / && $0 !~ /parent/ {print $2; exit}'
}

has_fq_leaf() {
    grep -qE '^qdisc fq [0-9]'
}

echo "== syntax: wildpaqet.sh =="
bash -n "$SCRIPT"
echo "  PASS: bash -n wildpaqet.sh"
PASS=$((PASS + 1))

echo "== load helpers =="
load_optimizer_helpers
echo "  PASS: helpers loaded"
PASS=$((PASS + 1))

echo "== default-route iface parsing =="
assert_eq "eth0 from IPv4 default" \
    "$(echo 'default via 1.2.3.4 dev eth0 proto dhcp metric 100' | parse_default_iface)" \
    "eth0"
assert_eq "enp3s0 from IPv4 default" \
    "$(echo 'default via 10.0.0.1 dev enp3s0 proto static' | parse_default_iface)" \
    "enp3s0"
assert_eq "ens3 from IPv6 default" \
    "$(echo 'default via fe80::1 dev ens3 proto ra metric 1024' | parse_default_iface)" \
    "ens3"

echo "== virtual iface filter =="
if optimizer_iface_is_virtual "docker0"; then
    echo "  PASS: docker0 virtual"; PASS=$((PASS + 1))
else
    echo "  FAIL: docker0 should be virtual"; FAIL=$((FAIL + 1))
fi
if optimizer_iface_is_virtual "veth0abc"; then
    echo "  PASS: veth* virtual"; PASS=$((PASS + 1))
else
    echo "  FAIL: veth* should be virtual"; FAIL=$((FAIL + 1))
fi
if optimizer_iface_is_virtual "lo"; then
    echo "  PASS: lo virtual"; PASS=$((PASS + 1))
else
    echo "  FAIL: lo should be virtual"; FAIL=$((FAIL + 1))
fi

echo "== qdisc fixture detection =="
MQ_FQ_FIXTURE=$'qdisc mq 0: root\nqdisc fq 0: parent 1:1 limit 10000p flow_limit 100p\nqdisc fq 0: parent 1:2 limit 10000p flow_limit 100p'
assert_eq "mq root kind" "$(printf '%s\n' "$MQ_FQ_FIXTURE" | root_qdisc_kind)" "mq"
if printf '%s\n' "$MQ_FQ_FIXTURE" | has_fq_leaf; then
    echo "  PASS: detects fq leaves under mq"; PASS=$((PASS + 1))
else
    echo "  FAIL: should detect fq leaves"; FAIL=$((FAIL + 1))
fi

FQ_ROOT=$'qdisc fq 0: root refcnt 2 limit 10000p flow_limit 100p'
assert_eq "fq root kind" "$(printf '%s\n' "$FQ_ROOT" | root_qdisc_kind)" "fq"

FQ_CODEL=$'qdisc fq_codel 0: root refcnt 2 limit 10240p flows 1024'
assert_eq "fq_codel root kind" "$(printf '%s\n' "$FQ_CODEL" | root_qdisc_kind)" "fq_codel"
if printf '%s\n' "$FQ_CODEL" | has_fq_leaf; then
    echo "  FAIL: fq_codel must not match fq leaf regex"; FAIL=$((FAIL + 1))
else
    echo "  PASS: fq_codel not mistaken for fq"; PASS=$((PASS + 1))
fi

PFIFO=$'qdisc pfifo_fast 0: root refcnt 2 bands 3 priomap'
assert_eq "pfifo_fast root kind" "$(printf '%s\n' "$PFIFO" | root_qdisc_kind)" "pfifo_fast"

echo "== RAM-based safe profile =="
PROF_2G=$(optimizer_build_safe_profile 1536)
assert_contains "2G uses fq_codel" "$PROF_2G" "net.core.default_qdisc = fq_codel"
assert_not_contains "2G never bare fq" "$PROF_2G" "default_qdisc = fq"$'\n'
# fq_codel contains the substring "fq" — assert the exact safe value instead:
assert_contains "2G exact qdisc line" "$PROF_2G" "net.core.default_qdisc = fq_codel"
assert_contains "2G smaller rmem_max" "$PROF_2G" "net.core.rmem_max = 8388608"
assert_contains "2G backlog 2500" "$PROF_2G" "netdev_max_backlog = 2500"
assert_not_contains "2G no 16MB default rmem" "$PROF_2G" "rmem_default"
assert_not_contains "2G no conntrack mega" "$PROF_2G" "nf_conntrack_max"
assert_not_contains "2G no rp_filter" "$PROF_2G" "rp_filter"
assert_not_contains "2G no ip_forward" "$PROF_2G" "ip_forward"

PROF_4G=$(optimizer_build_safe_profile 4096)
assert_contains "4G rmem_max mid" "$PROF_4G" "net.core.rmem_max = 25165824"
assert_contains "4G backlog 8000" "$PROF_4G" "netdev_max_backlog = 8000"

PROF_8G=$(optimizer_build_safe_profile 8192)
assert_contains "8G rmem_max 32M" "$PROF_8G" "net.core.rmem_max = 33554432"
assert_contains "8G backlog 10000" "$PROF_8G" "netdev_max_backlog = 10000"
assert_contains "profile has marker" "$PROF_8G" "wildpaqet-managed"
assert_contains "BBR preferred" "$PROF_8G" "tcp_congestion_control = bbr"
assert_contains "port range safe" "$PROF_8G" "ip_local_port_range = 10000 65535"

PROF_DEF=$(optimizer_build_safe_profile 2048)
assert_contains "default 16M max" "$PROF_DEF" "net.core.rmem_max = 16777216"
assert_contains "default backlog 5000" "$PROF_DEF" "netdev_max_backlog = 5000"
assert_contains "default somax 4096" "$PROF_DEF" "somaxconn = 4096"

echo "== owned keys list =="
KEYS=$(optimizer_owned_sysctl_keys)
assert_contains "owns default_qdisc" "$KEYS" "net.core.default_qdisc"
assert_contains "owns congestion" "$KEYS" "net.ipv4.tcp_congestion_control"
assert_not_contains "does not own ip_forward" "$KEYS" "ip_forward"
assert_not_contains "does not own rp_filter" "$KEYS" "rp_filter"
assert_not_contains "does not own conntrack" "$KEYS" "conntrack"

echo "== config idempotency (same RAM => same body) =="
A=$(optimizer_build_safe_profile 4096)
B=$(optimizer_build_safe_profile 4096)
assert_eq "idempotent profile body" "$A" "$B"

echo "== rollback fixture layout =="
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SNAP="$TMP/snap-fixture"
mkdir -p "$SNAP/sysctl_values" "$SNAP/qdisc"
echo "cubic" > "$SNAP/sysctl_values/net.ipv4.tcp_congestion_control"
echo "pfifo_fast" > "$SNAP/sysctl_values/net.core.default_qdisc"
printf '%s\n' "$MQ_FQ_FIXTURE" > "$SNAP/qdisc/enp3s0.txt"
echo "safe-auto" > "$SNAP/meta.profile"
assert_eq "snapshot congestion value" "$(cat "$SNAP/sysctl_values/net.ipv4.tcp_congestion_control")" "cubic"
assert_eq "snapshot qdisc iface file" "$(root_qdisc_kind < "$SNAP/qdisc/enp3s0.txt")" "mq"
assert_eq "snapshot profile meta" "$(cat "$SNAP/meta.profile")" "safe-auto"

echo "== dry-run path markers (Debian/Ubuntu + RHEL family) =="
assert_contains "sysctl drop-in path" "$(grep -n 'SYSCTL_FILE=' "$SCRIPT" | head -1)" "99-paqet-tunnel.conf"
assert_contains "limits drop-in path" "$(grep -n 'LIMITS_FILE=' "$SCRIPT" | head -1)" "99-paqet.conf"
assert_contains "netopt state dir" "$(grep -n 'NETOPT_STATE_DIR=' "$SCRIPT" | head -1)" "/var/lib/wildpaqet/netopt"
if grep -q 'install_bbr_legacy' "$SCRIPT"; then
    echo "  FAIL: legacy BBR installer still present"; FAIL=$((FAIL + 1))
else
    echo "  PASS: legacy teddysun BBR installer removed"; PASS=$((PASS + 1))
fi
if grep -q 'optimizer_fix_fq_on_iface' "$SCRIPT" && grep -q 'parent "$parent" fq_codel' "$SCRIPT"; then
    echo "  PASS: mq-safe leaf remediator present"; PASS=$((PASS + 1))
else
    echo "  FAIL: mq-safe remediator missing"; FAIL=$((FAIL + 1))
fi

echo "== shellcheck (optional) =="
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -e SC2034,SC2086,SC2155,SC2162,SC1090,SC1091 "$ROOT/tests/test_optimizer.sh"; then
        echo "  PASS: shellcheck test_optimizer.sh"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: shellcheck test_optimizer.sh"
        FAIL=$((FAIL + 1))
    fi
else
    echo "  SKIP: shellcheck not installed"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
