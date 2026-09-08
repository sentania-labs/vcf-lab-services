#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$project_dir"
fail() { echo "FAIL: $*" >&2; exit 1; }

product_files=(docker-compose.yml compose.sh install.sh caddy/Caddyfile Dockerfile.sync-base
	Dockerfile.ui Dockerfile.sftp sftp/entrypoint.sh sftp/healthcheck.sh sftp/sshd_config
	sync/entrypoint.sh sync/sync.sh ui/app.py ui/bootstrap.py ui/templates/index.html)

! grep -q 'docker.sock' -- "${product_files[@]}" || fail "a product container mounts the Docker socket"
! grep -qi 'macvlan' -- "${product_files[@]}" || fail "macvlan remains in the product"
! grep -Eq 'STORAGE_MODE|NFS_|driver_opts|DEPOT_VOLUME_(TYPE|OPTIONS|DEVICE)|BACKUP_VOLUME_(TYPE|OPTIONS|DEVICE)' \
	-- "${product_files[@]}" || fail "product-managed storage configuration remains"

# The rendered source checkout defaults track latest and always pull it.
default_render="$(env -u VCF_SERVICES_UI_IMAGE -u VCF_SERVICES_SYNC_IMAGE \
	-u VCF_SERVICES_SFTP_IMAGE -u VCF_SERVICES_PULL_POLICY docker compose config)"
[ "$(grep -c 'image: ghcr.io/sentania-labs/vcf-lab-services/ui:latest' <<< "$default_render")" -eq 2 ] \
	|| fail "bootstrap and UI do not default to the latest published image through VCF_SERVICES_UI_IMAGE"
grep -q 'image: ghcr.io/sentania-labs/vcf-lab-services/sync-base:latest' <<< "$default_render" \
	|| fail "sync does not default to the latest published image through VCF_SERVICES_SYNC_IMAGE"
grep -q 'image: ghcr.io/sentania-labs/vcf-lab-services/sftp:latest' <<< "$default_render" \
	|| fail "SFTP does not default to the latest published image through VCF_SERVICES_SFTP_IMAGE"
! grep -Eq 'vcf-lab-services/(ui|sync-base|sftp):v[0-9]' <<< "$default_render" \
	|| fail "a Compose default still pins a concrete release tag; pinning belongs in deployments"
[ "$(grep -c 'pull_policy: always' <<< "$default_render")" -eq 4 ] \
	|| fail "the four product services do not always refresh the latest image"
pinned_render="$(VCF_SERVICES_UI_IMAGE=example/ui:v9.9.9 VCF_SERVICES_SYNC_IMAGE=example/sync:v9.9.9 \
	VCF_SERVICES_SFTP_IMAGE=example/sftp:v9.9.9 VCF_SERVICES_PULL_POLICY=never docker compose config)"
[ "$(grep -c 'image: example/ui:v9.9.9' <<< "$pinned_render")" -eq 2 ] \
	|| fail "VCF_SERVICES_UI_IMAGE override did not reach bootstrap and the UI"
grep -q 'image: example/sync:v9.9.9' <<< "$pinned_render" || fail "VCF_SERVICES_SYNC_IMAGE override did not render"
grep -q 'image: example/sftp:v9.9.9' <<< "$pinned_render" || fail "VCF_SERVICES_SFTP_IMAGE override did not render"
[ "$(grep -c 'pull_policy: never' <<< "$pinned_render")" -eq 4 ] \
	|| fail "VCF_SERVICES_PULL_POLICY override did not reach the four product services"
! grep -q '^ *build:' docker-compose.yml || fail "Compose still builds a product image"

published_services="$(awk '/^  [A-Za-z0-9_-]+:$/ {service=$1} /^    ports:/ {print service}' docker-compose.yml)"
[ "$published_services" = $'depot-web:\nsftp-backup:' ] || fail "unexpected published ports: $published_services"
grep -q -- '- "443:443"' docker-compose.yml || fail "HTTPS must listen on host port 443"
grep -q -- '- "2222:22"' docker-compose.yml || fail "SFTP must listen on host port 2222"

grep -q 'container_name: vcf-services-bootstrap' docker-compose.yml || fail "bootstrap service missing"
grep -q 'condition: service_completed_successfully' docker-compose.yml || fail "services do not wait for bootstrap"
grep -q 'config_state:/config:rw' docker-compose.yml || fail "console lacks writable file-backed config"
grep -q 'secrets_state:/run/vcf-services-secrets:rw' docker-compose.yml \
	|| fail "console lacks writable protected secrets at the safe path"
! grep -q '/run/secrets' docker-compose.yml || fail "Compose still uses the platform-reserved secrets path"
! grep -q '/etc/vcf-services/secrets' docker-compose.yml \
	|| fail "Compose secrets remain nested beneath the sync config mount"
[ "$(grep -c '/run/vcf-services-secrets' docker-compose.yml)" -eq 13 ] \
	|| fail "not every Compose secret reference uses the non-nested mount path"
grep -q 'requirepass' ui/bootstrap.py || fail "bootstrap does not protect Redis"
! grep -q 'requirepass' docker-compose.yml || fail "Redis password material appears in Compose"
grep -q '.vcf-services-version' ui/bootstrap.py || fail "bootstrap does not mark config versions"
grep -q 'VERSION_STATUS_FILE' sync/entrypoint.sh || fail "sync does not stop on config version mismatch"
grep -q 'VERSION_STATUS_FILE' sftp/entrypoint.sh || fail "SFTP does not stop on config version mismatch"

grep -q 'depot_store:/depot:ro' docker-compose.yml || fail "web depot mount must be read-only at /depot"
grep -q 'depot_store:/depot:rw' docker-compose.yml || fail "sync depot mount must be read-write at /depot"
grep -q 'backup_store:/mnt/backup:rw' docker-compose.yml || fail "backup mount must be separate and writable"
docker compose config --format json | python3 -c '
import json
import sys

config = json.load(sys.stdin)
for name in ("depot-sync", "admin-ui"):
    mounts = [mount for mount in config["services"][name]["volumes"]
              if mount["target"] == "/opt/vcfdt"]
    assert len(mounts) == 1, f"{name}: expected one tool mount"
    mount = mounts[0]
    assert mount["type"] == "volume" and mount["source"] == "vcfdt_tool", name
    assert mount.get("read_only", False) is False, f"{name}: tool mount must be writable"
'
grep -q 'name: vcf-services-vcfdt-state' docker-compose.yml || fail "machine ID volume renamed"
grep -q 'name: vcf-services-sftp-host-keys' docker-compose.yml || fail "SFTP host-key volume renamed"

grep -q 'tls internal' caddy/Caddyfile || fail "first boot does not provide internal TLS"
grep -q 'ask http://{$ADMIN_UI_UPSTREAM:admin-ui:8080}/tls/allow' caddy/Caddyfile \
	|| fail "on-demand internal TLS has no issuance guard"
grep -q 'forward_auth {$ADMIN_UI_UPSTREAM:admin-ui:8080}' caddy/Caddyfile \
	|| fail "depot requests do not use the configurable console upstream"
grep -q 'handle_path /admin/\*' caddy/Caddyfile || fail "admin console route missing"
grep -q 'handle /umds-patch-store/\*' caddy/Caddyfile || fail "open UMDS route missing"

for key_type in ed25519 rsa ecdsa; do
	grep -q "ssh_host_${key_type}_key" sftp/entrypoint.sh || fail "$key_type host key generation missing"
done
grep -q '^AllowUsers vcf$' sftp/sshd_config || fail "SFTP must use the shared vcf username"
grep -q '^ForceCommand /usr/lib/openssh/sftp-server$' sftp/sshd_config \
	|| fail "SFTP account is not restricted to file transfer"

work_dir="$(mktemp -d /tmp/vcf-services-compose-test.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT
mkdir -p "$work_dir/bin"
cat > "$work_dir/bin/docker" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$DOCKER_CALLS"
case "$1" in
	info) [ "${MOCK_DAEMON_UP:-true}" = true ] ;;
	compose) exit 0 ;;
	*) exit 2 ;;
esac
EOF
chmod +x "$work_dir/bin/docker"
export DOCKER_CALLS="$work_dir/docker.calls"

set +e
output="$(MOCK_DAEMON_UP=false PATH="$work_dir/bin:$PATH" ./compose.sh up -d 2>&1)"
status=$?
set -e
[ "$status" -eq 1 ] || fail "compose wrapper ignored an unreachable daemon"
grep -q 'cannot reach the Docker daemon' <<< "$output" || fail "daemon error is unclear"

: > "$DOCKER_CALLS"
PATH="$work_dir/bin:$PATH" ./compose.sh up -d
grep -qx 'compose up -d' "$DOCKER_CALLS" || fail "compose arguments were not preserved"

for name in 'vcf-services:sync:requests' 'vcf-services:sync:status' \
	'vcf-services:sync:log' 'vcf-services:sync:versions'; do
	grep -q "$name" docs/redis-contract.md || fail "$name missing from Redis contract"
	grep -q "$name" ui/app.py || fail "$name missing from console"
done

docker compose config --quiet
single_pod_render="$(REDIS_HOST=127.0.0.1 ADMIN_UI_UPSTREAM=127.0.0.1:8080 docker compose config)"
[ "$(grep -c 'REDIS_HOST: 127.0.0.1' <<< "$single_pod_render")" -eq 2 ] \
	|| fail "Redis host environment override did not reach both consumers"
grep -q 'ADMIN_UI_UPSTREAM: 127.0.0.1:8080' <<< "$single_pod_render" \
	|| fail "Caddy upstream environment override did not render"
docker run --rm -e ADMIN_UI_UPSTREAM=127.0.0.1:8080 \
	-v "$project_dir/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" \
	caddy:2.10.0-alpine caddy validate --config /etc/caddy/Caddyfile >/dev/null
echo "compose and architecture contract tests passed"
