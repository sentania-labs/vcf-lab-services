#!/bin/sh
set -eu

uid="${1:-}"
gid="${2:-}"
backup_root="${BACKUP_ROOT:-/mnt/backup}"
marker_file="${BACKUP_OWNER_MARKER:-/etc/ssh/keys/backup-owner}"

case "$uid$gid" in
	''|*[!0-9]*)
		echo "ERROR: sftp-own-backup.sh needs a numeric UID and GID" >&2
		exit 2
		;;
esac

[ -d "$backup_root" ] || {
	echo "ERROR: backup storage $backup_root is not mounted" >&2
	exit 2
}

desired="$uid:$gid"
storage_id="$(stat -c '%d:%i' "$backup_root")"
current_owner="$(stat -c '%u:%g' "$backup_root")"

marker_storage=""
marker_identity=""
marker_outcome=""
if [ -r "$marker_file" ]; then
	marker_line="$(head -n 1 "$marker_file" 2>/dev/null || true)"
	marker_storage="$(printf '%s' "$marker_line" | cut -d' ' -f1)"
	marker_identity="$(printf '%s' "$marker_line" | cut -d' ' -f2)"
	marker_outcome="$(printf '%s' "$marker_line" | cut -d' ' -f3)"
fi

record_attempt() {
	mkdir -p "$(dirname "$marker_file")" 2>/dev/null || return 0
	printf '%s %s %s\n' "$storage_id" "$desired" "$1" > "$marker_file" 2>/dev/null || return 0
	chmod 0644 "$marker_file" 2>/dev/null || true
}

warn_unownable() {
	echo "WARNING: backup storage $backup_root is not owned by $desired and does not permit" >&2
	echo "         an ownership change. Set the share owner to $desired on the storage side," >&2
	echo "         then restart the sftp-backup service." >&2
}

if [ "$current_owner" = "$desired" ]; then
	record_attempt ok
	exit 0
fi

if [ "$marker_storage" = "$storage_id" ] \
	&& [ "$marker_identity" = "$desired" ] \
	&& [ "$marker_outcome" = failed ]; then
	warn_unownable
	exit 1
fi

if chown -R "$desired" "$backup_root" 2>/dev/null; then
	record_attempt ok
	echo "Re-owned $backup_root as $desired"
	exit 0
fi

record_attempt failed
warn_unownable
exit 1
