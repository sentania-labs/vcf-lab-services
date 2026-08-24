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

validate_uid_gid "1003:1003" || fail "valid SFTP UID:GID rejected"
validate_uid_gid "0:1003" 2>/dev/null && fail "root SFTP UID accepted"
validate_uid_gid "1003" 2>/dev/null && fail "UID without GID accepted"
validate_uid_gid "name:1003" 2>/dev/null && fail "non-numeric UID accepted"
validate_tcp_port "2222" || fail "valid SFTP port rejected"
validate_tcp_port "0" 2>/dev/null && fail "TCP port zero accepted"
validate_tcp_port "65536" 2>/dev/null && fail "TCP port above 65535 accepted"

ss() {
	printf 'LISTEN 0 128 0.0.0.0:2222 0.0.0.0:*\n'
}
host_tcp_port_is_bound 2222 || fail "bound host port was not detected"
host_tcp_port_is_bound 2223 && fail "free host port was reported as bound"
unset -f ss

docker() {
	printf '2222\n'
}
container_publishes_tcp_port test-container 2222 || fail "container host port was not detected"
container_publishes_tcp_port test-container 2223 && fail "wrong container host port was accepted"
unset -f docker
paths_are_disjoint /srv/depot /srv/backup || fail "sibling depot and backup paths rejected"
paths_are_disjoint /srv/depot /srv/depot/backup 2>/dev/null && fail "backup path inside the depot accepted"
paths_are_disjoint /srv/depot/inner /srv/depot 2>/dev/null && fail "backup path containing the depot accepted"
paths_are_disjoint /srv/depot /srv/depot/ 2>/dev/null && fail "identical depot and backup paths accepted"
paths_are_disjoint /srv/depot "" 2>/dev/null && fail "empty backup path accepted"
paths_are_disjoint /srv/depot /srv/depot-archive || fail "shared path prefix wrongly treated as nested"
paths_are_disjoint /exports/depot /exports/depot/../depot/backup 2>/dev/null \
	&& fail "backup path with a .. segment accepted"
paths_are_disjoint /exports/depot/../depot /exports/backup 2>/dev/null \
	&& fail "depot path with a .. segment accepted"
paths_are_disjoint /srv/depot..archive /srv/backup || fail "a literal .. inside a name wrongly rejected"

check_backup_free_space $((200 * 1024 * 1024)) /srv/backup "" 100 >/dev/null \
	|| fail "healthy backup capacity reported a problem"
low_capacity_output="$(check_backup_free_space $((10 * 1024 * 1024)) /srv/backup "" 100 2>&1)" \
	|| fail "low backup capacity must warn, not fail"
grep -q "^WARNING" <<< "$low_capacity_output" || fail "low backup capacity warning missing"
check_backup_free_space $((10 * 1024 * 1024)) /srv/backup 100 100 2>/dev/null \
	&& fail "requested hard backup floor was not enforced"
check_backup_free_space $((200 * 1024 * 1024)) /srv/backup 100 100 >/dev/null \
	|| fail "hard backup floor rejected sufficient space"
echo "SFTP installer validation tests passed"

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
ln -s /etc/passwd "$wrong_root_depot/umds-patch-store"
wrong_root_error="$(validate_depot_fixture "$wrong_root_depot" 2>&1)" \
	&& fail "adopted depot with an incompatible absolute symlink accepted"
grep -q 'resolves outside /depot' <<< "$wrong_root_error" \
	|| fail "wrong-root symlink error did not explain the /depot constraint"

absolute_escape_depot="$work_dir/absolute-escape-depot"
cp -a "$valid_depot" "$absolute_escape_depot"
rm "$absolute_escape_depot/umds-patch-store"
ln -s /depot/../etc/passwd "$absolute_escape_depot/umds-patch-store"
absolute_escape_error="$(validate_depot_fixture "$absolute_escape_depot" 2>&1)" \
	&& fail "adopted depot with an absolute dot-dot symlink escape accepted"
grep -q 'resolves outside /depot as /etc/passwd' <<< "$absolute_escape_error" \
	|| fail "absolute dot-dot escape error did not name the resolved path"

relative_escape_depot="$work_dir/relative-escape-depot"
cp -a "$valid_depot" "$relative_escape_depot"
rm "$relative_escape_depot/umds-patch-store"
ln -s ../../etc/passwd "$relative_escape_depot/umds-patch-store"
relative_escape_error="$(validate_depot_fixture "$relative_escape_depot" 2>&1)" \
	&& fail "adopted depot with a relative symlink escape accepted"
grep -q 'resolves outside /depot as /etc/passwd' <<< "$relative_escape_error" \
	|| fail "relative escape error did not name the resolved path"

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

docker run --rm --entrypoint /bin/sh \
	--mount "type=volume,src=$partial_target,dst=/state" \
	"$state_test_image" -c 'mkdir -p /state/.vcf-services-import-staging'
stale_marker_error="$("$project_dir/scripts/import-vcfdt-state.sh" \
	"$state_test_image" directory "$conflict_source" "$partial_target" 2>&1)" \
	&& fail "a stale import marker let a different Software Depot ID be wiped"
grep -q 'refusing to overwrite' <<< "$stale_marker_error" \
	|| fail "stale import marker conflict did not explain the overwrite refusal"
stale_marker_id="$(docker run --rm --entrypoint /opt/vcfdt/bin/vcf-download-tool \
	--mount "type=volume,src=$partial_target,dst=/root/.local/share/vmware/vdt,readonly" \
	"$state_test_image" configuration get --machineId)"
[ "$stale_marker_id" = '22222222-2222-4222-8222-222222222222' ] \
	|| fail "stale import marker conflict changed the existing target ID"

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
