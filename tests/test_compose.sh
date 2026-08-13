#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$project_dir"

fail() { echo "FAIL: $*" >&2; exit 1; }

product_files=(docker-compose.yml install.sh caddy/Caddyfile config/answers.example
	config/settings.env.example Dockerfile.sync Dockerfile.sync-base Dockerfile.ui
	sync/entrypoint.sh sync/sync.sh sync/targets/vkr.sh scripts/verify-byte-exact.sh
	ui/app.py ui/requirements.txt ui/templates/index.html)

# No Docker socket, Docker proxy, or Docker client dependency anywhere.
! grep -q 'docker.sock' docker-compose.yml || fail "docker-compose.yml mounts the Docker socket"
! grep -q 'dockerproxy\|docker-socket-proxy' -- "${product_files[@]}" || fail "a Docker socket proxy reference remains"
! grep -Eq '^docker([=<>]|$)' ui/requirements.txt || fail "the console still depends on the Docker client library"
! grep -Eq '^import docker|^from docker' ui/app.py || fail "the console still imports the Docker client"

# Macvlan is fully removed from the product.
! grep -qi 'macvlan' -- "${product_files[@]}" || fail "a macvlan reference remains"
[ ! -f compose.macvlan.yml ] || fail "compose.macvlan.yml still exists"

# Published HTTPS is the only exposure: exactly one service publishes ports,
# and it is depot-web on the configurable HTTPS port.
published_services="$(awk '/^  [A-Za-z0-9_-]+:$/ {service=$1} /^    ports:/ {print service}' docker-compose.yml)"
[ "$published_services" = "depot-web:" ] || fail "unexpected published ports: $published_services"
grep -q 'HTTPS_PORT:-443' docker-compose.yml || fail "depot-web must default to published port 443"

# Redis job bus: present, internal only, password protected, non-persistent.
grep -q 'container_name: vcf-services-redis' docker-compose.yml || fail "redis service missing"
grep -q '/etc/redis/redis.conf' docker-compose.yml || fail "redis must load the generated config"
grep -q 'command: \["sh", "-c", "exec redis-server /etc/redis/redis.conf"\]' docker-compose.yml \
	|| fail "redis must start via sh so the image entrypoint keeps root and can read the 0600 config"
grep -q 'requirepass' install.sh || fail "install.sh must generate a requirepass config"
! grep -q 'requirepass' docker-compose.yml || fail "no password material belongs in docker-compose.yml"
grep -q "openssl rand" install.sh || fail "install.sh must generate the Redis password"
! grep -q -- '--plaintext' install.sh || fail "the web password must be hashed via stdin"

# Config is mounted as a directory so atomic settings replacement is visible.
grep -q -- '- ./config:/etc/vcf-services:ro' docker-compose.yml || fail "sync must mount the config directory"
grep -q -- '- ./config:/config' docker-compose.yml || fail "console must mount the config directory"
! grep -q 'config/settings.env:' docker-compose.yml || fail "single-file settings mounts break atomic replacement"

# Depot storage contracts.
grep -q 'depot_store:/depot:ro' docker-compose.yml || fail "web depot mount must be read-only at /depot"
grep -q 'depot_store:/depot:rw' docker-compose.yml || fail "sync depot mount must be read-write at /depot"
grep -q 'name: vcf-services-vcfdt-state' docker-compose.yml || fail "vcfdt state volume renamed"
grep -A1 'name: vcf-services-vcfdt-state' docker-compose.yml | grep -q 'external: true' \
	|| fail "vcfdt state volume must stay external"

# Bus key names stay consistent across producers, consumers, and the contract.
for name in 'vcf-services:sync:requests' 'vcf-services:sync:status' 'vcf-services:sync:log' 'vcf-services:sync:versions'; do
	grep -q "$name" docs/redis-contract.md || fail "$name missing from docs/redis-contract.md"
	grep -q "$name" ui/app.py || fail "$name missing from ui/app.py"
done
grep -q 'vcf-services:sync:requests' sync/entrypoint.sh || fail "queue name missing from the scheduler"
grep -q 'vcf-services:sync:status' sync/sync.sh || fail "status key missing from sync.sh"
grep -q 'vcf-services:sync:log' sync/sync.sh || fail "log key missing from sync.sh"

# Operator config hygiene.
grep -qx 'config/settings.env.\*' .gitignore || fail ".gitignore must cover settings.env temp files"

echo "compose and architecture contract tests passed"
