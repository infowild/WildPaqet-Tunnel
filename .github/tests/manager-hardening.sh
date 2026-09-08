#!/usr/bin/env bash
# Regression tests for manager-side hardening:
#   - cover_path validation must agree with core/internal/conf/tls.go
#   - secrets written into YAML must survive the parser
#   - firewall cleanup must remove udp rules, not only tcp
#   - the manager self-update must reject a non-manager download
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

work=$(mktemp -d /tmp/wildpaqet-hardening.XXXXXX)
cleanup() { case "$work" in /tmp/wildpaqet-hardening.*) rm -rf -- "$work" ;; esac; }
trap cleanup EXIT

export WILDPAQET_LIB_ONLY=1
export WILDPAQET_STATE_DIR="$work/state"
export WILDPAQET_FIREWALL_STATE_FILE="$work/state/firewall.rules"
export WILDPAQET_BACKUP_DIR="$work/backups"
export WILDPAQET_MANAGER_PATH="$work/installed-manager"
mkdir -p "$work/state" "$work/backups" "$work/bin"
# shellcheck source=/dev/null
source "$repo_root/wildpaqet.sh"

echo "== cover_path agrees with the core validator =="
for good in /api/v1/events /api/v1/ab12cd34/events /a/b/c; do
    v3_validate_cover_path "$good" || fail "cover_path rejected a valid path: $good"
done
# Every one of these fails path.Clean(p) == p in the core and would produce a
# config the service cannot load.
for bad in /api/v1/events/ /. /a/./b /a/../b /a//b / "" no-leading-slash; do
    if v3_validate_cover_path "$bad"; then fail "cover_path accepted an invalid path: $bad"; fi
done
echo "  ok"

echo "== YAML escaping keeps a secret parseable =="
raw='abc"def'
esc=$(yaml_escape_dq "$raw")
[ -n "$esc" ] || fail "yaml_escape_dq produced nothing for quote"
raw='a\b'
esc=$(yaml_escape_dq "$raw")
[ -n "$esc" ] || fail "yaml_escape_dq produced nothing for backslash"
raw='a\"b'
esc=$(yaml_escape_dq "$raw")
[ -n "$esc" ] || fail "yaml_escape_dq produced nothing for both"
raw='plain-secret'
esc=$(yaml_escape_dq "$raw")
[ -n "$esc" ] || fail "yaml_escape_dq produced nothing for plain"
# A double quote must come back escaped, and a backslash must be doubled.
q=$(yaml_escape_dq 'a"b')
[ "$q" = 'a\"b' ] || fail "quote not escaped: $q"
s=$(yaml_escape_dq 'a\b')
[ "$s" = 'a\\b' ] || fail "backslash not doubled: $s"
yaml_value_is_safe "normal" || fail "yaml_value_is_safe rejected a normal value"
yaml_value_is_safe "$(printf 'a\tb')" && fail "yaml_value_is_safe accepted a tab"
echo "  ok"

echo "== firewall cleanup removes udp rules too =="
cat > "$work/bin/ufw" <<'STUB'
#!/bin/bash
[ "$1" = "show" ] && { cat "$UFW_DB"; exit 0; }
if [ "$1" = "--force" ] && [ "$2" = "delete" ]; then
    grep -vF "allow $4" "$UFW_DB" > "$UFW_DB.n"; mv "$UFW_DB.n" "$UFW_DB"
fi
exit 0
STUB
chmod +x "$work/bin/ufw"
export PATH="$work/bin:$PATH"
export UFW_DB="$work/ufw.db"
printf 'ufw allow 443/tcp\nufw allow 8443/udp\nufw allow 22/tcp\n' > "$UFW_DB"
printf 'ufw|tcp|443\nufw|udp|8443\n' > "$WILDPAQET_FIREWALL_STATE_FILE"
cleanup_managed_firewall_rules || fail "cleanup reported failure with a udp rule present"
grep -q "8443/udp" "$UFW_DB" && fail "udp allowance survived cleanup"
grep -q "443/tcp" "$UFW_DB" && fail "tcp allowance survived cleanup"
grep -q "22/tcp" "$UFW_DB" || fail "cleanup removed an administrator rule it does not own"
[ -f "$WILDPAQET_FIREWALL_STATE_FILE" ] && fail "firewall state file survived a complete cleanup"
echo "  ok"

echo "== self-update refuses a non-manager download =="
cat > "$work/bin/curl" <<'STUB'
#!/bin/bash
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && printf '<html>captive portal</html>\n' > "$out"
exit 0
STUB
chmod +x "$work/bin/curl"
cp "$repo_root/wildpaqet.sh" "$WILDPAQET_MANAGER_PATH"
before=$(wc -c < "$WILDPAQET_MANAGER_PATH")
printf '\n' | update_manager_script >/dev/null 2>&1 || true
after=$(wc -c < "$WILDPAQET_MANAGER_PATH")
[ "$before" = "$after" ] || fail "a captive-portal response replaced the installed manager"
is_manager_binary_ok "$WILDPAQET_MANAGER_PATH" || fail "installed manager is no longer valid"
ls "$work"/installed-manager.update.* >/dev/null 2>&1 && fail "a staged download was left behind"
echo "  ok"

if [ "$failures" -ne 0 ]; then
    echo "manager-hardening: $failures failure(s)" >&2
    exit 1
fi
echo "manager-hardening: PASS"
