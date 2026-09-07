#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

config_dir="$test_root/etc/paqet"
service_dir="$test_root/etc/systemd/system"
bin_dir="$test_root/usr/local/bin"
backup_dir="$test_root/backups"
mock_dir="$test_root/mock-bin"
mkdir -p "$config_dir" "$service_dir" "$bin_dir" "$backup_dir" "$mock_dir"

export TEST_CRONTAB_FILE="$test_root/crontab"
cat > "$mock_dir/systemctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    is-enabled|is-active) exit 0 ;;
    *) exit 0 ;;
esac
EOF
cat > "$mock_dir/crontab" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    -l)
        [ -f "$TEST_CRONTAB_FILE" ] && cat "$TEST_CRONTAB_FILE" || exit 1
        ;;
    -r)
        rm -f "$TEST_CRONTAB_FILE"
        ;;
    *)
        cp "$1" "$TEST_CRONTAB_FILE"
        ;;
esac
EOF
chmod +x "$mock_dir/systemctl" "$mock_dir/crontab"
export PATH="$mock_dir:$PATH"

cat > "$bin_dir/paqet" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = version ]; then
    echo 'Version: v-test'
fi
EOF
chmod +x "$bin_dir/paqet"
cp "$repo_dir/wildpaqet.sh" "$bin_dir/wildpaqet"
chmod +x "$bin_dir/wildpaqet"

printf '%s\n' 'test-ca' > "$config_dir/custom-ca.crt"
mkdir -p "$test_root/external-tls"
printf '%s\n' 'test-server-certificate' > "$test_root/external-tls/server.crt"
printf '%s\n' 'test-server-private-key' > "$test_root/external-tls/server.key"
cat > "$config_dir/england.yaml" <<EOF
role: "client"
forward:
  - listen: "0.0.0.0:2083"
    target: "127.0.0.1:2083"
    protocol: "tcp"
server:
  addr: "203.0.113.10:443"
transport:
  protocol: "tls"
  conn: 4
  tls:
    mode: "h2"
    server_name: "example.test"
    ca_file: "$config_dir/custom-ca.crt"
    secret: "01234567890123456789012345678901"
    alpn: "h2"
    cover_path: "/api/v1/test/events"
EOF
cat > "$config_dir/france.yaml" <<EOF
role: "server"
listen:
  addr: ":443"
transport:
  protocol: "tls"
  tls:
    mode: "h2"
    server_name: "example.test"
    cert_file: "$test_root/external-tls/server.crt"
    key_file: "$test_root/external-tls/server.key"
    secret: "12345678901234567890123456789012"
    alpn: "h2"
    cover_path: "/api/v1/test/events"
EOF
cat > "$TEST_CRONTAB_FILE" <<'EOF'
0 * * * * systemctl restart paqet-england.service
0 * * * * systemctl restart paqet-england.service; touch /tmp/unsafe
EOF

export WILDPAQET_LIB_ONLY=1
export WILDPAQET_CONFIG_DIR="$config_dir"
export WILDPAQET_SERVICE_DIR="$service_dir"
export WILDPAQET_BIN_DIR="$bin_dir"
export WILDPAQET_MANAGER_PATH="$bin_dir/wildpaqet"
export WILDPAQET_INSTALL_DIR="$test_root/opt/paqet"
export WILDPAQET_BACKUP_DIR="$backup_dir"
export WILDPAQET_PORTABLE_BACKUP_DIR="$backup_dir"
export WILDPAQET_STATE_DIR="$test_root/var/lib/wildpaqet"
# shellcheck source=../wildpaqet.sh
source "$repo_dir/wildpaqet.sh"

portable_backup_create test
archive="$PORTABLE_BACKUP_CREATED"
[ -s "$archive" ]
[ -s "$archive.sha256" ]
portable_backup_prepare "$archive"
if grep -Fq 'touch /tmp/unsafe' "$PORTABLE_RESTORE_ROOT/state/cron.txt"; then
    echo 'unsafe cron entry was included in backup' >&2
    exit 1
fi
[ -f "$PORTABLE_RESTORE_ROOT/tls-assets/france/cert_file.pem" ]
[ -f "$PORTABLE_RESTORE_ROOT/tls-assets/france/key_file.pem" ]
portable_backup_cleanup_prepare
sidecar_bad="$test_root/sidecar-bad.tar.gz"
cp "$archive" "$sidecar_bad"
printf '%064d  %s\n' 0 "$(basename "$sidecar_bad")" > "$sidecar_bad.sha256"
if portable_backup_prepare "$sidecar_bad"; then
    echo 'archive with a wrong external checksum was incorrectly accepted' >&2
    exit 1
fi
portable_backup_prepare "$archive"
tamper_dir="$test_root/tampered"
mkdir -p "$tamper_dir"
cp -a "$PORTABLE_RESTORE_ROOT" "$tamper_dir/wildpaqet-backup"
printf '%s\n' '# tampered' >> "$tamper_dir/wildpaqet-backup/configs/england.yaml"
tar -czf "$test_root/tampered.tar.gz" -C "$tamper_dir" wildpaqet-backup
portable_backup_cleanup_prepare
if portable_backup_prepare "$test_root/tampered.tar.gz"; then
    echo 'tampered archive was incorrectly accepted' >&2
    exit 1
fi

mkdir -p "$test_root/unsafe"
printf '%s\n' unsafe > "$test_root/unsafe/not-wildpaqet"
tar -czf "$test_root/unsafe.tar.gz" -C "$test_root/unsafe" not-wildpaqet
if portable_backup_prepare "$test_root/unsafe.tar.gz"; then
    echo 'unsafe archive layout was incorrectly accepted' >&2
    exit 1
fi

rm -rf "$config_dir" "$service_dir"
rm -f "$bin_dir/paqet" "$TEST_CRONTAB_FILE"
mkdir -p "$service_dir"

portable_backup_restore "$archive" <<'EOF'
RESTORE
y
EOF

[ -x "$bin_dir/paqet" ]
[ -f "$config_dir/england.yaml" ]
[ -f "$config_dir/france.yaml" ]
[ -f "$service_dir/paqet-england.service" ]
[ -f "$service_dir/paqet-france.service" ]
grep -Fq 'secret: "01234567890123456789012345678901"' "$config_dir/england.yaml"
grep -Fq "ca_file: \"$config_dir/tls/england/restored-ca_file.pem\"" "$config_dir/england.yaml"
[ -f "$config_dir/tls/england/restored-ca_file.pem" ]
grep -Fq "cert_file: \"$config_dir/tls/france/restored-cert_file.pem\"" "$config_dir/france.yaml"
grep -Fq "key_file: \"$config_dir/tls/france/restored-key_file.pem\"" "$config_dir/france.yaml"
[ -f "$config_dir/tls/france/restored-cert_file.pem" ]
[ -f "$config_dir/tls/france/restored-key_file.pem" ]
grep -Fq 'systemctl restart paqet-england.service' "$TEST_CRONTAB_FILE"
if grep -Fq 'touch /tmp/unsafe' "$TEST_CRONTAB_FILE"; then
    echo 'unsafe cron entry was restored' >&2
    exit 1
fi

echo 'portable backup/restore test: OK'
