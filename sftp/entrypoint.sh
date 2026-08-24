#!/bin/sh
set -eu

settings_file="${SETTINGS_FILE:-/config/settings.env}"
password_file="${SFTP_PASSWORD_FILE:-/run/sftp-secrets/password}"
backup_user=vcfbackup
sshd_pid=""

setting() {
	key="$1"
	fallback="$2"
	value="$(sed -n "s/^${key}=\"\\{0,1\\}\([^\"]*\)\"\\{0,1\\}$/\\1/p" "$settings_file" 2>/dev/null | tail -n 1)"
	printf '%s' "${value:-$fallback}"
}

validate_uid_gid() {
	case "$1" in
		*[!0-9:]*|*:*:*) return 1 ;;
	esac
	uid="${1%%:*}"
	gid="${1#*:}"
	[ -n "$uid" ] && [ -n "$gid" ] && [ "$uid" -ge 1 ] && [ "$uid" -le 2147483647 ] \
		&& [ "$gid" -ge 1 ] && [ "$gid" -le 2147483647 ]
}

apply_identity() {
	uid_gid="$(setting SFTP_UID_GID 1003:1003)"
	validate_uid_gid "$uid_gid" || {
		echo "ERROR: SFTP_UID_GID must contain a non-root numeric UID:GID" >&2
		exit 1
	}
	uid="${uid_gid%%:*}"
	gid="${uid_gid#*:}"

	if getent group "$backup_user" >/dev/null 2>&1; then
		current_gid="$(getent group "$backup_user" | cut -d: -f3)"
		[ "$current_gid" = "$gid" ] || groupmod -g "$gid" "$backup_user"
	else
		if getent group "$gid" >/dev/null 2>&1; then
			echo "ERROR: configured SFTP GID $gid is already assigned in the container" >&2
			exit 1
		fi
		groupadd -g "$gid" "$backup_user"
	fi

	if id "$backup_user" >/dev/null 2>&1; then
		current_uid="$(id -u "$backup_user")"
		[ "$current_uid" = "$uid" ] || usermod -u "$uid" "$backup_user"
		usermod -g "$gid" -d /mnt/backup -s /bin/sh "$backup_user"
	else
		if getent passwd "$uid" >/dev/null 2>&1; then
			echo "ERROR: configured SFTP UID $uid is already assigned in the container" >&2
			exit 1
		fi
		useradd -M -u "$uid" -g "$gid" -d /mnt/backup -s /bin/sh "$backup_user"
	fi
	own_backup_tree "$uid" "$gid"
	last_uid_gid="$uid_gid"
}

own_backup_tree() {
	uid="$1"
	gid="$2"
	current="$(stat -c '%u:%g' /mnt/backup 2>/dev/null || true)"
	if [ "$current" = "$uid:$gid" ]; then
		return 0
	fi
	if chown -R "$uid:$gid" /mnt/backup 2>/dev/null; then
		echo "Re-owned /mnt/backup as $uid:$gid"
		return 0
	fi
	echo "WARNING: could not re-own /mnt/backup as $uid:$gid. Backup writes will fail until the share ownership is corrected." >&2
	return 0
}

apply_password() {
	[ -s "$password_file" ] || {
		echo "ERROR: enabled SFTP backup requires a non-empty password secret" >&2
		exit 1
	}
	password="$(cat "$password_file")"
	case "$password" in
		*'
'*) echo "ERROR: SFTP password secret must be one line" >&2; exit 1 ;;
	esac
	printf '%s:%s\n' "$backup_user" "$password" | chpasswd
	password=""
	last_password_hash="$(sha256sum "$password_file" | cut -d' ' -f1)"
}

generate_host_key() {
	type="$1"
	bits="$2"
	path="/etc/ssh/keys/ssh_host_${type}_key"
	if [ ! -s "$path" ]; then
		if [ -n "$bits" ]; then
			ssh-keygen -q -t "$type" -b "$bits" -f "$path" -N ''
		else
			ssh-keygen -q -t "$type" -f "$path" -N ''
		fi
	fi
	chmod 0600 "$path"
	chmod 0644 "$path.pub"
}

stop_sshd() {
	if [ -n "$sshd_pid" ] && kill -0 "$sshd_pid" 2>/dev/null; then
		kill "$sshd_pid"
		wait "$sshd_pid" 2>/dev/null || true
	fi
	sshd_pid=""
	rm -f /run/sshd.pid
}

shutdown() {
	stop_sshd
	exit 0
}
trap shutdown INT TERM

generate_host_key ed25519 ""
generate_host_key rsa 3072
generate_host_key ecdsa 256

echo "SFTP host key fingerprints"
for public_key in /etc/ssh/keys/ssh_host_ed25519_key.pub \
	/etc/ssh/keys/ssh_host_rsa_key.pub \
	/etc/ssh/keys/ssh_host_ecdsa_key.pub; do
	ssh-keygen -lf "$public_key"
done

last_uid_gid=""
last_password_hash=""
touch /run/sftp-supervisor-ready

while :; do
	enabled="$(setting BACKUP_ENABLED true)"
	uid_gid="$(setting SFTP_UID_GID 1003:1003)"
	case "$enabled" in
		true|yes|1)
			[ "$uid_gid" = "$last_uid_gid" ] || apply_identity
			password_hash=""
			[ -s "$password_file" ] && password_hash="$(sha256sum "$password_file" | cut -d' ' -f1)"
			[ "$password_hash" = "$last_password_hash" ] || apply_password
			if [ -z "$sshd_pid" ] || ! kill -0 "$sshd_pid" 2>/dev/null; then
				/usr/sbin/sshd -D -e -f /etc/ssh/sshd_config &
				sshd_pid=$!
				echo "SFTP backup service enabled for $backup_user with UID:GID $uid_gid"
			fi
			;;
		false|no|0)
			stop_sshd
			passwd -l "$backup_user" >/dev/null 2>&1 || true
			last_password_hash=""
			;;
		*)
			echo "ERROR: BACKUP_ENABLED must be true or false" >&2
			exit 1
			;;
	esac
	sleep 5 &
	wait $!
done
