#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work_dir="$(mktemp -d /tmp/vcf-services-install-checks-test.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT

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
echo "SFTP installer validation tests passed"

echo "install checks tests passed"
