#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export WILDPAQET_LIB_ONLY=1

test_dir=$(mktemp -d /tmp/wildpaqet-cert-test.XXXXXX)
cleanup_cert_test() {
	case "$test_dir" in
		/tmp/wildpaqet-cert-test.*) rm -rf -- "$test_dir" ;;
		*) echo "unsafe temp path: $test_dir" >&2; return 1 ;;
	esac
}
trap cleanup_cert_test EXIT

# Certbot layout: the directory name does not have to match the certificate.
mkdir -p "$test_dir/letsencrypt/live/pay.wilduser.org-0001"
openssl req -x509 -newkey rsa:2048 -sha256 -days 2 -nodes \
	-keyout "$test_dir/letsencrypt/live/pay.wilduser.org-0001/privkey.pem" \
	-out "$test_dir/letsencrypt/live/pay.wilduser.org-0001/fullchain.pem" \
	-subj '/CN=pay.wilduser.org' \
	-addext 'subjectAltName=DNS:pay.wilduser.org,DNS:*.wilduser.org' >/dev/null 2>&1

# acme.sh layout: chain file plus a key named after the domain, not the folder.
mkdir -p "$test_dir/acme/cdn.wilduser.org_ecc"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -sha256 -days 2 -nodes \
	-keyout "$test_dir/acme/cdn.wilduser.org_ecc/cdn.wilduser.org.key" \
	-out "$test_dir/acme/cdn.wilduser.org_ecc/fullchain.cer" \
	-subj '/CN=cdn.wilduser.org' \
	-addext 'subjectAltName=DNS:cdn.wilduser.org' >/dev/null 2>&1

# A certificate whose neighbouring key belongs to something else must be skipped.
mkdir -p "$test_dir/broken"
openssl req -x509 -newkey rsa:2048 -sha256 -days 2 -nodes \
	-keyout "$test_dir/broken/other.key" -out "$test_dir/broken/fullchain.pem" \
	-subj '/CN=broken.wilduser.org' >/dev/null 2>&1
openssl genrsa -out "$test_dir/broken/privkey.pem" 2048 >/dev/null 2>&1
rm -f "$test_dir/broken/other.key"

export WILDPAQET_CERT_GLOBS="$test_dir/letsencrypt/live/*/fullchain.pem:$test_dir/acme/*/fullchain.cer:$test_dir/broken/fullchain.pem"
source "$repo_root/wildpaqet.sh"

mapfile -t pairs < <(v3_find_certificate_pairs)
test "${#pairs[@]}" -eq 2

certbot_line=$(printf '%s\n' "${pairs[@]}" | grep 'letsencrypt/live')
test "$(printf '%s' "$certbot_line" | cut -d'|' -f2)" = "$test_dir/letsencrypt/live/pay.wilduser.org-0001/privkey.pem"
printf '%s' "$certbot_line" | cut -d'|' -f3 | grep -q 'pay.wilduser.org'

acme_line=$(printf '%s\n' "${pairs[@]}" | grep 'acme/')
test "$(printf '%s' "$acme_line" | cut -d'|' -f2)" = "$test_dir/acme/cdn.wilduser.org_ecc/cdn.wilduser.org.key"

if printf '%s\n' "${pairs[@]}" | grep -q '/broken/'; then
	echo 'a certificate was paired with a foreign key' >&2
	exit 1
fi

v3_certificate_key_matches \
	"$test_dir/letsencrypt/live/pay.wilduser.org-0001/fullchain.pem" \
	"$test_dir/letsencrypt/live/pay.wilduser.org-0001/privkey.pem"
if v3_certificate_key_matches \
	"$test_dir/letsencrypt/live/pay.wilduser.org-0001/fullchain.pem" \
	"$test_dir/acme/cdn.wilduser.org_ecc/cdn.wilduser.org.key"; then
	echo 'a foreign key was accepted for this certificate' >&2
	exit 1
fi

v3_certificate_covers_name 'pay.wilduser.org,*.wilduser.org' 'pay.wilduser.org'
v3_certificate_covers_name 'PAY.WILDUSER.ORG' 'pay.wilduser.org'
v3_certificate_covers_name '*.wilduser.org' 'cdn.wilduser.org'
if v3_certificate_covers_name '*.wilduser.org' 'wilduser.org'; then
	echo 'a wildcard was accepted for the bare domain' >&2
	exit 1
fi
if v3_certificate_covers_name 'pay.wilduser.org' 'other.example.com'; then
	echo 'an unrelated name was accepted' >&2
	exit 1
fi

echo 'certificate-discovery: PASS'
