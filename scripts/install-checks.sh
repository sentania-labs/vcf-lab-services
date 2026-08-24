#!/bin/bash
# Preflight validators shared by install.sh and tests/test_install_checks.sh.

cron_field_in_range() {
	local spec="$1" field_min="$2" field_max="$3" label="$4"
	local part start end step
	local -a parts
	IFS=',' read -r -a parts <<< "$spec"
	[ "${#parts[@]}" -gt 0 ] || { echo "ERROR: cron $label field is empty" >&2; return 1; }
	for part in "${parts[@]}"; do
		step=1
		case "$part" in
			*/*) step="${part##*/}"; part="${part%/*}" ;;
		esac
		[[ "$step" =~ ^[0-9]+$ ]] && [ "$step" -ge 1 ] || {
			echo "ERROR: cron $label field has an invalid step '/$step' (must be a number of at least 1)" >&2
			return 1
		}
		if [ "$part" = '*' ]; then
			continue
		fi
		if [[ "$part" == *-* ]]; then
			start="${part%-*}"
			end="${part#*-}"
		else
			start="$part"
			end="$part"
		fi
		[[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] || {
			echo "ERROR: cron $label field '$part' is not numeric" >&2
			return 1
		}
		if [ "$start" -gt "$end" ]; then
			echo "ERROR: cron $label range '$part' runs backwards" >&2
			return 1
		fi
		if [ "$start" -lt "$field_min" ] || [ "$end" -gt "$field_max" ]; then
			echo "ERROR: cron $label field '$part' is outside the valid range $field_min-$field_max" >&2
			return 1
		fi
	done
	return 0
}

validate_cron_schedule() {
	local schedule="$1"
	local -a fields
	read -r -a fields <<< "$schedule"
	[ "${#fields[@]}" -eq 5 ] || {
		echo "ERROR: cron schedule must contain five fields (minute hour day-of-month month day-of-week)" >&2
		return 1
	}
	cron_field_in_range "${fields[0]}" 0 59 minute || return 1
	cron_field_in_range "${fields[1]}" 0 23 hour || return 1
	cron_field_in_range "${fields[2]}" 1 31 day-of-month || return 1
	cron_field_in_range "${fields[3]}" 1 12 month || return 1
	cron_field_in_range "${fields[4]}" 0 7 day-of-week || return 1
	return 0
}

validate_provided_tls() {
	local cert="$1" key="$2" fqdn="$3" cert_pub key_pub
	openssl x509 -in "$cert" -noout -checkhost "$fqdn" 2>/dev/null \
		| grep -q "does match" || {
		echo "ERROR: supplied certificate does not cover $fqdn" >&2
		return 1
	}
	openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || {
		echo "ERROR: supplied certificate is expired (valid until $(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)). Renew it, then rerun install.sh." >&2
		return 1
	}
	cert_pub="$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null | openssl sha256)"
	key_pub="$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl sha256)"
	[ -n "$cert_pub" ] && [ "$cert_pub" = "$key_pub" ] || {
		echo "ERROR: supplied certificate and key do not match" >&2
		return 1
	}
	return 0
}

validate_uid_gid() {
	local value="$1" uid gid
	[[ "$value" =~ ^[0-9]+:[0-9]+$ ]] || {
		echo "ERROR: UID:GID must contain two numeric values separated by a colon" >&2
		return 1
	}
	uid="${value%%:*}"
	gid="${value#*:}"
	[ "$uid" -ge 1 ] && [ "$uid" -le 2147483647 ] \
		&& [ "$gid" -ge 1 ] && [ "$gid" -le 2147483647 ] || {
		echo "ERROR: UID:GID values must be non-root and no greater than 2147483647" >&2
		return 1
	}
}

validate_tcp_port() {
	local port="$1"
	[[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || {
		echo "ERROR: TCP port must be a whole number from 1 through 65535" >&2
		return 1
	}
}

host_tcp_port_is_bound() {
	local port="$1"
	ss -H -ltn | awk -v suffix=":$port" '
		$4 == suffix || (length($4) >= length(suffix) && substr($4, length($4) - length(suffix) + 1) == suffix) { found=1 }
		END { exit !found }
	'
}

container_publishes_tcp_port() {
	local container="$1" port="$2"
	docker inspect -f '{{range $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{println .HostPort}}{{end}}{{end}}' \
		"$container" 2>/dev/null | grep -qx "$port"
}

path_has_no_parent_segment() {
	local path="$1"
	case "/$path/" in
		*/../*) echo "ERROR: $path must not contain a '..' segment" >&2; return 1 ;;
	esac
	return 0
}

paths_are_disjoint() {
	local first="${1%/}" second="${2%/}"
	[ -n "$first" ] && [ -n "$second" ] || {
		echo "ERROR: both paths must be non-empty" >&2
		return 1
	}
	path_has_no_parent_segment "$first" || return 1
	path_has_no_parent_segment "$second" || return 1
	[ "$first" != "$second" ] || {
		echo "ERROR: $second must not be the same directory as $first" >&2
		return 1
	}
	case "$second/" in
		"$first"/*) echo "ERROR: $second must not sit inside $first" >&2; return 1 ;;
	esac
	case "$first/" in
		"$second"/*) echo "ERROR: $second must not contain $first" >&2; return 1 ;;
	esac
	return 0
}

check_backup_free_space() {
	local available_kb="$1" label="$2" hard_floor_gb="$3" advisory_gb="$4"
	local available_gb=$((available_kb / 1024 / 1024))
	if [ -n "$hard_floor_gb" ]; then
		if [ "$available_gb" -lt "$hard_floor_gb" ]; then
			echo "ERROR: backup storage $label has ${available_gb} GB free, below the requested ${hard_floor_gb} GB floor." >&2
			return 1
		fi
		return 0
	fi
	if [ "$available_gb" -lt "$advisory_gb" ]; then
		echo "WARNING: backup storage $label has ${available_gb} GB free, under the ${advisory_gb} GB advisory level." >&2
		echo "         Backups will still be accepted. Use --min-backup-free-gb to make this a hard floor." >&2
	fi
	return 0
}
