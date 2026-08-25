#!/bin/bash
# shellcheck disable=SC2016,SC2329
set -uo pipefail

settings_file="${SETTINGS_FILE:-/etc/vcf-services/settings.env}"
if [ -f "$settings_file" ]; then
	set -a
	# shellcheck disable=SC1090
	. "$settings_file"
	set +a
fi

: "${DEPOT_DIR:=/depot}"
: "${STATE_DIR:=/state}"
: "${AUTH_FILE:=/run/secrets/activation-code.txt}"
: "${TOOL_ROOT:=/opt/vcfdt}"
: "${VCFDT_TOOL_STORE:=$TOOL_ROOT}"
: "${SYNC_TARGETS:=esx install upgrade patches}"
: "${VCF_VERSION:=9.1.0}"
: "${SKU:=VCF}"
: "${ESX_MODE:=download}"
: "${CEIP:=DISABLE}"
: "${LOG_RETENTION:=20}"
: "${VKR_MATCH:=}"
: "${VKR_OS:=}"
: "${REDIS_HOST:=}"
: "${REDIS_PORT:=6379}"
: "${REDIS_PASSWORD_FILE:=/run/secrets/redis/password}"

status_key="vcf-services:sync:status"
log_key="vcf-services:sync:log"
state_file="$STATE_DIR/state.json"
tool="$TOOL_ROOT/bin/vcf-download-tool"
mkdir -p "$STATE_DIR"

now() { date -u +%FT%TZ; }
log() { echo "[sync $(now)] $*"; }

redis_cmd() {
	[ -n "$REDIS_HOST" ] || return 1
	command -v redis-cli >/dev/null 2>&1 || return 1
	local auth=""
	if [ -s "$REDIS_PASSWORD_FILE" ]; then auth="$(cat "$REDIS_PASSWORD_FILE")"; fi
	REDISCLI_AUTH="$auth" redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" "$@" 2>/dev/null
}

publish_status() {
	[ -s "$state_file" ] || return 0
	redis_cmd -x SET "$status_key" < "$state_file" >/dev/null || true
}

publish_log_tail() {
	[ -s "${run_log:-}" ] || return 0
	tail -n 500 "$run_log" | redis_cmd -x SET "$log_key" >/dev/null || true
}

write_state() {
	local filter="$1"
	shift
	local tmp
	tmp="$(mktemp "$STATE_DIR/state.json.XXXXXX")" || return 0
	[ -s "$state_file" ] || printf '{}\n' > "$state_file"
	if jq "$@" "$filter" "$state_file" > "$tmp" 2>/dev/null; then
		mv "$tmp" "$state_file"
		publish_status
	else
		rm -f "$tmp"
	fi
}

not_armed_message() {
	log "not armed: activation code missing"
	log "Register the Software Depot ID and save the activation code in the admin console."
}

if [ "${1:-}" = "--status" ]; then
	if [ -s "$AUTH_FILE" ]; then
		echo "armed: activation code present"
	else
		echo "not armed: activation code missing"
		echo "Register the Software Depot ID and save the activation code in the admin console."
	fi
	exit 0
fi

if [ "$#" -gt 0 ]; then SYNC_TARGETS="$*"; fi

exec 9>"$STATE_DIR/sync.lock"
if ! flock -n 9; then
	log "another sync is already running, skipping this trigger"
	exit 0
fi

if [ ! -x "$tool" ]; then
	write_state '. + {running:false, currentTarget:null}'
	log "VCF Download Tool is not installed; upload it in the admin console"
	exit 1
fi
tool_lock="$VCFDT_TOOL_STORE/.update.lock"
if [ ! -e "$tool_lock" ]; then
	write_state '. + {running:false, currentTarget:null}'
	log "ERROR: the tool volume has no $tool_lock update lock; the tool store is incomplete"
	log "Re-upload the VCF Download Tool in the admin console to repair the tool volume."
	exit 1
fi
exec 7<"$tool_lock"
flock -s 7

run_log="$STATE_DIR/run-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
exec > >(tee -a "$run_log") 2>&1
ln -sfn "$(basename "$run_log")" "$STATE_DIR/latest.log"

log_publisher_pid=""
if [ -n "$REDIS_HOST" ]; then
	main_pid=$$
	(
		exec 9>&- >/dev/null 2>&1
		while kill -0 "$main_pid" 2>/dev/null; do
			publish_log_tail
			sleep 2
		done
	) &
	log_publisher_pid=$!
fi
stop_log_publisher() {
	if [ -n "$log_publisher_pid" ]; then
		kill "$log_publisher_pid" 2>/dev/null || true
		log_publisher_pid=""
	fi
	publish_log_tail
}
trap stop_log_publisher EXIT

prune_logs() {
	if [[ "$LOG_RETENTION" =~ ^[1-9][0-9]*$ ]]; then
		mapfile -t old_logs < <(find "$STATE_DIR" -maxdepth 1 -type f -name 'run-*.log' -printf '%T@ %p\n' \
			| sort -rn | tail -n "+$((LOG_RETENTION + 1))" | cut -d' ' -f2-)
		if [ "${#old_logs[@]}" -gt 0 ]; then rm -f -- "${old_logs[@]}"; fi
	fi
}
prune_logs

if [ ! -s "$AUTH_FILE" ]; then
	write_state '. + {running:false, armed:false, currentTarget:null}'
	not_armed_message
	exit 0
fi

if [ "$CEIP" != "DISABLE" ] && [ "$CEIP" != "ENABLE" ]; then
	log "ERROR: CEIP must be explicitly set to ENABLE or DISABLE"
	exit 2
fi

if [ ! -x "$tool" ]; then
	log "ERROR: VCF Download Tool is missing or not executable at $tool"
	exit 2
fi

write_state '. + {running:true, armed:true, currentTarget:null, startedAt:$t, targets:$targets}' \
	--arg t "$(now)" --arg targets "$SYNC_TARGETS"

finish_state() {
	write_state '. + {running:false, currentTarget:null, finishedAt:$t}' --arg t "$(now)"
	stop_log_publisher
}
trap finish_state EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

auth_opt="--depot-download-activation-code-file=$AUTH_FILE"
ceip_opt="--ceip=$CEIP"
overall_rc=0
last_status=""

run_target() {
	local label="$1"
	shift
	log ">>> $label"
	if "$@"; then
		log "<<< $label OK"
		last_status=OK
	else
		local target_rc=$?
		overall_rc=$target_rc
		last_status="FAILED:$target_rc"
		log "<<< $label FAILED rc=$target_rc, continuing"
	fi
}

for target in $SYNC_TARGETS; do
	write_state '.currentTarget=$target' --arg target "$target"
	last_status=unknown
	case "$target" in
		esx)
			run_target esx-image-library "$tool" esx "$ESX_MODE" "$ceip_opt" \
				"--depot-store=$DEPOT_DIR" "$auth_opt"
			;;
		install)
			run_target vcf-install "$tool" binaries download "$ceip_opt" \
				"--depot-store=$DEPOT_DIR" "$auth_opt" "--vcf-version=$VCF_VERSION" \
				"--sku=$SKU" --automated-install --type=INSTALL
			;;
		upgrade)
			run_target vcf-upgrade "$tool" binaries download "$ceip_opt" \
				"--depot-store=$DEPOT_DIR" "$auth_opt" "--vcf-version=$VCF_VERSION" \
				"--sku=$SKU" --type=UPGRADE
			;;
		patches)
			run_target vcf-patches "$tool" binaries download "$ceip_opt" \
				"--depot-store=$DEPOT_DIR" "$auth_opt" "--vcf-version=$VCF_VERSION" \
				"--sku=$SKU" --patches-only
			;;
		vkr)
			run_target vkr-content-library /usr/local/lib/vcf-services/targets/vkr.sh \
				"$DEPOT_DIR" "$VKR_MATCH" "$VKR_OS"
			;;
		*)
			last_status=INVALID
			overall_rc=2
			log "unknown sync target '$target', continuing"
			;;
	esac
	write_state '.lastRun[$target]={status:$status, finishedAt:$finished}' \
		--arg target "$target" --arg status "$last_status" --arg finished "$(now)"
done

log "sync finished overall rc=$overall_rc"
exit "$overall_rc"
