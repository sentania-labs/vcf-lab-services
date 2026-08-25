#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work_dir="$(mktemp -d /tmp/vcf-services-sftp-test.XXXXXX)"
suffix="$$"
image="vcf-services-sftp:test-$suffix"
container="vcf-services-sftp-test-$suffix"
client_container="vcf-services-sftp-client-$suffix"
backup_volume="vcf-services-sftp-test-backup-$suffix"
key_volume="vcf-services-sftp-test-keys-$suffix"

cleanup() {
	status=$?
	if [ "$status" -ne 0 ]; then
		docker logs "$container" >&2 || true
	fi
	docker rm -f "$client_container" >/dev/null 2>&1 || true
	docker rm -f "$container" >/dev/null 2>&1 || true
	docker volume rm "$backup_volume" "$key_volume" >/dev/null 2>&1 || true
	docker volume rm "vcf-services-sftp-test-backup2-$suffix" >/dev/null 2>&1 || true
	docker image rm "$image" >/dev/null 2>&1 || true
	rm -rf "$work_dir"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$work_dir/config" "$work_dir/secrets"
printf 'BACKUP_ENABLED="true"\nSFTP_UID_GID="1003:1003"\n' > "$work_dir/config/settings.env"
printf 'sftp-test-password\n' > "$work_dir/secrets/password"
chmod 0600 "$work_dir/secrets/password"
printf 'backup payload\n' > "$work_dir/payload.txt"

docker build -q -f "$project_dir/Dockerfile.sftp" -t "$image" "$project_dir" >/dev/null
docker volume create "$backup_volume" >/dev/null
docker volume create "$key_volume" >/dev/null
docker run --rm --entrypoint /bin/sh -v "$backup_volume:/mnt/backup" "$image" \
	-c 'chown 1003:1003 /mnt/backup'
docker run --rm --user 1003:1003 --entrypoint /bin/sh -v "$backup_volume:/mnt/backup" "$image" \
	-c 'mkdir -p /mnt/backup/sddc-manager /mnt/backup/nsx /mnt/backup/vcenter'

start_server() {
	docker run -d --name "$container" -p 127.0.0.1::22 \
		-v "$backup_volume:/mnt/backup:rw" \
		-v "$key_volume:/etc/ssh/keys:rw" \
		-v "$work_dir/config:/config:ro" \
		-v "$work_dir/secrets:/run/sftp-secrets:ro" \
		"$image" >/dev/null
	deadline=$((SECONDS + 60))
	while [ "$SECONDS" -lt "$deadline" ]; do
		state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container" 2>/dev/null || true)"
		[ "$state" = healthy ] && return 0
		sleep 1
	done
	docker logs "$container" >&2 || true
	return 1
}

start_server || fail "SFTP container did not become healthy"
logs="$(docker logs "$container" 2>&1)"
grep -q 'SFTP host key fingerprints' <<< "$logs" || fail "fingerprint heading missing from logs"
for key_type in ED25519 RSA ECDSA; do
	grep -q "($key_type)" <<< "$logs" || fail "$key_type fingerprint missing from logs"
done

for key_type in ed25519 rsa ecdsa; do
	docker run --rm --entrypoint test -v "$key_volume:/keys:ro" "$image" \
		-s "/keys/ssh_host_${key_type}_key" || fail "$key_type private host key missing"
done
before_hash="$(docker run --rm --entrypoint /bin/sh -v "$key_volume:/keys:ro" "$image" \
	-c 'sha256sum /keys/ssh_host_*_key | sort')"

host_port="$(docker port "$container" 22/tcp | head -n 1 | awk -F: '{print $NF}')"
[ -n "$host_port" ] || fail "published SFTP port was not discoverable"
SSHPASS=sftp-test-password docker run --rm --network host --entrypoint /bin/sh \
	-e SSHPASS -e "SFTP_PORT=$host_port" -v "$work_dir:/work:ro" "$image" \
	-c 'printf "put /work/payload.txt /mnt/backup/vcenter/payload.txt\nbye\n" | \
		sshpass -e sftp -q -o BatchMode=no -o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null -P "$SFTP_PORT" vcf@127.0.0.1'

uploaded="$(docker run --rm --entrypoint /bin/sh -v "$backup_volume:/mnt/backup:ro" "$image" \
	-c 'cat /mnt/backup/vcenter/payload.txt')"
[ "$uploaded" = "backup payload" ] || fail "absolute-path SFTP upload did not reach backup storage"

if SSHPASS=wrong-password timeout 15 docker run --rm --network host --entrypoint /bin/sh \
	-e SSHPASS -e "SFTP_PORT=$host_port" "$image" \
	-c 'printf "ls /mnt/backup\nbye\n" | sshpass -e sftp -q -o BatchMode=no \
		-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-P "$SFTP_PORT" vcf@127.0.0.1' >/dev/null 2>&1; then
	fail "SFTP accepted the wrong password"
fi

remote_command_output="$(SSHPASS=sftp-test-password timeout 15 docker run --rm --network host \
	--entrypoint /bin/sh -e SSHPASS -e "SFTP_PORT=$host_port" "$image" \
	-c 'sshpass -e ssh -o BatchMode=no -o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null -p "$SFTP_PORT" vcf@127.0.0.1 id' 2>/dev/null \
	| tr -cd "[:print:]" || true)"
case "$remote_command_output" in
	*uid=*) fail "SFTP account was able to run a remote command" ;;
esac

SSHPASS=sftp-test-password docker run -d --name "$client_container" --network host \
	--entrypoint /bin/sh -e SSHPASS -e "SFTP_PORT=$host_port" "$image" \
	-c 'while :; do printf "pwd\n"; sleep 1; done | sshpass -e sftp -q -o BatchMode=no \
		-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-P "$SFTP_PORT" vcf@127.0.0.1' >/dev/null
deadline=$((SECONDS + 30))
session_started=false
while [ "$SECONDS" -lt "$deadline" ]; do
	if docker exec "$container" pgrep -u vcf >/dev/null 2>&1; then
		session_started=true
		break
	fi
	sleep 1
done
[ "$session_started" = true ] || fail "long-lived SFTP test session did not authenticate"

printf 'BACKUP_ENABLED="false"\nSFTP_UID_GID="1003:1003"\n' > "$work_dir/config/settings.env"
deadline=$((SECONDS + 30))
session_stopped=false
while [ "$SECONDS" -lt "$deadline" ]; do
	server_sessions="$(docker exec "$container" sh -c \
		'pgrep -x sshd >/dev/null || pgrep -u vcf >/dev/null; printf "%s" "$?"' 2>/dev/null || true)"
	if [ "$server_sessions" = 1 ]; then
		session_stopped=true
		break
	fi
	sleep 1
done
if [ "$session_stopped" != true ]; then
	docker top "$container" -eo pid,ppid,uid,stat,comm,args >&2 || true
	fail "disabling SFTP left a listener or authenticated session process running"
fi
docker rm -f "$client_container" >/dev/null

printf 'BACKUP_ENABLED="true"\nSFTP_UID_GID="1003:1003"\n' > "$work_dir/config/settings.env"
deadline=$((SECONDS + 30))
while [ "$SECONDS" -lt "$deadline" ]; do
	if docker exec "$container" sh -c \
		'test -s /run/sshd.pid && kill -0 "$(cat /run/sshd.pid)"' 2>/dev/null; then
		break
	fi
	sleep 1
done
docker exec "$container" sh -c \
	'test -s /run/sshd.pid && kill -0 "$(cat /run/sshd.pid)"' 2>/dev/null \
	|| fail "SFTP listener did not return after re-enabling the service"

printf 'BACKUP_ENABLED="true"\nSFTP_UID_GID="1005:1005"\n' > "$work_dir/config/settings.env"
deadline=$((SECONDS + 60))
owner=""
while [ "$SECONDS" -lt "$deadline" ]; do
	owner="$(docker run --rm --entrypoint /bin/sh -v "$backup_volume:/mnt/backup:ro" "$image" \
		-c 'stat -c "%u:%g" /mnt/backup/vcenter/payload.txt')"
	[ "$owner" = "1005:1005" ] && break
	sleep 2
done
[ "$owner" = "1005:1005" ] || fail "changed UID:GID did not re-own the existing backup tree (saw $owner)"
marker="$(docker run --rm --entrypoint /bin/sh -v "$key_volume:/keys:ro" "$image" \
	-c 'cat /keys/backup-owner')"
case "$marker" in
	*' 1005:1005 ok') ;;
	*) fail "re-own marker was not recorded against the backup storage (saw $marker)" ;;
esac

relocated_volume="vcf-services-sftp-test-backup2-$suffix"
docker volume create "$relocated_volume" >/dev/null
docker run --rm --entrypoint /usr/local/bin/sftp-own-backup.sh \
	-v "$relocated_volume:/mnt/backup:rw" -v "$key_volume:/etc/ssh/keys:rw" \
	"$image" 1005 1005 >/dev/null \
	|| fail "a relocated backup store was not re-owned"
relocated_owner="$(docker run --rm --entrypoint /bin/sh -v "$relocated_volume:/mnt/backup:ro" "$image" \
	-c 'stat -c "%u:%g" /mnt/backup')"
docker volume rm "$relocated_volume" >/dev/null
[ "$relocated_owner" = "1005:1005" ] \
	|| fail "stale marker blocked the re-own of a new backup location (saw $relocated_owner)"
SSHPASS=sftp-test-password docker run --rm --network host --entrypoint /bin/sh \
	-e SSHPASS -e "SFTP_PORT=$host_port" -v "$work_dir:/work:ro" "$image" \
	-c 'printf "put /work/payload.txt /mnt/backup/vcenter/reowned.txt\nbye\n" | \
		sshpass -e sftp -q -o BatchMode=no -o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null -P "$SFTP_PORT" vcf@127.0.0.1' \
	|| fail "upload failed after the UID:GID change"

docker rm -f "$container" >/dev/null
start_server || fail "recreated SFTP container did not become healthy"
after_hash="$(docker run --rm --entrypoint /bin/sh -v "$key_volume:/keys:ro" "$image" \
	-c 'sha256sum /keys/ssh_host_*_key | sort')"
[ "$before_hash" = "$after_hash" ] || fail "host keys changed across container recreation"

echo "SFTP backup runtime tests passed"
