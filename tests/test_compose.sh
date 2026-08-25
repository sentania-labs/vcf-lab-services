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

grep -q 'ghcr.io/sentania-labs/vcf-lab-services/ui:latest' docker-compose.yml \
	|| fail "UI does not default to the published image"
grep -q 'ghcr.io/sentania-labs/vcf-lab-services/sync-base:latest' docker-compose.yml \
	|| fail "sync does not default to the published image"
grep -q 'ghcr.io/sentania-labs/vcf-lab-services/sftp:latest' docker-compose.yml \
	|| fail "SFTP does not default to the published image"
! grep -q '^ *build:' docker-compose.yml || fail "Compose still builds a product image"

published_services="$(awk '/^  [A-Za-z0-9_-]+:$/ {service=$1} /^    ports:/ {print service}' docker-compose.yml)"
[ "$published_services" = $'depot-web:\nsftp-backup:' ] || fail "unexpected published ports: $published_services"
grep -q -- '- "443:443"' docker-compose.yml || fail "HTTPS must listen on host port 443"
grep -q -- '- "2222:22"' docker-compose.yml || fail "SFTP must listen on host port 2222"

grep -q 'container_name: vcf-services-bootstrap' docker-compose.yml || fail "bootstrap service missing"
grep -q 'condition: service_completed_successfully' docker-compose.yml || fail "services do not wait for bootstrap"
grep -q 'config_state:/config:rw' docker-compose.yml || fail "console lacks writable file-backed config"
grep -q 'secrets_state:/run/secrets:rw' docker-compose.yml || fail "console lacks writable protected secrets"
grep -q 'requirepass' ui/bootstrap.py || fail "bootstrap does not protect Redis"
! grep -q 'requirepass' docker-compose.yml || fail "Redis password material appears in Compose"

grep -q 'depot_store:/depot:ro' docker-compose.yml || fail "web depot mount must be read-only at /depot"
grep -q 'depot_store:/depot:rw' docker-compose.yml || fail "sync depot mount must be read-write at /depot"
grep -q 'backup_store:/mnt/backup:rw' docker-compose.yml || fail "backup mount must be separate and writable"
grep -q 'vcfdt_tool:/opt/vcfdt:ro' docker-compose.yml || fail "sync tool mount must be read-only"
grep -q 'vcfdt_tool:/opt/vcfdt:rw' docker-compose.yml || fail "console tool mount must be writable"
[ "$(grep -c 'vcfdt_tool:/opt/vcfdt:rw' docker-compose.yml)" -eq 1 ] \
	|| fail "only the console may write the tool volume"
grep -q 'name: vcf-services-vcfdt-state' docker-compose.yml || fail "machine ID volume renamed"
grep -q 'name: vcf-services-sftp-host-keys' docker-compose.yml || fail "SFTP host-key volume renamed"

grep -q 'tls internal' caddy/Caddyfile || fail "first boot does not provide internal TLS"
grep -q 'ask http://admin-ui:8080/tls/allow' caddy/Caddyfile \
	|| fail "on-demand internal TLS has no issuance guard"
grep -q 'forward_auth admin-ui:8080' caddy/Caddyfile || fail "depot requests do not use live console credentials"
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
echo "compose and architecture contract tests passed"
