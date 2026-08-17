#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export WILDPAQET_LIB_ONLY=1
source "$repo_root/wildpaqet.sh"

test_dir=$(mktemp -d /tmp/wildpaqet-pair-test.XXXXXX)
cleanup_pair_test() {
    case "$test_dir" in
        /tmp/wildpaqet-pair-test.*) rm -rf -- "$test_dir" ;;
        *) echo "unsafe temp path: $test_dir" >&2; return 1 ;;
    esac
}
trap cleanup_pair_test EXIT

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -sha256 -days 2 -nodes \
    -keyout "$test_dir/server.key" -out "$test_dir/server.crt" \
    -subj '/CN=pay.wilduser.org' \
    -addext 'subjectAltName=DNS:pay.wilduser.org' \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,digitalSignature,keyCertSign' \
    -addext 'extendedKeyUsage=serverAuth' >/dev/null 2>&1

code=$(v3_create_pairing_code \
	"$test_dir/server.crt" '203.0.113.10:443' 'pay.wilduser.org' '/api/v1/test/events')
v3_decode_pairing_code "$code" "$test_dir/imported.crt"
test "$V3_PAIR_ENDPOINT" = '203.0.113.10:443'
test "$V3_PAIR_IDENTITY" = 'pay.wilduser.org'
test "$V3_PAIR_MODE" = 'h2'
test "$V3_PAIR_COVER_PATH" = '/api/v1/test/events'
cmp "$test_dir/server.crt" "$test_dir/imported.crt"

legacy_code=$(v3_create_pairing_code \
	"$test_dir/server.crt" '203.0.113.10:443' 'pay.wilduser.org')
v3_decode_pairing_code "$legacy_code" "$test_dir/legacy.crt"
test "$V3_PAIR_MODE" = 'direct'
test -z "$V3_PAIR_COVER_PATH"

if v3_create_pairing_code \
	"$test_dir/server.crt" '203.0.113.10:443' 'pay.wilduser.org' '/../bad?path' >/dev/null; then
	echo 'unsafe cover path was accepted' >&2
	exit 1
fi
if v3_validate_cover_path '/api/../admin'; then
	echo 'traversal cover path was accepted' >&2
	exit 1
fi

if v3_create_pairing_code \
    "$test_dir/server.crt" '203.0.113.10:443' 'wrong.wilduser.org' >/dev/null; then
    echo 'certificate-name mismatch was accepted' >&2
    exit 1
fi
if v3_validate_endpoint 'bad"host:443'; then
    echo 'unsafe endpoint was accepted' >&2
    exit 1
fi

echo 'pairing-code-roundtrip: PASS'
