#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$project_dir"

fail() { echo "FAIL: $*" >&2; exit 1; }

product_files=(docker-compose.yml compose.sh install.sh caddy/Caddyfile config/answers.example
	config/settings.env.example Dockerfile.sync Dockerfile.sync-base Dockerfile.ui
	Dockerfile.sftp Dockerfile.sftp.dockerignore sftp/entrypoint.sh sftp/healthcheck.sh sftp/sshd_config
	sftp/own-backup.sh sync/entrypoint.sh sync/sync.sh sync/targets/vkr.sh scripts/verify-byte-exact.sh
	ui/app.py ui/requirements.txt ui/templates/index.html)

# No Docker socket, Docker proxy, or Docker client dependency anywhere.
! grep -q 'docker.sock' docker-compose.yml || fail "docker-compose.yml mounts the Docker socket"
! grep -q 'dockerproxy\|docker-socket-proxy' -- "${product_files[@]}" || fail "a Docker socket proxy reference remains"
! grep -Eq '^docker([=<>]|$)' ui/requirements.txt || fail "the console still depends on the Docker client library"
! grep -Eq '^import docker|^from docker' ui/app.py || fail "the console still imports the Docker client"

# Macvlan is fully removed from the product.
! grep -qi 'macvlan' -- "${product_files[@]}" || fail "a macvlan reference remains"
[ ! -f compose.macvlan.yml ] || fail "compose.macvlan.yml still exists"

# Only the operator-facing HTTPS and SFTP services publish ports.
published_services="$(awk '/^  [A-Za-z0-9_-]+:$/ {service=$1} /^    ports:/ {print service}' docker-compose.yml)"
[ "$published_services" = $'depot-web:\nsftp-backup:' ] || fail "unexpected published ports: $published_services"
grep -q 'HTTPS_PORT:-443' docker-compose.yml || fail "depot-web must default to published port 443"
grep -q 'SFTP_PORT:-2222' docker-compose.yml || fail "SFTP must default to published port 2222"

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
grep -q 'name: vcf-services-vcfdt-tool' docker-compose.yml || fail "vcfdt tool volume missing"
! grep -q 'docker volume create vcf-services-vcfdt-tool' install.sh \
	|| fail "installer must let Compose create and own the disposable tool volume"
grep -q 'vcfdt_tool:/opt/vcfdt:ro' docker-compose.yml || fail "sync tool mount must be read-only"
grep -q 'vcfdt_tool:/opt/vcfdt:rw' docker-compose.yml || fail "console tool mount must be read-write"
[ "$(grep -c 'vcfdt_tool:/opt/vcfdt:rw' docker-compose.yml)" -eq 1 ] \
	|| fail "only the console may write the tool volume"
! grep -q 'patch_tool_endpoint' sync/entrypoint.sh \
	|| fail "sync entrypoint must not rewrite the mounted tool"
! grep -q 'COPY build/vcfdt' Dockerfile.sync || fail "licensed tool is still baked into an image"
grep -q 'VCF_SERVICES_SYNC_IMAGE' docker-compose.yml || fail "compose does not consume the license-safe sync image"

# SFTP backup contracts proven necessary by live VCF components.
grep -q 'backup_store:/mnt/backup:rw' docker-compose.yml || fail "backup storage must be read-write at /mnt/backup"
grep -q 'sftp_host_keys:/etc/ssh/keys:rw' docker-compose.yml || fail "SFTP host keys need a dedicated volume"
grep -A1 'name: vcf-services-sftp-host-keys' docker-compose.yml | grep -q 'external: true' \
	|| fail "SFTP host keys must survive Compose volume cleanup"
for key_type in ed25519 rsa ecdsa; do
	grep -q "ssh_host_${key_type}_key" sftp/entrypoint.sh || fail "$key_type host-key generation missing"
	grep -q "ssh_host_${key_type}_key" sftp/sshd_config || fail "$key_type HostKey missing from sshd_config"
done
grep -q '^PasswordAuthentication yes$' sftp/sshd_config || fail "SFTP password authentication must be enabled"
grep -q '^PermitRootLogin no$' sftp/sshd_config || fail "SFTP root login must be disabled"
grep -q '^AllowUsers vcfbackup$' sftp/sshd_config || fail "SFTP must allow only the backup user"
grep -q '^Subsystem sftp /usr/lib/openssh/sftp-server$' sftp/sshd_config \
	|| fail "SFTP must use the external sftp-server subsystem"
! grep -Eq 'ChrootDirectory|internal-sftp' sftp/sshd_config || fail "SFTP must not chroot or rewrite absolute paths"
grep -q '^ForceCommand /usr/lib/openssh/sftp-server$' sftp/sshd_config \
	|| fail "SFTP must force file transfer only, with no shell or remote command"
grep -q 'sftp-own-backup.sh' sftp/entrypoint.sh || fail "SFTP must re-own the backup tree on a UID:GID change"
grep -q 'sftp-own-backup.sh' install.sh || fail "installer and service must share one re-own implementation"
grep -q 'backup-owner' sftp/own-backup.sh || fail "re-own needs a persistent marker"
grep -q 'storage_id' sftp/own-backup.sh || fail "the re-own marker must be keyed to the backup storage"
grep -q 'warn_identity' sftp/entrypoint.sh || fail "identity retry warnings must be deduplicated"
grep -q -- '--min-backup-free-gb' install.sh || fail "installer must offer an opt-in backup free-space floor"
! grep -q 'depot_local_path/backup' install.sh || fail "backup storage must not nest inside the depot tree"
grep -q 'paths_are_disjoint "\$depot_local_path" "\$backup_local_path"' install.sh \
	|| fail "installer must reject a backup directory inside the depot directory"
grep -q 'host_tcp_port_is_bound' install.sh || fail "installer port collision check missing"
! grep -q 'SFTP_PASSWORD=' docker-compose.yml || fail "SFTP password material belongs only in the secret file"

# Manual startup reports install-created prerequisites before Compose can fail.
work_dir="$(mktemp -d /tmp/vcf-services-compose-test.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT
mkdir -p "$work_dir/bin"
cat > "$work_dir/bin/docker" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$DOCKER_CALLS"
case "$1 ${2:-}" in
	"info ") [ "${MOCK_DAEMON_UP:-true}" = true ] ;;
	"volume inspect") [ "${MOCK_VOLUME_EXISTS:-}" = true ] ;;
	"image inspect") [ "${MOCK_IMAGE_EXISTS:-}" = true ] ;;
	compose\ *) exit 0 ;;
	*) exit 2 ;;
esac
EOF
chmod +x "$work_dir/bin/docker"
export DOCKER_CALLS="$work_dir/docker.calls"

set +e
daemon_output="$(MOCK_DAEMON_UP=false PATH="$work_dir/bin:$PATH" ./compose.sh up -d 2>&1)"
daemon_status=$?
set -e
[ "$daemon_status" -eq 1 ] || fail "compose preflight ignored an unreachable Docker daemon"
grep -q 'cannot reach the Docker daemon' <<< "$daemon_output" \
	|| fail "compose preflight misdiagnosed an unreachable Docker daemon"
! grep -q 'Run ./install.sh instead' <<< "$daemon_output" \
	|| fail "compose preflight blamed the installation for a daemon outage"

: > "$DOCKER_CALLS"
set +e
preflight_output="$(PATH="$work_dir/bin:$PATH" ./compose.sh up -d 2>&1)"
preflight_status=$?
set -e
[ "$preflight_status" -eq 1 ] || fail "compose preflight did not reject missing prerequisites"
grep -q 'external volume vcf-services-vcfdt-state' <<< "$preflight_output" \
	|| fail "compose preflight did not identify the missing external volume"
grep -q 'Run ./install.sh instead' <<< "$preflight_output" \
	|| fail "compose preflight did not direct the operator to install.sh"
! grep -q '^compose up' "$DOCKER_CALLS" || fail "Compose ran after a failed preflight"

: > "$DOCKER_CALLS"
set +e
option_preflight_output="$(PATH="$work_dir/bin:$PATH" \
	./compose.sh --profile debug --ansi never up -d 2>&1)"
option_preflight_status=$?
set -e
[ "$option_preflight_status" -eq 1 ] \
	|| fail "compose global options bypassed the installation preflight"
grep -q 'external volume vcf-services-vcfdt-state' <<< "$option_preflight_output" \
	|| fail "options-before-command preflight missed the external volume"
! grep -q '^compose ' "$DOCKER_CALLS" \
	|| fail "Compose ran after an options-before-command preflight failure"

: > "$DOCKER_CALLS"
set +e
image_only_output="$(MOCK_IMAGE_EXISTS=true PATH="$work_dir/bin:$PATH" ./compose.sh up -d 2>&1)"
image_only_status=$?
set -e
[ "$image_only_status" -eq 1 ] || fail "compose preflight accepted a missing external volume"
grep -q 'external volume vcf-services-vcfdt-state' <<< "$image_only_output" \
	|| fail "compose preflight missed the absent external volume"
! grep -q 'local image' <<< "$image_only_output" \
	|| fail "compose preflight reported an image that exists"

: > "$DOCKER_CALLS"
MOCK_VOLUME_EXISTS=true PATH="$work_dir/bin:$PATH" ./compose.sh up -d
grep -qx 'compose up -d' "$DOCKER_CALLS" || fail "validated up command was not passed to Compose"

: > "$DOCKER_CALLS"
MOCK_VOLUME_EXISTS=true PATH="$work_dir/bin:$PATH" \
	./compose.sh --profile debug --ansi never up -d
grep -qx 'compose --profile debug --ansi never up -d' "$DOCKER_CALLS" \
	|| fail "Compose global options were not preserved after preflight"

: > "$DOCKER_CALLS"
PATH="$work_dir/bin:$PATH" ./compose.sh ps
grep -qx 'compose ps' "$DOCKER_CALLS" || fail "day-to-day Compose command was not passed through"

# The wrapper acts on its own project no matter where the operator invokes it.
: > "$DOCKER_CALLS"
(cd "$work_dir" && MOCK_VOLUME_EXISTS=true \
	PATH="$work_dir/bin:$PATH" "$project_dir/compose.sh" up -d)
grep -qx 'compose up -d' "$DOCKER_CALLS" \
	|| fail "compose wrapper failed when invoked from another directory"

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
