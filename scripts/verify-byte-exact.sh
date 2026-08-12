#!/bin/bash
set -euo pipefail

base_url="${1:?usage: verify-byte-exact.sh BASE_URL RESOLVE_HOST_PORT_IP}"
resolve_arg="${2:?usage: verify-byte-exact.sh BASE_URL RESOLVE_HOST_PORT_IP}"
: "${AUTH_USERNAME:?set AUTH_USERNAME}"
: "${AUTH_PASSWORD:?set AUTH_PASSWORD}"

work_dir="$(mktemp -d /tmp/vcf-services-range.XXXXXX)"
test_path=".vcf-services-byte-test"
cleanup() {
	docker exec vcf-services-sync rm -f "/depot/$test_path" >/dev/null 2>&1 || true
	rm -rf "$work_dir"
}
trap cleanup EXIT

printf '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\n' > "$work_dir/source"
docker cp "$work_dir/source" "vcf-services-sync:/depot/$test_path"
dd if="$work_dir/source" of="$work_dir/expected" bs=1 skip=11 count=17 status=none

curl -kfsS --resolve "$resolve_arg" -u "$AUTH_USERNAME:$AUTH_PASSWORD" \
	-H 'Range: bytes=11-27' -D "$work_dir/headers" \
	-o "$work_dir/actual" "$base_url/$test_path"

grep -Eqi '^Accept-Ranges:[[:space:]]*bytes[[:space:]]*$' "$work_dir/headers"
if grep -Eqi '^Content-Encoding:' "$work_dir/headers"; then
	echo "ERROR: byte-exact response unexpectedly has Content-Encoding" >&2
	exit 1
fi
cmp "$work_dir/expected" "$work_dir/actual"
echo "Byte-exact Range self-test passed"
