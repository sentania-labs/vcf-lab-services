#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work_dir="$(mktemp -d /tmp/vcf-services-compose-boot.XXXXXX)"
override_file="$work_dir/volumes.yml"
test_id="${VCF_COMPOSE_BOOT_ID:-$$}"
test_id="${test_id//[^A-Za-z0-9_.-]/-}"

export VCF_SERVICES_UI_IMAGE="${VCF_SERVICES_UI_IMAGE:-vcf-services-ui:ci}"
export VCF_SERVICES_SYNC_IMAGE="${VCF_SERVICES_SYNC_IMAGE:-vcf-services-sync-base:ci}"
export VCF_SERVICES_SFTP_IMAGE="${VCF_SERVICES_SFTP_IMAGE:-vcf-services-sftp:ci}"
export VCF_SERVICES_PULL_POLICY="${VCF_SERVICES_PULL_POLICY:-never}"

for image in "$VCF_SERVICES_UI_IMAGE" "$VCF_SERVICES_SYNC_IMAGE" "$VCF_SERVICES_SFTP_IMAGE"; do
	docker image inspect "$image" >/dev/null 2>&1 \
		|| { echo "FAIL: required local image is missing: $image" >&2; exit 1; }
done

cat > "$override_file" <<EOF
name: vcf-services-compose-test-${test_id}

services:
  bootstrap:
    container_name: vcf-services-compose-test-${test_id}-bootstrap
  depot-web:
    container_name: vcf-services-compose-test-${test_id}-depot-web
    ports: !override
      - target: 443
        published: "0"
        host_ip: 127.0.0.1
        protocol: tcp
  depot-sync:
    container_name: vcf-services-compose-test-${test_id}-sync
  sftp-backup:
    container_name: vcf-services-compose-test-${test_id}-sftp
    ports: !override
      - target: 22
        published: "0"
        host_ip: 127.0.0.1
        protocol: tcp
  admin-ui:
    container_name: vcf-services-compose-test-${test_id}-ui
  redis:
    container_name: vcf-services-compose-test-${test_id}-redis

volumes:
  depot_store:
    name: vcf-services-compose-test-${test_id}-depot
  backup_store:
    name: vcf-services-compose-test-${test_id}-backup
  vcfdt_state:
    name: vcf-services-compose-test-${test_id}-vcfdt-state
  vcfdt_tool:
    name: vcf-services-compose-test-${test_id}-vcfdt-tool
  sync_state:
    name: vcf-services-compose-test-${test_id}-sync-state
  caddy_data:
    name: vcf-services-compose-test-${test_id}-caddy-data
  caddy_config:
    name: vcf-services-compose-test-${test_id}-caddy-config
  sftp_host_keys:
    name: vcf-services-compose-test-${test_id}-sftp-host-keys
  config_state:
    name: vcf-services-compose-test-${test_id}-config
  secrets_state:
    name: vcf-services-compose-test-${test_id}-secrets
EOF

compose=(docker compose -f "$project_dir/docker-compose.yml" -f "$override_file")
started=false
cleanup() {
	if [ "$started" = true ]; then
		"${compose[@]}" down --volumes >/dev/null 2>&1 || true
	fi
	rm -rf "$work_dir"
}
diagnose() {
	status=$?
	if [ "$status" -ne 0 ] && [ "$started" = true ]; then
		"${compose[@]}" ps --all >&2 || true
		"${compose[@]}" logs --no-color --tail=100 >&2 || true
	fi
	cleanup
	exit "$status"
}
trap diagnose EXIT

base_config="$work_dir/base-config.json"
test_config="$work_dir/test-config.json"
docker compose -f "$project_dir/docker-compose.yml" config --format json > "$base_config"
"${compose[@]}" config --format json > "$test_config"
python3 - "$base_config" "$test_config" <<'PY'
import json
import sys

services = ("bootstrap", "depot-web", "depot-sync", "sftp-backup", "admin-ui", "redis")
with open(sys.argv[1], encoding="utf-8") as stream:
    base = json.load(stream)
with open(sys.argv[2], encoding="utf-8") as stream:
    test = json.load(stream)

if not base.get("name") or not test.get("name") or base["name"] == test["name"]:
    raise SystemExit("FAIL: Compose boot test project name is not isolated")

for service in services:
    base_name = base.get("services", {}).get(service, {}).get("container_name")
    test_name = test.get("services", {}).get(service, {}).get("container_name")
    if not base_name or not test_name or base_name == test_name:
        raise SystemExit(f"FAIL: Compose boot test container is not isolated: {service}")

published_ports = {
    "depot-web": 443,
    "sftp-backup": 22,
}
for service, target in published_ports.items():
    ports = test.get("services", {}).get(service, {}).get("ports", [])
    if len(ports) != 1:
        raise SystemExit(f"FAIL: Compose boot test has unexpected published ports: {service}")
    port = ports[0]
    if (port.get("target") != target or port.get("published") != "0"
            or port.get("host_ip") != "127.0.0.1" or port.get("protocol") != "tcp"):
        raise SystemExit(f"FAIL: Compose boot test port is not a dynamic loopback binding: {service}")
PY

started=true
"${compose[@]}" up -d

mapfile -t services < <("${compose[@]}" config --services)
deadline=$((SECONDS + 180))
while true; do
	pending=()
	for service in "${services[@]}"; do
		container_id="$("${compose[@]}" ps --all -q "$service")"
		if [ -z "$container_id" ]; then
			pending+=("$service (not created)")
			continue
		fi
		state="$(docker inspect "$container_id" --format '{{.State.Status}}')"
		health="$(docker inspect "$container_id" --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}')"
		if [ "$service" = bootstrap ]; then
			exit_code="$(docker inspect "$container_id" --format '{{.State.ExitCode}}')"
			if [ "$state" = exited ] && [ "$exit_code" = 0 ]; then
				continue
			fi
		elif [ -n "$health" ]; then
			if [ "$state" = running ] && [ "$health" = healthy ]; then
				continue
			fi
		elif [ "$state" = running ]; then
			continue
		fi
		if [ "$state" = exited ] || [ "$state" = dead ] || [ "$health" = unhealthy ]; then
			echo "FAIL: $service reached terminal state: state=$state health=${health:-none}" >&2
			exit 1
		fi
		pending+=("$service (state=$state health=${health:-none})")
	done
	[ "${#pending[@]}" -gt 0 ] || break
	if [ "$SECONDS" -ge "$deadline" ]; then
		printf 'FAIL: Compose services did not become ready: %s\n' "${pending[*]}" >&2
		exit 1
	fi
	sleep 2
done

https_endpoint="$("${compose[@]}" port depot-web 443)"
sftp_endpoint="$("${compose[@]}" port sftp-backup 22)"
https_port="${https_endpoint##*:}"
sftp_port="${sftp_endpoint##*:}"
[[ "$https_endpoint" = 127.0.0.1:* && "$https_port" =~ ^[0-9]+$ && "$https_port" -gt 0 ]] \
	|| { echo "FAIL: Compose did not publish HTTPS on a dynamic loopback port: $https_endpoint" >&2; exit 1; }
[[ "$sftp_endpoint" = 127.0.0.1:* && "$sftp_port" =~ ^[0-9]+$ && "$sftp_port" -gt 0 ]] \
	|| { echo "FAIL: Compose did not publish SFTP on a dynamic loopback port: $sftp_endpoint" >&2; exit 1; }

admin_page="$work_dir/admin.html"
curl --fail --silent --show-error --insecure \
	--output "$admin_page" "https://127.0.0.1:$https_port/admin/"
grep -q 'VCF Services' "$admin_page" \
	|| { echo "FAIL: published HTTPS port did not return the console login page" >&2; exit 1; }
echo "HTTPS published-port proof passed: https://127.0.0.1:$https_port/admin/ returned the VCF Services login page"

stub_archive="$work_dir/vcf-download-tool-0.0.0-stub.tar.gz"
"$project_dir/tests/make-stub-vcfdt.sh" "$stub_archive" >/dev/null
ui_container="$("${compose[@]}" ps -q admin-ui)"
sync_container="$("${compose[@]}" ps -q depot-sync)"
docker cp "$stub_archive" "$ui_container:/tmp/vcf-download-tool-stub.tar.gz" >/dev/null
docker exec "$ui_container" curl --fail --silent --show-error --insecure \
	--cookie-jar /tmp/vcf-services-test-cookies \
	-H 'Content-Type: application/json' \
	-d '{"username":"vcf","password":"compose boot proof"}' \
	https://depot-web/admin/api/claim >/dev/null
docker exec "$ui_container" curl --fail --silent --show-error --insecure \
	--cookie /tmp/vcf-services-test-cookies \
	-H 'Content-Type: application/json' \
	-d '{"backupEnabled":true}' \
	https://depot-web/admin/api/settings >/dev/null

deadline=$((SECONDS + 30))
while true; do
	sftp_banner=""
	if { IFS= read -r -t 2 sftp_banner < "/dev/tcp/127.0.0.1/$sftp_port"; } 2>/dev/null; then
		sftp_banner="${sftp_banner%$'\r'}"
		break
	fi
	if [ "$SECONDS" -ge "$deadline" ]; then
		echo "FAIL: published SFTP port did not return an SSH banner" >&2
		exit 1
	fi
	sleep 1
done
[[ "$sftp_banner" = SSH-2.0-* || "$sftp_banner" = SSH-1.99-* ]] \
	|| { echo "FAIL: published SFTP port returned an invalid SSH banner: $sftp_banner" >&2; exit 1; }
echo "SFTP published-port proof passed: 127.0.0.1:$sftp_port returned $sftp_banner"

docker exec "$ui_container" curl --fail --silent --show-error --insecure \
	--cookie /tmp/vcf-services-test-cookies \
	-F 'archive=@/tmp/vcf-download-tool-stub.tar.gz;filename=vcf-download-tool-0.0.0-stub.tar.gz' \
	https://depot-web/admin/api/vcfdt >/dev/null
docker exec "$ui_container" curl --fail --silent --show-error --insecure \
	--cookie /tmp/vcf-services-test-cookies \
	-H 'Content-Type: application/json' \
	-d '{"activationCode":"compose-boot-test-code"}' \
	https://depot-web/admin/api/registration >/dev/null
docker exec "$ui_container" sh -c \
	"printf '%s\\n' waiting-for-sync > /opt/vcfdt/current/conf/telemetry/telemetry.flag"

deadline=$((SECONDS + 60))
until docker exec "$sync_container" grep -qx written \
	/opt/vcfdt/current/conf/telemetry/telemetry.flag >/dev/null 2>&1; do
	if [ "$SECONDS" -ge "$deadline" ]; then
		echo "FAIL: Compose sync did not complete the telemetry write proof" >&2
		exit 1
	fi
	docker exec "$sync_container" /usr/local/bin/sync.sh patches >/dev/null || true
	sleep 1
done
docker exec "$sync_container" jq -e \
	'.running == false and .lastRun.patches.status == "OK"' /state/state.json >/dev/null
docker exec "$sync_container" grep -qx written \
	/opt/vcfdt/current/conf/telemetry/telemetry.flag

"${compose[@]}" ps --all
echo "Compose boot test passed: services started and the mounted tool wrote its telemetry flag during sync"
