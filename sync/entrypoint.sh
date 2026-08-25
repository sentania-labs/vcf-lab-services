#!/bin/bash
set -euo pipefail

settings_file="${SETTINGS_FILE:-/etc/vcf-services/settings.env}"
STATE_DIR="${STATE_DIR:-/state}"
AUTH_FILE="${AUTH_FILE:-/run/secrets/activation-code.txt}"
TOOL_ROOT="${TOOL_ROOT:-/opt/vcfdt}"
VCFDT_TOOL_STORE="${VCFDT_TOOL_STORE:-}"
SYNC_COMMAND="${SYNC_COMMAND:-/usr/local/bin/sync.sh}"
POLL_SECONDS="${POLL_SECONDS:-10}"
REDIS_HOST="${REDIS_HOST:-}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_PASSWORD_FILE="${REDIS_PASSWORD_FILE:-/run/secrets/redis/password}"

REQUEST_QUEUE="vcf-services:sync:requests"
STATUS_KEY="vcf-services:sync:status"
VERSIONS_KEY="vcf-services:sync:versions"

load_settings() {
	if [ -f "$settings_file" ]; then
		set -a
		# shellcheck disable=SC1090
		. "$settings_file"
		set +a
	fi
	: "${CRON_SCHEDULE:=0 3 * * 0}"
}

redis_cmd() {
	[ -n "$REDIS_HOST" ] || return 1
	command -v redis-cli >/dev/null 2>&1 || return 1
	local auth=""
	if [ -s "$REDIS_PASSWORD_FILE" ]; then auth="$(cat "$REDIS_PASSWORD_FILE")"; fi
	REDISCLI_AUTH="$auth" redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" "$@" 2>/dev/null
}

cron_field_matches() {
	local spec="$1" value="$2" field_min="$3"
	local part start end step
	local -a parts
	IFS=',' read -r -a parts <<< "$spec"
	for part in "${parts[@]}"; do
		step=1
		case "$part" in
			*/*) step="${part#*/}"; part="${part%/*}" ;;
		esac
		[[ "$step" =~ ^[0-9]+$ ]] && [ "$step" -ge 1 ] || continue
		if [ "$part" = '*' ]; then
			start="$field_min"
			end=63
		elif [[ "$part" == *-* ]]; then
			start="${part%-*}"
			end="${part#*-}"
		else
			start="$part"
			end="$part"
		fi
		[[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] || continue
		if [ "$value" -ge "$start" ] && [ "$value" -le "$end" ] \
			&& [ $(( (value - start) % step )) -eq 0 ]; then
			return 0
		fi
	done
	return 1
}

cron_matches() {
	local schedule="$1" minute="$2" hour="$3" dom="$4" month="$5" dow="$6"
	local -a fields
	read -r -a fields <<< "$schedule"
	[ "${#fields[@]}" -eq 5 ] || return 1
	cron_field_matches "${fields[0]}" "$minute" 0 || return 1
	cron_field_matches "${fields[1]}" "$hour" 0 || return 1
	cron_field_matches "${fields[3]}" "$month" 1 || return 1
	local dom_ok=false dow_ok=false
	if cron_field_matches "${fields[2]}" "$dom" 1; then dom_ok=true; fi
	if cron_field_matches "${fields[4]}" "$dow" 0; then
		dow_ok=true
	elif [ "$dow" -eq 0 ] && cron_field_matches "${fields[4]}" 7 0; then
		dow_ok=true
	fi
	if [ "${fields[2]}" != '*' ] && [ "${fields[4]}" != '*' ]; then
		[ "$dom_ok" = true ] || [ "$dow_ok" = true ]
	else
		[ "$dom_ok" = true ] && [ "$dow_ok" = true ]
	fi
}

refresh_versions() {
	load_settings
	local tool="$TOOL_ROOT/bin/vcf-download-tool"
	if [ ! -s "$AUTH_FILE" ]; then
		jq -n --arg t "$(date -u +%FT%TZ)" \
			'{error:"not armed: activation code missing", fetchedAt:$t}' \
			| redis_cmd -x SET "$VERSIONS_KEY" >/dev/null || true
		return 0
	fi
	mkdir -p "$STATE_DIR"
	exec 8>"$STATE_DIR/sync.lock"
	if ! flock -n 8; then
		echo "[scheduler] versions refresh skipped: a sync or refresh already holds the depot lock"
		if [ "$(redis_cmd EXISTS "$VERSIONS_KEY")" != "1" ]; then
			jq -n --arg t "$(date -u +%FT%TZ)" \
				'{error:"refresh skipped: a sync or refresh is already running, retry when it finishes", fetchedAt:$t}' \
				| redis_cmd -x SET "$VERSIONS_KEY" >/dev/null || true
		fi
		exec 8>&-
		return 0
	fi
	local output rc=0
	if [ ! -x "$tool" ]; then
		jq -n --arg t "$(date -u +%FT%TZ)" \
			'{error:"VCF Download Tool is not installed; upload it in the admin console", fetchedAt:$t}' \
			| redis_cmd -x SET "$VERSIONS_KEY" >/dev/null || true
		exec 7>&-
		exec 8>&-
		return 0
	fi
	local tool_lock="${VCFDT_TOOL_STORE:-$TOOL_ROOT}/.update.lock"
	if [ ! -e "$tool_lock" ]; then
		jq -n --arg t "$(date -u +%FT%TZ)" \
			'{error:"the tool volume has no update lock; re-upload the VCF Download Tool in the admin console to repair it", fetchedAt:$t}' \
			| redis_cmd -x SET "$VERSIONS_KEY" >/dev/null || true
		exec 8>&-
		return 0
	fi
	exec 7<"$tool_lock"
	flock -s 7
	output="$("$tool" binaries list "--vcf-version=${VCF_VERSION:-9.1.0}" --type=UPGRADE \
		"--depot-download-activation-code-file=$AUTH_FILE" "--ceip=${CEIP:-DISABLE}" 2>&1)" || rc=$?
	jq -n --arg out "$output" --arg t "$(date -u +%FT%TZ)" --argjson rc "$rc" \
		'{output:$out, fetchedAt:$t, exitCode:$rc}' \
		| redis_cmd -x SET "$VERSIONS_KEY" >/dev/null || true
	exec 7>&-
	exec 8>&-
}

handle_request() {
	local payload="$1" kind
	kind="$(jq -r '.kind // "sync"' <<< "$payload" 2>/dev/null || true)"
	case "$kind" in
		sync)
			local -a targets=()
			mapfile -t targets < <(jq -r '.targets[]?' <<< "$payload" 2>/dev/null \
				| grep -Ex 'esx|install|upgrade|patches|vkr' || true)
			if [ "${#targets[@]}" -gt 0 ]; then
				echo "[scheduler] bus dispatch: ${targets[*]}"
				"$SYNC_COMMAND" "${targets[@]}" &
			else
				echo "[scheduler] ignored sync request with no valid targets"
			fi
			;;
		versions)
			refresh_versions &
			;;
		*)
			echo "[scheduler] ignored unknown request kind '$kind'"
			;;
	esac
}

init_state() {
	mkdir -p "$STATE_DIR"
	local armed=false tmp_state
	if [ -s "$AUTH_FILE" ]; then armed=true; fi
	tmp_state="$(mktemp "$STATE_DIR/state.json.XXXXXX")"
	if ! jq --argjson armed "$armed" '. + {running:false, armed:$armed, currentTarget:null}' \
		"$STATE_DIR/state.json" > "$tmp_state" 2>/dev/null || [ ! -s "$tmp_state" ]; then
		if [ -s "$STATE_DIR/state.json" ]; then
			echo "[scheduler] state.json is not valid JSON, regenerating defaults"
		fi
		jq -n --argjson armed "$armed" \
			'{running:false, armed:$armed, currentTarget:null, lastRun:{}}' > "$tmp_state"
	fi
	mv "$tmp_state" "$STATE_DIR/state.json"
	if [ "$armed" = false ]; then
		echo "[scheduler] not armed: activation code missing"
		echo "[scheduler] Register the Software Depot ID and save the activation code in the admin console."
	fi
}

refresh_armed_state() {
	local armed=false current tmp_state
	if [ -s "$AUTH_FILE" ]; then armed=true; fi
	exec 8>"$STATE_DIR/sync.lock"
	if ! flock -n 8; then
		exec 8>&-
		return 0
	fi
	current="$(jq -r '.armed' "$STATE_DIR/state.json" 2>/dev/null || true)"
	if [ "$current" = "$armed" ]; then
		exec 8>&-
		return 0
	fi
	tmp_state="$(mktemp "$STATE_DIR/state.json.XXXXXX")"
	if jq --argjson armed "$armed" '.armed=$armed' "$STATE_DIR/state.json" > "$tmp_state" 2>/dev/null; then
		mv "$tmp_state" "$STATE_DIR/state.json"
		redis_cmd -x SET "$STATUS_KEY" < "$STATE_DIR/state.json" >/dev/null || true
	else
		rm -f "$tmp_state"
	fi
	exec 8>&-
}

main() {
	load_settings
	init_state
	echo "[scheduler] vcf-services sync scheduler ready, schedule: '$CRON_SCHEDULE'"
	local attempt=0
	while [ "$attempt" -lt 30 ]; do
		if redis_cmd PING | grep -q PONG; then
			echo "[scheduler] connected to the Redis job bus"
			break
		fi
		attempt=$((attempt + 1))
		sleep 2
	done
	if [ -s "$STATE_DIR/state.json" ]; then
		redis_cmd -x SET "$STATUS_KEY" < "$STATE_DIR/state.json" >/dev/null || true
	fi
	local last_dispatched_minute="" now_minute payload
	while true; do
		load_settings
		refresh_armed_state
		now_minute="$(date +%Y%m%d%H%M)"
		if [ "$now_minute" != "$last_dispatched_minute" ] \
			&& cron_matches "$CRON_SCHEDULE" "$(date +%-M)" "$(date +%-H)" \
				"$(date +%-d)" "$(date +%-m)" "$(date +%w)"; then
			last_dispatched_minute="$now_minute"
			echo "[scheduler] schedule '$CRON_SCHEDULE' matched, dispatching sync"
			"$SYNC_COMMAND" &
		fi
		if payload="$(redis_cmd BRPOP "$REQUEST_QUEUE" "$POLL_SECONDS" | tail -n 1)" \
			&& [ -n "$payload" ]; then
			handle_request "$payload"
		else
			sleep 1
		fi
	done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
