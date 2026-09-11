#!/bin/bash
set -euo pipefail

settings_file="${SETTINGS_FILE:-/etc/vcf-services/settings.env}"
STATE_DIR="${STATE_DIR:-/state}"
AUTH_FILE="${AUTH_FILE:-/etc/vcf-services/secrets/activation-code.txt}"
TOOL_ROOT="${TOOL_ROOT:-/opt/vcfdt}"
VCFDT_TOOL_STORE="${VCFDT_TOOL_STORE:-}"
SYNC_COMMAND="${SYNC_COMMAND:-/usr/local/bin/sync.sh}"
POLL_SECONDS="${POLL_SECONDS:-10}"
REDIS_HOST="${REDIS_HOST:-}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_PASSWORD_FILE="${REDIS_PASSWORD_FILE:-/etc/vcf-services/secrets/redis-password}"
VERSION_STATUS_FILE="${VERSION_STATUS_FILE:-/etc/vcf-services/.vcf-services-version-status.json}"

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

# Verbose lock diagnostics, switched on from the console (SYNC_DIAGNOSTICS in
# settings.env, reloaded every loop) and off by default. Lines carry the
# operation, descriptor, device:inode as /proc/locks names it, and process
# identity: never arguments, environment, or secrets.
diag() {
	local flag="${SYNC_DIAGNOSTICS:-false}"
	case "${flag,,}" in
		true|yes|1) echo "[scheduler] diag: $*" ;;
	esac
}

lock_identity() {
	local fd="$1" dev="" ino=""
	read -r dev ino < <(stat -Lc '%d %i' "/proc/self/fd/$fd" 2>/dev/null) || true
	if [ -n "$ino" ]; then
		printf 'fd=%s dev=%02x:%02x ino=%s' "$fd" \
			"$(( ((dev >> 8) & 0xfff) | ((dev >> 32) & ~0xfff) ))" \
			"$(( (dev & 0xff) | ((dev >> 12) & ~0xff) ))" "$ino"
	else
		printf 'fd=%s dev=? ino=?' "$fd"
	fi
}

# Take the shared depot lock on fd 8 without blocking. Returns 0 when it is
# held, 1 when a sync or versions refresh legitimately holds it, and 2 when
# the lock could not be opened or taken at all; depot_lock_error then names
# the reason. util-linux flock exits 1 only for a conflicting lock, so any
# other status is a locking failure rather than a run in progress.
depot_lock_error=""
take_depot_lock() {
	local op="$1" rc=0 output
	mkdir -p "$STATE_DIR"
	if ! { exec 8>"$STATE_DIR/sync.lock"; } 2>/dev/null; then
		output="$( { : >>"$STATE_DIR/sync.lock"; } 2>&1 | sed 's/^[^:]*: line [0-9]*: //' || true)"
		output="${output#"$STATE_DIR/sync.lock: "}"
		depot_lock_error="could not open $STATE_DIR/sync.lock${output:+ ($output)}"
		diag "lock failed op=$op fd=8 pid=$BASHPID reason=open"
		return 2
	fi
	output="$(flock -n 8 2>&1)" || rc=$?
	case "$rc" in
		0)
			diag "lock acquired op=$op $(lock_identity 8) pid=$BASHPID"
			return 0
			;;
		1)
			diag "lock contended op=$op $(lock_identity 8) pid=$BASHPID"
			exec 8>&-
			return 1
			;;
		*)
			depot_lock_error="flock exit $rc${output:+: $output}"
			diag "lock failed op=$op $(lock_identity 8) pid=$BASHPID reason=flock"
			exec 8>&-
			return 2
			;;
	esac
}

release_depot_lock() {
	diag "lock released op=$1 $(lock_identity 8) pid=$BASHPID"
	exec 8>&-
}

# Launch a sync run already holding the depot lock it will keep. The lock is
# taken here on fd 9 and the locked descriptor is inherited by the run, so the
# next housekeeping pass of this loop (which takes the same lock on fd 8) can
# no longer slip in ahead of a run it just launched and make that run skip
# itself. sync.sh keeps an inherited fd 9 that refers to its lock file and
# opens the file only when invoked any other way. The scheduler closes its own
# copy right after the fork, so the lock lives exactly as long as the run and
# a run that exits or crashes releases it. When another sync or a versions
# refresh genuinely holds the lock, the run is still launched and reports the
# contention itself, exactly as before.
dispatch_sync() {
	local rc=0 output child
	mkdir -p "$STATE_DIR"
	if { exec 9>"$STATE_DIR/sync.lock"; } 2>/dev/null; then
		output="$(flock -n 9 2>&1)" || rc=$?
		case "$rc" in
			0) diag "lock acquired op=sync-dispatch $(lock_identity 9) pid=$BASHPID handoff=fd9" ;;
			1) diag "lock contended op=sync-dispatch $(lock_identity 9) pid=$BASHPID; the run reports it" ;;
			*) diag "lock failed op=sync-dispatch $(lock_identity 9) pid=$BASHPID reason=flock exit=$rc; the run reports it" ;;
		esac
	else
		diag "lock failed op=sync-dispatch fd=9 pid=$BASHPID reason=open; the run reports it"
	fi
	"$SYNC_COMMAND" "$@" &
	child=$!
	diag "sync launched pid=$child ppid=$BASHPID targets=${*:-configured}"
	exec 9>&-
	diag "lock handed off op=sync-dispatch fd=9 pid=$BASHPID to=$child"
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

# Refresh the versions listing. The scheduler loop forks this with the depot
# lock outcome it already obtained (see dispatch_versions_refresh); a direct
# call takes the lock itself.
refresh_versions() {
	local lock_state="${1:-}"
	load_settings
	local tool="$TOOL_ROOT/bin/vcf-download-tool"
	if [ ! -s "$AUTH_FILE" ]; then
		jq -n --arg t "$(date -u +%FT%TZ)" \
			'{error:"not armed: activation code missing", fetchedAt:$t}' \
			| redis_cmd -x SET "$VERSIONS_KEY" >/dev/null || true
		[ "$lock_state" != 0 ] || release_depot_lock versions-refresh
		return 0
	fi
	if [ -z "$lock_state" ]; then
		lock_state=0
		take_depot_lock versions-refresh || lock_state=$?
	fi
	if [ "$lock_state" -eq 1 ]; then
		echo "[scheduler] versions refresh skipped: a sync or refresh already holds the depot lock"
		if [ "$(redis_cmd EXISTS "$VERSIONS_KEY")" != "1" ]; then
			jq -n --arg t "$(date -u +%FT%TZ)" \
				'{error:"refresh skipped: a sync or refresh is already running, retry when it finishes", fetchedAt:$t}' \
				| redis_cmd -x SET "$VERSIONS_KEY" >/dev/null || true
		fi
		return 0
	elif [ "$lock_state" -ne 0 ]; then
		echo "[scheduler] ERROR: versions refresh could not take the depot lock: $depot_lock_error"
		jq -n --arg t "$(date -u +%FT%TZ)" --arg reason "$depot_lock_error" \
			'{error:("refresh failed: the depot lock could not be taken (" + $reason + "); check the sync service log"), fetchedAt:$t}' \
			| redis_cmd -x SET "$VERSIONS_KEY" >/dev/null || true
		return 0
	fi
	local output rc=0
	if [ ! -x "$tool" ]; then
		jq -n --arg t "$(date -u +%FT%TZ)" \
			'{error:"VCF Download Tool is not installed; upload it in the admin console", fetchedAt:$t}' \
			| redis_cmd -x SET "$VERSIONS_KEY" >/dev/null || true
		exec 7>&-
		release_depot_lock versions-refresh
		return 0
	fi
	local tool_lock="${VCFDT_TOOL_STORE:-$TOOL_ROOT}/.update.lock"
	if [ ! -e "$tool_lock" ]; then
		jq -n --arg t "$(date -u +%FT%TZ)" \
			'{error:"the tool volume has no update lock; re-upload the VCF Download Tool in the admin console to repair it", fetchedAt:$t}' \
			| redis_cmd -x SET "$VERSIONS_KEY" >/dev/null || true
		release_depot_lock versions-refresh
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
	release_depot_lock versions-refresh
}

# The same hand-off as dispatch_sync, for a versions refresh: the lock is
# taken here before the refresh is forked, so the next housekeeping pass of
# this loop cannot take it ahead of a refresh it just launched. The forked
# refresh inherits fd 8 and the lock with it, and this copy is closed right
# after the fork. A contended or failed lock is passed down for the refresh
# to report.
dispatch_versions_refresh() {
	local lock_state=0
	take_depot_lock versions-refresh || lock_state=$?
	refresh_versions "$lock_state" &
	if [ "$lock_state" -eq 0 ]; then
		exec 8>&-
		diag "lock handed off op=versions-refresh fd=8 pid=$BASHPID to=$!"
	fi
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
				dispatch_sync "${targets[@]}"
			else
				echo "[scheduler] ignored sync request with no valid targets"
			fi
			;;
		versions)
			dispatch_versions_refresh
			;;
		*)
			echo "[scheduler] ignored unknown request kind '$kind'"
			;;
	esac
}

init_state() {
	mkdir -p "$STATE_DIR"
	# The admin console opens this lock read only to tell whether a run already
	# holds the settings.env snapshot, so it has to exist before the first run.
	[ -e "$STATE_DIR/settings-snapshot.lock" ] || : > "$STATE_DIR/settings-snapshot.lock"
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

armed_refresh_lock_error=""
refresh_armed_state() {
	local armed=false current tmp_state lock_state=0
	if [ -s "$AUTH_FILE" ]; then armed=true; fi
	take_depot_lock armed-refresh || lock_state=$?
	if [ "$lock_state" -eq 1 ]; then
		# A sync or versions refresh holds the lock and publishes state itself.
		return 0
	elif [ "$lock_state" -ne 0 ]; then
		# Reported once per distinct reason rather than on every loop pass.
		if [ "$armed_refresh_lock_error" != "$depot_lock_error" ]; then
			armed_refresh_lock_error="$depot_lock_error"
			echo "[scheduler] ERROR: armed-state refresh could not take the depot lock: $depot_lock_error"
		fi
		return 0
	fi
	armed_refresh_lock_error=""
	current="$(jq -r '.armed' "$STATE_DIR/state.json" 2>/dev/null || true)"
	if [ "$current" = "$armed" ]; then
		release_depot_lock armed-refresh
		return 0
	fi
	tmp_state="$(mktemp "$STATE_DIR/state.json.XXXXXX")"
	if jq --argjson armed "$armed" '.armed=$armed' "$STATE_DIR/state.json" > "$tmp_state" 2>/dev/null; then
		mv "$tmp_state" "$STATE_DIR/state.json"
		redis_cmd -x SET "$STATUS_KEY" < "$STATE_DIR/state.json" >/dev/null || true
	else
		rm -f "$tmp_state"
	fi
	release_depot_lock armed-refresh
}

main() {
	load_settings
	init_state
	if [ -s "$VERSION_STATUS_FILE" ]; then
		local startup_error tmp_state
		startup_error="$(jq -r '.message // "persistent configuration version mismatch"' "$VERSION_STATUS_FILE" 2>/dev/null)"
		tmp_state="$(mktemp "$STATE_DIR/state.json.XXXXXX")"
		jq --arg error "$startup_error" \
			'. + {running:false, armed:false, currentTarget:null, startupBlocked:true, startupError:$error}' \
			"$STATE_DIR/state.json" > "$tmp_state"
		mv "$tmp_state" "$STATE_DIR/state.json"
		echo "[scheduler] ERROR: $startup_error"
		echo "[scheduler] Sync dispatch is disabled until the config volume is replaced or restored."
		while true; do
			redis_cmd -x SET "$STATUS_KEY" < "$STATE_DIR/state.json" >/dev/null || true
			sleep "$POLL_SECONDS"
		done
	fi
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
			dispatch_sync
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
