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
    ports: !override []
  depot-sync:
    container_name: vcf-services-compose-test-${test_id}-sync
  sftp-backup:
    container_name: vcf-services-compose-test-${test_id}-sftp
    ports: !override []
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

"${compose[@]}" ps --all
echo "Compose boot test passed: every service is healthy, running, or completed successfully"
