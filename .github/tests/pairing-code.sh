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

# A pasted code survives terminal wrapping, CRLF clipboards and shell quotes.
v3_decode_pairing_code "  ${code:0:100}"$'\r\n'"${code:100} " "$test_dir/wrapped.crt"
cmp "$test_dir/server.crt" "$test_dir/wrapped.crt"
v3_decode_pairing_code "\"$code\"" "$test_dir/quoted.crt"
cmp "$test_dir/server.crt" "$test_dir/quoted.crt"

# A code that a terminal cut short must stay "incomplete" so the wizard keeps
# collecting the rest instead of blaming the certificate.
if v3_decode_pairing_code "${code:0:400}" "$test_dir/partial.crt"; then
	echo 'truncated code was accepted' >&2
	exit 1
fi
test "$V3_PAIR_ERROR" = 'incomplete'
if v3_decode_pairing_code "WPQ9|aaa|bbb|ccc" "$test_dir/future.crt"; then
	echo 'unknown code version was accepted' >&2
	exit 1
fi
test "$V3_PAIR_ERROR" = 'version'
if v3_decode_pairing_code 'not-a-code' "$test_dir/junk.crt"; then
	echo 'non-code text was accepted' >&2
	exit 1
fi
test "$V3_PAIR_ERROR" = 'format'

# Chunked paste: joining the printed lines must rebuild the same code.
chunked=""
for ((i = 0; i < ${#code}; i += 120)); do
	chunked+=$(v3_sanitize_pairing_code "${code:i:120}")
done
test "$chunked" = "$code"
v3_decode_pairing_code "$chunked" "$test_dir/chunked.crt"
cmp "$test_dir/server.crt" "$test_dir/chunked.crt"

# A real certificate chain is longer than a terminal can accept on one line, so
# it is printed as a block that ends with the completion marker and rebuilds
# into the whole chain, not just its first certificate.
openssl req -x509 -newkey rsa:4096 -sha256 -days 2 -nodes \
	-keyout "$test_dir/root.key" -out "$test_dir/root.crt" -subj '/CN=WildPaqet Test Root' >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes \
	-keyout "$test_dir/leaf.key" -out "$test_dir/leaf.csr" -subj '/CN=pay.wilduser.org' >/dev/null 2>&1
openssl x509 -req -in "$test_dir/leaf.csr" -CA "$test_dir/root.crt" -CAkey "$test_dir/root.key" \
	-CAcreateserial -days 1 -sha256 -extfile <(printf 'subjectAltName=DNS:pay.wilduser.org\nextendedKeyUsage=serverAuth\n') \
	-out "$test_dir/leaf.crt" >/dev/null 2>&1
cat "$test_dir/leaf.crt" "$test_dir/root.crt" > "$test_dir/fullchain.pem"
chain_code=$(v3_create_pairing_code \
	"$test_dir/fullchain.pem" '203.0.113.10:443' 'pay.wilduser.org' '/api/v1/test/events')
test "${#chain_code}" -gt 3000
block=$(v3_print_pairing_code "$chain_code" | grep -E '^[A-Za-z0-9+/=|]+$')
test "$(printf '%s\n' "$block" | tail -n 1)" = "$V3_PAIR_BLOCK_END"
joined=""
while IFS= read -r block_line; do
	block_line=$(v3_sanitize_pairing_code "$block_line")
	[ "$block_line" = "$V3_PAIR_BLOCK_END" ] && continue
	joined+="$block_line"
done <<< "$block"
test "$joined" = "$chain_code"
v3_decode_pairing_code "$joined" "$test_dir/chain.crt"
cmp "$test_dir/fullchain.pem" "$test_dir/chain.crt"

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
