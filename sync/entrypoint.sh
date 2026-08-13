#!/bin/bash
set -euo pipefail

settings_file="${SETTINGS_FILE:-/etc/vcf-services/settings.env}"
STATE_DIR="${STATE_DIR:-/state}"
AUTH_FILE="${AUTH_FILE:-/run/secrets/activation-code.txt}"
TOOL_ROOT="${TOOL_ROOT:-/opt/vcfdt}"
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
	local output rc=0
	output="$("$tool" binaries list "--vcf-version=${VCF_VERSION:-9.1.0}" --type=UPGRADE \
		"--depot-download-activation-code-file=$AUTH_FILE" "--ceip=${CEIP:-DISABLE}" 2>&1)" || rc=$?
	jq -n --arg out "$output" --arg t "$(date -u +%FT%TZ)" --argjson rc "$rc" \
		'{output:$out, fetchedAt:$t, exitCode:$rc}' \
		| redis_cmd -x SET "$VERSIONS_KEY" >/dev/null || true
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
	if [ -s "$STATE_DIR/state.json" ]; then
		jq --argjson armed "$armed" '. + {running:false, armed:$armed, currentTarget:null}' \
			"$STATE_DIR/state.json" > "$tmp_state"
	else
		jq -n --argjson armed "$armed" \
			'{running:false, armed:$armed, currentTarget:null, lastRun:{}}' > "$tmp_state"
	fi
	mv "$tmp_state" "$STATE_DIR/state.json"
	if [ "$armed" = false ]; then
		echo "[scheduler] not armed: activation code missing"
		echo "[scheduler] Register the Software Depot ID in the Broadcom download tool registration flow, then rerun install.sh."
	fi
}

patch_tool_endpoint() {
	[ -f "$TOOL_ROOT/conf/application-prodv2.properties" ] || return 0
	: "${DEPOT_ENDPOINT:=dl.broadcom.com}"
	: "${TOKEN_URL:=https://eapi.broadcom.com/vcf/generateToken}"
	local properties="$TOOL_ROOT/conf/application-prodv2.properties" safe_token_url
	safe_token_url="$(printf '%s' "$TOKEN_URL" | sed 's/[\\&|]/\\&/g')"
	sed -i -E "s|^lcm\.depot\.adapter\.host=.*$|lcm.depot.adapter.host=${DEPOT_ENDPOINT}|" "$properties"
	if grep -q '^lcm.access_token.broadcom.authorization.server.url=' "$properties"; then
		sed -i -E "s|^lcm\.access_token\.broadcom\.authorization\.server\.url=.*$|lcm.access_token.broadcom.authorization.server.url=${safe_token_url}|" "$properties"
	else
		printf '%s\n' "lcm.access_token.broadcom.authorization.server.url=${TOKEN_URL}" >> "$properties"
	fi
}

main() {
	load_settings
	init_state
	patch_tool_endpoint
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
