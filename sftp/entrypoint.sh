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
		echo "WARNING: SFTP_UID_GID must contain a non-root numeric UID:GID. Keeping the running identity." >&2
		return 1
	}
	uid="${uid_gid%%:*}"
	gid="${uid_gid#*:}"

	if getent group "$backup_user" >/dev/null 2>&1; then
		current_gid="$(getent group "$backup_user" | cut -d: -f3)"
		if [ "$current_gid" != "$gid" ]; then
			groupmod -g "$gid" "$backup_user" || {
				echo "WARNING: could not move $backup_user to GID $gid. Retrying shortly." >&2
				return 1
			}
		fi
	else
		if getent group "$gid" >/dev/null 2>&1; then
			echo "WARNING: configured SFTP GID $gid is already assigned in the container" >&2
			return 1
		fi
		groupadd -g "$gid" "$backup_user" || {
			echo "WARNING: could not create the $backup_user group with GID $gid. Retrying shortly." >&2
			return 1
		}
	fi

	if id "$backup_user" >/dev/null 2>&1; then
		current_uid="$(id -u "$backup_user")"
		if [ "$current_uid" != "$uid" ]; then
			usermod -u "$uid" "$backup_user" || {
				echo "WARNING: could not move $backup_user to UID $uid, usually because a transfer is still running. Retrying shortly." >&2
				return 1
			}
		fi
		usermod -g "$gid" -d /mnt/backup -s /bin/sh "$backup_user" || {
			echo "WARNING: could not update the $backup_user account. Retrying shortly." >&2
			return 1
		}
	else
		if getent passwd "$uid" >/dev/null 2>&1; then
			echo "WARNING: configured SFTP UID $uid is already assigned in the container" >&2
			return 1
		fi
		useradd -M -u "$uid" -g "$gid" -d /mnt/backup -s /bin/sh "$backup_user" || {
			echo "WARNING: could not create the $backup_user account. Retrying shortly." >&2
			return 1
		}
	fi
	/usr/local/bin/sftp-own-backup.sh "$uid" "$gid" || true
	last_uid_gid="$uid_gid"
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
			if [ "$uid_gid" != "$last_uid_gid" ]; then
				apply_identity || true
			fi
			if [ -z "$last_uid_gid" ]; then
				stop_sshd
			else
				password_hash=""
				if [ -s "$password_file" ]; then
					password_hash="$(sha256sum "$password_file" | cut -d' ' -f1)"
				fi
				[ "$password_hash" = "$last_password_hash" ] || apply_password
				if [ -z "$sshd_pid" ] || ! kill -0 "$sshd_pid" 2>/dev/null; then
					/usr/sbin/sshd -D -e -f /etc/ssh/sshd_config &
					sshd_pid=$!
					echo "SFTP backup service enabled for $backup_user with UID:GID $uid_gid"
				fi
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
