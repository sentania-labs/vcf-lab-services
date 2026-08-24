#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work_dir="$(mktemp -d /tmp/vcf-services-install-checks-test.XXXXXX)"
state_test_image="vcf-services-state-import-test-$$"
state_test_volumes=()
cleanup() {
	local volume
	for volume in "${state_test_volumes[@]}"; do
		docker volume rm "$volume" >/dev/null 2>&1 || true
	done
	docker image rm "$state_test_image" >/dev/null 2>&1 || true
	rm -rf "$work_dir"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# shellcheck source=/dev/null
source "$project_dir/scripts/install-checks.sh"

validate_cron_schedule "0 3 * * 0" || fail "default schedule rejected"
validate_cron_schedule "*/15 2-5 1,15 6 7" || fail "list, range, and step schedule rejected"
validate_cron_schedule "59 23 31 12 0" || fail "upper-bound schedule rejected"
validate_cron_schedule "60 * * * *" 2>/dev/null && fail "minute 60 accepted"
validate_cron_schedule "0 24 * * *" 2>/dev/null && fail "hour 24 accepted"
validate_cron_schedule "0 3 0 * *" 2>/dev/null && fail "day-of-month 0 accepted"
validate_cron_schedule "0 3 32 * *" 2>/dev/null && fail "day-of-month 32 accepted"
validate_cron_schedule "0 3 * 0 *" 2>/dev/null && fail "month 0 accepted"
validate_cron_schedule "0 3 * 13 *" 2>/dev/null && fail "month 13 accepted"
validate_cron_schedule "0 3 * * 8" 2>/dev/null && fail "day-of-week 8 accepted"
validate_cron_schedule "0 3 * *" 2>/dev/null && fail "four-field schedule accepted"
validate_cron_schedule "10-5 * * * *" 2>/dev/null && fail "inverted range accepted"
validate_cron_schedule "*/0 * * * *" 2>/dev/null && fail "zero step accepted"
echo "cron bounds tests passed"

fqdn="depot.example.test"
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 2 \
	-keyout "$work_dir/good.key" -out "$work_dir/good.crt" \
	-subj "/CN=$fqdn" -addext "subjectAltName=DNS:$fqdn" >/dev/null 2>&1
validate_provided_tls "$work_dir/good.crt" "$work_dir/good.key" "$fqdn" \
	|| fail "valid certificate rejected"
validate_provided_tls "$work_dir/good.crt" "$work_dir/good.key" "other.example.test" 2>/dev/null \
	&& fail "wrong-host certificate accepted"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
	-out "$work_dir/other.key" >/dev/null 2>&1
validate_provided_tls "$work_dir/good.crt" "$work_dir/other.key" "$fqdn" 2>/dev/null \
	&& fail "mismatched key accepted"

ca_dir="$work_dir/ca"
mkdir -p "$ca_dir"
touch "$ca_dir/index.txt"
echo 01 > "$ca_dir/serial"
cat > "$ca_dir/openssl.cnf" <<EOF
[ ca ]
default_ca = local
[ local ]
new_certs_dir = $ca_dir
database = $ca_dir/index.txt
serial = $ca_dir/serial
default_md = sha256
policy = anything
email_in_dn = no
[ anything ]
commonName = supplied
[ v3_server ]
subjectAltName = DNS:$fqdn
EOF
openssl req -new -key "$work_dir/good.key" -subj "/CN=$fqdn" \
	-out "$work_dir/expired.csr" >/dev/null 2>&1
openssl ca -config "$ca_dir/openssl.cnf" -selfsign -batch \
	-keyfile "$work_dir/good.key" -in "$work_dir/expired.csr" \
	-startdate 20200101000000Z -enddate 20200102000000Z \
	-extensions v3_server -notext -out "$work_dir/expired.crt" >/dev/null 2>&1
[ -s "$work_dir/expired.crt" ] || fail "could not mint an expired test certificate"
expired_error="$(validate_provided_tls "$work_dir/expired.crt" "$work_dir/good.key" "$fqdn" 2>&1)" \
	&& fail "expired certificate accepted"
grep -qi "expired" <<< "$expired_error" || fail "expired certificate error message missing"
echo "tls validation tests passed"

validate_depot_fixture() {
	local fixture="$1"
	docker run --rm \
		--mount "type=bind,src=$fixture,dst=/depot,readonly" \
		--mount "type=bind,src=$project_dir/scripts/validate-adopted-depot.sh,dst=/validate-adopted-depot.sh,readonly" \
		alpine:3.20 sh /validate-adopted-depot.sh /depot
}

valid_depot="$project_dir/tests/fixtures/adopt-depot-valid"
invalid_depot="$project_dir/tests/fixtures/adopt-depot-invalid"
validate_depot_fixture "$valid_depot" >/dev/null || fail "valid-looking adopted depot rejected"

invalid_error="$(validate_depot_fixture "$invalid_depot" 2>&1)" \
	&& fail "invalid adopted depot accepted"
grep -q '/depot/PROD/COMP is missing' <<< "$invalid_error" \
	|| fail "invalid depot error did not name the missing VCFDT structure"

wrong_root_depot="$work_dir/wrong-root-depot"
cp -a "$valid_depot" "$wrong_root_depot"
rm "$wrong_root_depot/umds-patch-store"
ln -s /old-vcfdt/depot/PROD/COMP/ESX_HOST/patch-store "$wrong_root_depot/umds-patch-store"
wrong_root_error="$(validate_depot_fixture "$wrong_root_depot" 2>&1)" \
	&& fail "adopted depot with an incompatible absolute symlink accepted"
grep -q 'absolute symlinks must stay under /depot' <<< "$wrong_root_error" \
	|| fail "wrong-root symlink error did not explain the /depot constraint"

dangling_depot="$work_dir/dangling-depot"
cp -a "$valid_depot" "$dangling_depot"
rm "$dangling_depot/umds-patch-store"
ln -s /depot/PROD/COMP/missing "$dangling_depot/umds-patch-store"
dangling_error="$(validate_depot_fixture "$dangling_depot" 2>&1)" \
	&& fail "adopted depot with a dangling /depot symlink accepted"
grep -q 'does not resolve with the depot mounted at /depot' <<< "$dangling_error" \
	|| fail "dangling symlink error did not explain the resolution failure"
echo "adopted depot validation tests passed"

docker build -q -t "$state_test_image" "$project_dir/tests/fixtures/vcfdt-state-tool" >/dev/null
directory_source="$work_dir/vdt-state"
mkdir -p "$directory_source"
printf '11111111-1111-4111-8111-111111111111\n' > "$directory_source/machine_id"
printf 'source remains read-only\n' > "$directory_source/source-marker"
directory_source_hash="$(sha256sum "$directory_source/machine_id" "$directory_source/source-marker")"
directory_target="vcf-services-state-import-directory-$$"
state_test_volumes+=("$directory_target")
imported_id="$("$project_dir/scripts/import-vcfdt-state.sh" \
	"$state_test_image" directory "$directory_source" "$directory_target" 2>/dev/null)"
[ "$imported_id" = '11111111-1111-4111-8111-111111111111' ] \
	|| fail "directory state import returned the wrong Software Depot ID"
[ "$(sha256sum "$directory_source/machine_id" "$directory_source/source-marker")" = "$directory_source_hash" ] \
	|| fail "directory state source changed during import"
rerun_id="$("$project_dir/scripts/import-vcfdt-state.sh" \
	"$state_test_image" directory "$directory_source" "$directory_target" 2>/dev/null)"
[ "$rerun_id" = "$imported_id" ] || fail "state import rerun was not idempotent"

volume_source="vcf-services-state-import-source-$$"
volume_target="vcf-services-state-import-volume-$$"
state_test_volumes+=("$volume_source" "$volume_target")
docker volume create "$volume_source" >/dev/null
docker run --rm --entrypoint /bin/sh \
	--mount "type=volume,src=$volume_source,dst=/state" \
	"$state_test_image" -c "printf '%s\\n' '22222222-2222-4222-8222-222222222222' > /state/machine_id
printf 'source remains read-only\\n' > /state/source-marker"
volume_source_digest() {
	docker run --rm --entrypoint /bin/sh \
		--mount "type=volume,src=$volume_source,dst=/state,readonly" \
		"$state_test_image" -c 'cd /state && find . | sort | sha256sum && cat ./machine_id ./source-marker'
}
volume_source_state="$(volume_source_digest)"
volume_id="$("$project_dir/scripts/import-vcfdt-state.sh" \
	"$state_test_image" volume "$volume_source" "$volume_target" 2>/dev/null)"
[ "$volume_id" = '22222222-2222-4222-8222-222222222222' ] \
	|| fail "Docker volume state import returned the wrong Software Depot ID"
[ "$(volume_source_digest)" = "$volume_source_state" ] \
	|| fail "Docker volume state source changed during import"
imported_marker="$(docker run --rm --entrypoint /bin/sh \
	--mount "type=volume,src=$volume_target,dst=/state,readonly" \
	"$state_test_image" -c 'cat /state/source-marker; find /state -mindepth 1 -name ".vcf-services-import-staging"')"
[ "$imported_marker" = 'source remains read-only' ] \
	|| fail "Docker volume state import did not land a complete staged tree"

partial_target="vcf-services-state-import-partial-$$"
state_test_volumes+=("$partial_target")
docker volume create "$partial_target" >/dev/null
docker run --rm --entrypoint /bin/sh \
	--mount "type=volume,src=$partial_target,dst=/state" \
	"$state_test_image" -c "mkdir -p /state/.vcf-services-import-staging
printf '%s\\n' '22222222-2222-4222-8222-222222222222' > /state/machine_id"
partial_id="$("$project_dir/scripts/import-vcfdt-state.sh" \
	"$state_test_image" volume "$volume_source" "$partial_target" 2>/dev/null)"
[ "$partial_id" = '22222222-2222-4222-8222-222222222222' ] \
	|| fail "rerun after an incomplete state import did not recover"
partial_leftover="$(docker run --rm --entrypoint /bin/sh \
	--mount "type=volume,src=$partial_target,dst=/state,readonly" \
	"$state_test_image" -c 'find /state -mindepth 1 -name ".vcf-services-import-staging"')"
[ -z "$partial_leftover" ] || fail "incomplete state import staging directory survived a rerun"

conflict_source="$work_dir/conflict-state"
mkdir -p "$conflict_source"
printf '33333333-3333-4333-8333-333333333333\n' > "$conflict_source/machine_id"
conflict_error="$("$project_dir/scripts/import-vcfdt-state.sh" \
	"$state_test_image" directory "$conflict_source" "$volume_target" 2>&1)" \
	&& fail "state import overwrote a different Software Depot ID"
grep -q 'refusing to overwrite' <<< "$conflict_error" \
	|| fail "state conflict error did not explain the overwrite refusal"
preserved_id="$(docker run --rm --entrypoint /opt/vcfdt/bin/vcf-download-tool \
	--mount "type=volume,src=$volume_target,dst=/root/.local/share/vmware/vdt,readonly" \
	"$state_test_image" configuration get --machineId)"
[ "$preserved_id" = "$volume_id" ] || fail "state conflict changed the existing target ID"
echo "VCFDT state import tests passed"

echo "install checks tests passed"
