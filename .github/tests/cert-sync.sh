#!/usr/bin/env bash
# Regression tests for the TLS certificate sync between Kharej servers.
#
# The sync moves a private key between hosts and replaces the pair a live
# server is using, so the parts that must not be taken on trust are: the peer
# key is pinned to the export command, a bad download never replaces a working
# certificate, and a full uninstall leaves none of it behind.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
section_mark=0
sec() { section_mark=$failures; echo "== $* =="; }
ok() { if [ "$failures" -eq "$section_mark" ]; then echo "  ok"; else echo "  FAILED"; fi; }

work=$(mktemp -d /tmp/wildpaqet-certsync.XXXXXX)
cleanup() { case "$work" in /tmp/wildpaqet-certsync.*) rm -rf -- "$work" ;; esac; }
trap cleanup EXIT

export WILDPAQET_LIB_ONLY=1
export WILDPAQET_STATE_DIR="$work/state"
export WILDPAQET_CONFIG_DIR="$work/etc-paqet"
export WILDPAQET_CERTSYNC_EXPORT="$work/bin/wp-cert-export"
export WILDPAQET_CERTSYNC_PULL="$work/bin/wp-cert-pull"
export WILDPAQET_CERTSYNC_KEY="$work/ssh/wp-cert-pull"
export WILDPAQET_CERTSYNC_AUTHKEYS="$work/ssh/authorized_keys"
export WILDPAQET_CERTSYNC_STATE="$work/state/certsync.conf"
mkdir -p "$work/bin" "$work/ssh" "$work/state" "$work/etc-paqet" "$work/certs"
# shellcheck source=/dev/null
source "$repo_root/wildpaqet.sh"

make_pair() { # dir, CN, days
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$1/key.pem" -out "$1/cert.pem" \
        -days "$3" -subj "/CN=$2" >/dev/null 2>&1
}

sec "the export script ships the pair under stable names"
make_pair "$work/certs" "crm.example.test" 90
# A symlinked path is the certbot layout; cp -L has to resolve it.
ln -sf "$work/certs/cert.pem" "$work/certs/live-cert.pem"
certsync_install_export "$work/certs/live-cert.pem" "$work/certs/key.pem" \
    || fail "export install rejected a valid pair"
[ -x "$WILDPAQET_CERTSYNC_EXPORT" ] || fail "export script is not executable"
listing=$("$WILDPAQET_CERTSYNC_EXPORT" | tar -tz | sort | tr '\n' ' ')
[ "$listing" = "cert.pem key.pem " ] || fail "export listing was '$listing'"
# The stream must carry the certificate itself, not the symlink.
"$WILDPAQET_CERTSYNC_EXPORT" | tar -xz -C "$work" cert.pem
cmp -s "$work/cert.pem" "$work/certs/cert.pem" || fail "export shipped the wrong bytes"
certsync_install_export "$work/certs/missing.pem" "$work/certs/key.pem" >/dev/null 2>&1 \
    && fail "export install accepted a missing certificate"
ok

sec "a peer key is pinned to the export command"
pub="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYMATERIALAAAAAAAAAAAAAAAAAAAA peer@one"
certsync_authorize_peer "$pub" || fail "a valid key was rejected"
line=$(cat "$WILDPAQET_CERTSYNC_AUTHKEYS")
case "$line" in
    "command=\"$WILDPAQET_CERTSYNC_EXPORT\","*) ;;
    *) fail "the authorized_keys line is not pinned to the export command: $line" ;;
esac
grep -q 'restrict\|no-pty' <<<"$line" || fail "the key was added without restrictions"
# The same key twice must not stack up lines.
certsync_authorize_peer "$pub" >/dev/null
[ "$(wc -l < "$WILDPAQET_CERTSYNC_AUTHKEYS" | tr -d ' ')" = "1" ] || fail "a duplicate key was appended"
certsync_authorize_peer "not-a-key" >/dev/null 2>&1 && fail "a non-key string was accepted"
certsync_authorize_peer "$(printf 'ssh-ed25519 AAAA x\nssh-ed25519 BBBB y')" >/dev/null 2>&1 \
    && fail "a two-line value was accepted"
ok

sec "the pull script refuses anything that would break TLS"
certsync_install_pull "root@198.51.100.7" "crm.example.test" \
    "$work/dest/cert.pem" "$work/dest/key.pem" || fail "pull install failed"
[ -x "$WILDPAQET_CERTSYNC_PULL" ] || fail "pull script is not executable"
grep -q 'checkhost' "$WILDPAQET_CERTSYNC_PULL" || fail "pull does not verify the certificate name"
grep -q 'checkend' "$WILDPAQET_CERTSYNC_PULL" || fail "pull does not warn before expiry"
grep -q 'StrictHostKeyChecking' "$WILDPAQET_CERTSYNC_PULL" || fail "pull does not set a host key policy"
grep -q 'systemctl' "$WILDPAQET_CERTSYNC_PULL" && fail "pull restarts the service; the core hot-reloads instead"

# Drive the validation with a stub ssh, so the checks run for real rather than
# being asserted from the source text.
mkdir -p "$work/stub" "$work/dest" "$work/payload"
cat > "$work/stub/ssh" <<'STUB'
#!/bin/sh
cat "$WP_TEST_BUNDLE"
STUB
chmod +x "$work/stub/ssh"
export PATH="$work/stub:$PATH"

bundle_of() { tar -czf "$work/bundle.tgz" -C "$1" cert.pem key.pem; export WP_TEST_BUNDLE="$work/bundle.tgz"; }

make_pair "$work/payload" "crm.example.test" 90
bundle_of "$work/payload"
"$WILDPAQET_CERTSYNC_PULL" || fail "a good bundle was refused"
cmp -s "$work/payload/cert.pem" "$work/dest/cert.pem" || fail "the certificate was not installed"
[ "$(stat -c %a "$work/dest/key.pem")" = "600" ] || fail "the private key is not 600"
good=$(cat "$work/dest/cert.pem")

before=$(stat -c %Y "$work/dest/cert.pem")
"$WILDPAQET_CERTSYNC_PULL" || fail "an unchanged bundle was treated as an error"
[ "$before" = "$(stat -c %Y "$work/dest/cert.pem")" ] || fail "an unchanged bundle rewrote the file"

# A certificate for another name parses and matches its key, and would still
# fail on the client, which verifies the name.
wrong="$work/wrong"; mkdir -p "$wrong"
make_pair "$wrong" "somewhere.else.test" 90
bundle_of "$wrong"
"$WILDPAQET_CERTSYNC_PULL" >/dev/null 2>&1 && fail "a certificate for the wrong name was accepted"
[ "$(cat "$work/dest/cert.pem")" = "$good" ] || fail "the working certificate was replaced by the wrong one"

# A key that does not belong to the certificate breaks every handshake.
other="$work/other"; mkdir -p "$other"; mix="$work/mix"; mkdir -p "$mix"
make_pair "$other" "crm.example.test" 90
cp "$work/payload/cert.pem" "$mix/cert.pem"; cp "$other/key.pem" "$mix/key.pem"
bundle_of "$mix"
"$WILDPAQET_CERTSYNC_PULL" >/dev/null 2>&1 && fail "a mismatched pair was accepted"
[ "$(cat "$work/dest/cert.pem")" = "$good" ] || fail "a mismatched pair replaced the working one"

trunc="$work/trunc"; mkdir -p "$trunc"
head -c 200 "$work/payload/cert.pem" > "$trunc/cert.pem"; cp "$work/payload/key.pem" "$trunc/key.pem"
bundle_of "$trunc"
"$WILDPAQET_CERTSYNC_PULL" >/dev/null 2>&1 && fail "a truncated certificate was accepted"
[ "$(cat "$work/dest/cert.pem")" = "$good" ] || fail "a truncated certificate replaced the working one"
ok

sec "removal leaves nothing behind"
certsync_write_state replica crm.example.test root@198.51.100.7 "$work/dest/cert.pem" "$work/dest/key.pem"
[ -f "$WILDPAQET_CERTSYNC_STATE" ] || fail "state file was not written"
: > "$WILDPAQET_CERTSYNC_KEY"; : > "$WILDPAQET_CERTSYNC_KEY.pub"
printf 'ssh-ed25519 AAAAUNRELATED admin@laptop\n' >> "$WILDPAQET_CERTSYNC_AUTHKEYS"
certsync_remove_silent
for p in "$WILDPAQET_CERTSYNC_EXPORT" "$WILDPAQET_CERTSYNC_PULL" \
         "$WILDPAQET_CERTSYNC_KEY" "$WILDPAQET_CERTSYNC_KEY.pub" "$WILDPAQET_CERTSYNC_STATE"; do
    [ -e "$p" ] && fail "survived removal: $p"
done
grep -q 'wp-cert-export' "$WILDPAQET_CERTSYNC_AUTHKEYS" && fail "a pinned peer line survived removal"
grep -q 'AAAAUNRELATED' "$WILDPAQET_CERTSYNC_AUTHKEYS" \
    || fail "removal deleted an administrator key it does not own"
ok

sec "the uninstall verifier knows about every artifact"
for fn in certsync_remove_silent certsync_install_export certsync_install_pull \
          certsync_authorize_peer cert_sync_menu certsync_status; do
    declare -F "$fn" >/dev/null || fail "missing function: $fn"
done
grep -q 'certsync_remove_silent' "$repo_root/wildpaqet.sh" || fail "uninstall does not call the cleanup"
awk '/^verify_full_uninstall_cleanup\(\)/,/^}/' "$repo_root/wildpaqet.sh" > "$work/verify.txt"
for token in CERTSYNC_EXPORT_SCRIPT CERTSYNC_PULL_SCRIPT CERTSYNC_KEY CERTSYNC_STATE_FILE CERTSYNC_CRON_MARK; do
    grep -q "$token" "$work/verify.txt" || fail "the verifier does not check $token"
done
ok

if [ "$failures" -ne 0 ]; then
    echo "cert-sync: $failures failure(s)" >&2
    exit 1
fi
echo "cert-sync: PASS"
