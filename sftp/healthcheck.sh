#!/bin/sh
set -eu

test -f /run/sftp-supervisor-ready

enabled="$(sed -n 's/^BACKUP_ENABLED=["'\'']\{0,1\}\([^"'\'']*\)["'\'']\{0,1\}$/\1/p' \
	"${SETTINGS_FILE:-/config/settings.env}" 2>/dev/null | tail -n 1)"
case "${enabled:-false}" in
	true|yes|1)
		test -s /run/sshd.pid
		kill -0 "$(cat /run/sshd.pid)"
		/usr/sbin/sshd -t -f /etc/ssh/sshd_config
		;;
	false|no|0) ;;
	*) exit 1 ;;
esac
