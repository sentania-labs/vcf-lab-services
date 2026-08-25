#!/bin/bash
set -euo pipefail

version="${1:?usage: verify-published-quickstart.sh RELEASE_VERSION}"
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$project_dir"

"$project_dir/scripts/verify-compose-version.sh" "$version" \
	"$project_dir/docker-compose.yml" >/dev/null

volumes=(
	vcf-services-depot-store
	vcf-services-backup-store
	vcf-services-vcfdt-state
	vcf-services-vcfdt-tool
	vcf-services-sync-state
	vcf-services-caddy-data
	vcf-services-caddy-config
	vcf-services-sftp-host-keys
	vcf-services-config
	vcf-services-secrets
)
for volume in "${volumes[@]}"; do
	if docker volume inspect "$volume" >/dev/null 2>&1; then
		echo "ERROR: published quickstart requires a clean runner, but $volume already exists" >&2
		exit 1
	fi
done

started=false
stop_stack() {
	if [ "$started" = true ]; then
		docker compose stop >/dev/null 2>&1 || true
	fi
}
trap stop_stack EXIT

started=true
# This is the README quickstart. No image variable or tag override is allowed.
docker compose up -d

deadline=$((SECONDS + 180))
until curl --fail --silent --show-error --insecure \
	https://127.0.0.1/healthz >/dev/null 2>&1; do
	if [ "$SECONDS" -ge "$deadline" ]; then
		echo "ERROR: published quickstart did not reach live HTTPS within 180 seconds" >&2
		docker compose ps >&2 || true
		exit 1
	fi
	sleep 2
done

for component in ui sync-base sftp; do
	case "$component" in
		ui) container=vcf-services-ui ;;
		sync-base) container=vcf-services-sync ;;
		sftp) container=vcf-services-sftp ;;
	esac
	expected_image="ghcr.io/sentania-labs/vcf-lab-services/$component:$version"
	actual_image="$(docker inspect "$container" --format '{{.Config.Image}}')"
	[ "$actual_image" = "$expected_image" ] || {
		echo "ERROR: $container started $actual_image, expected $expected_image" >&2
		exit 1
	}
	docker image inspect "$expected_image" --format '{{json .RepoDigests}}' \
		| grep -q "ghcr.io/sentania-labs/vcf-lab-services/$component@sha256:" || {
		echo "ERROR: $expected_image has no digest proving it was pulled from GHCR" >&2
		exit 1
	}
	actual="$(docker inspect "$container" \
		--format '{{ index .Config.Labels "org.opencontainers.image.version" }}')"
	[ "$actual" = "$version" ] || {
		echo "ERROR: $container is $actual, expected $version" >&2
		exit 1
	}
done

password="release quickstart proof"
cookie_jar="$(mktemp)"
stub_archive="$(mktemp --suffix=.tar.gz)"
"$project_dir/tests/make-stub-vcfdt.sh" "$stub_archive" >/dev/null

claim="$(curl --fail --silent --show-error --insecure -c "$cookie_jar" \
	-H 'Content-Type: application/json' \
	-d "{\"username\":\"vcf\",\"password\":\"$password\"}" \
	https://127.0.0.1/admin/api/claim)"
upload="$(curl --fail --silent --show-error --insecure -b "$cookie_jar" \
	-F "archive=@$stub_archive;filename=vcf-download-tool-0.0.0-stub.tar.gz" \
	https://127.0.0.1/admin/api/vcfdt)"
registration="$(curl --fail --silent --show-error --insecure -b "$cookie_jar" \
	https://127.0.0.1/admin/api/registration)"
activation="$(curl --fail --silent --show-error --insecure -b "$cookie_jar" \
	-H 'Content-Type: application/json' \
	-d '{"activationCode":"release-quickstart-test-code"}' \
	https://127.0.0.1/admin/api/registration)"
settings="$(curl --fail --silent --show-error --insecure -b "$cookie_jar" \
	-H 'Content-Type: application/json' \
	-d '{"cronSchedule":"30 2 * * *"}' \
	https://127.0.0.1/admin/api/settings)"

python3 - "$claim" "$upload" "$registration" "$activation" "$settings" <<'PY'
import json
import re
import sys

claim, upload, registration, activation, settings = map(json.loads, sys.argv[1:])
assert claim == {"claimed": True, "username": "vcf"}
assert upload["installed"] is True
assert upload["version"] == "vcf-download-tool 0.0.0-stub"
machine_id = registration["machineId"]
assert re.fullmatch(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
    machine_id,
)
assert registration["error"] is None
assert activation == {"machineId": machine_id, "saved": True}
assert settings["saved"] is True
assert settings["cronSchedule"] == "30 2 * * *"
assert settings["vcfVersion"] == "9.1.0"
assert settings["sku"] == "VCF"
PY

docker exec vcf-services-sync sh -c 'printf abcdef > /depot/range-proof.bin'
range_headers="$(mktemp)"
range_body="$(curl --fail --silent --show-error --insecure \
	--user "vcf:$password" -D "$range_headers" -H 'Range: bytes=1-3' \
	https://127.0.0.1/range-proof.bin)"
grep -Eiq '^HTTP/.* 206' "$range_headers"
grep -Eiq '^content-range: bytes 1-3/6' "$range_headers"
[ "$range_body" = bcd ]

echo "Published $version README quickstart and HTTP API walk passed"
