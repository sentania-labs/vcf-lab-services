#!/bin/bash
# shellcheck disable=SC2016,SC2329
set -uo pipefail

settings_file="${SETTINGS_FILE:-/etc/vcf-services/settings.env}"
# settings.env is read under the snapshot lock further down, so the admin
# console can tell whether a save landed before or after this run took its
# values. Container environment defaults are set first and any key the console
# owns overrides its default when the file is sourced.
load_settings() {
	if [ -f "$settings_file" ]; then
		set -a
		# shellcheck disable=SC1090
		. "$settings_file"
		set +a
	fi
}

# Container environment settings. The admin console does not own these keys.
: "${DEPOT_DIR:=/depot}"
: "${STATE_DIR:=/state}"
: "${AUTH_FILE:=/etc/vcf-services/secrets/activation-code.txt}"
: "${TOOL_ROOT:=/opt/vcfdt}"
: "${VCFDT_TOOL_STORE:=$TOOL_ROOT}"
: "${REDIS_HOST:=}"
: "${REDIS_PORT:=6379}"
: "${REDIS_PASSWORD_FILE:=/etc/vcf-services/secrets/redis-password}"
: "${DEPOT_OWNERSHIP_FILE:=$STATE_DIR/depot-ownership.json}"
: "${DEPOT_OWNERSHIP_LOCK:=$STATE_DIR/depot-ownership.lock}"

# Defaults for the keys the console owns, applied after settings.env is read so
# a missing or blank value still lands on a working default.
apply_settings_defaults() {
	: "${SYNC_TARGETS:=esx install upgrade patches}"
	: "${VCF_VERSION:=9.1.0}"
	: "${SKU:=VCF}"
	: "${ESX_MODE:=download}"
	: "${CEIP:=DISABLE}"
	: "${LOG_RETENTION:=20}"
	: "${VKR_MATCH:=}"
	: "${VKR_OS:=}"
}

status_key="vcf-services:sync:status"
log_key="vcf-services:sync:log"
state_file="$STATE_DIR/state.json"
tool="$TOOL_ROOT/bin/vcf-download-tool"
mkdir -p "$STATE_DIR"

now() { date -u +%FT%TZ; }
log() { echo "[sync $(now)] $*"; }

protected_trees_for_target() {
	local label="$1"
	[ -s "$DEPOT_OWNERSHIP_FILE" ] || return 0
	jq -r --arg label "$label" '.trees | to_entries[] |
		select(.value.protected == true) |
		select(if $label == "esx-image-library" then .key == "ESX_HOST"
		       elif $label == "vkr-content-library" then .key == "VKR"
		       else true end) | .key' "$DEPOT_OWNERSHIP_FILE"
}

record_tree_if_absent() {
	local name="$1"
	local ownership="$2"
	local protected="$3"
	local tmp
	(
		flock -x 5
		tmp="$(mktemp "$STATE_DIR/depot-ownership.json.XXXXXX")" || exit 1
		if ! jq --arg name "$name" --arg ownership "$ownership" --argjson protected "$protected" \
			'.version = 1 | .trees = (.trees // {}) |
			 if .trees[$name] then .
			 else .trees[$name] = {ownership:$ownership, protected:$protected}
			 end' \
			"${DEPOT_OWNERSHIP_FILE:-/dev/null}" > "$tmp" 2>/dev/null; then
			jq -n --arg name "$name" --arg ownership "$ownership" --argjson protected "$protected" \
				'{version:1, trees:{($name):{ownership:$ownership, protected:$protected}}}' \
				> "$tmp"
		fi
		mv "$tmp" "$DEPOT_OWNERSHIP_FILE"
	) 5>"$DEPOT_OWNERSHIP_LOCK" || log "WARNING: could not record ownership for PROD/COMP/$name"
}

record_product_tree() {
	record_tree_if_absent "$1" product-managed false
}

declare -A known_depot_trees=()
comp_root="$DEPOT_DIR/PROD/COMP"

record_new_product_trees() {
	local tree name
	[ -d "$comp_root" ] || return 0
	while IFS= read -r -d '' tree; do
		name="$(basename "$tree")"
		if [ -z "${known_depot_trees[$name]+present}" ]; then
			record_product_tree "$name"
			known_depot_trees["$name"]=1
		fi
	done < <(find "$comp_root" -mindepth 1 -maxdepth 1 -type d -print0)
}

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

exec 9>"$STATE_DIR/sync.lock"
if ! flock -n 9; then
	log "another sync is already running, skipping this trigger"
	exit 0
fi

if [ -d "$comp_root" ]; then
	while IFS= read -r -d '' tree; do
		name="$(basename "$tree")"
		if [ -f "$tree/items.json" ] && [ -f "$tree/lib.json" ]; then
			record_tree_if_absent "$name" operator-provided true
		else
			record_tree_if_absent "$name" unknown false
		fi
		known_depot_trees["$name"]=1
	done < <(find "$comp_root" -mindepth 1 -maxdepth 1 -type d -print0)
fi

# Take the settings snapshot lock before reading settings.env and hold it for
# the whole run. A console save waits here, so it either lands before this run
# reads the file and is reported as active, or lands after and is reported as
# applying to the next run. The kernel releases the lock when this process ends.
snapshot_lock="$STATE_DIR/settings-snapshot.lock"
[ -e "$snapshot_lock" ] || : > "$snapshot_lock"
# Publish this run's identity before the lock is taken, so a console that sees
# the lock held always reads an identity at least as new as that lock. The
# console tags a save with the identity it reads and only reports the save as
# pending while that same run still holds the snapshot.
snapshot_run_file="$STATE_DIR/settings-snapshot.run"
snapshot_run_id="run-$(date -u +%Y%m%dT%H%M%S)-$$-$RANDOM"
if snapshot_run_tmp="$(mktemp "$STATE_DIR/settings-snapshot.run.XXXXXX")"; then
	printf '%s\n' "$snapshot_run_id" > "$snapshot_run_tmp"
	mv "$snapshot_run_tmp" "$snapshot_run_file"
else
	log "WARNING: could not record the run identity in $snapshot_run_file"
fi
if exec 6<"$snapshot_lock" && flock -x 6; then
	:
else
	log "WARNING: could not hold $snapshot_lock; a settings save during this run may be reported as active"
fi
load_settings
apply_settings_defaults
if [ "$#" -gt 0 ]; then SYNC_TARGETS="$*"; fi

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

tool_version=unknown
tool_release_id=unknown
tool_metadata="$TOOL_ROOT/.vcf-services.json"
if [ -s "$tool_metadata" ]; then
	tool_version="$(jq -r 'if (.version | type) == "string" and .version != "" then .version else "unknown" end' "$tool_metadata" 2>/dev/null || printf unknown)"
	tool_release_id="$(jq -r 'if (.releaseId | type) == "string" and .releaseId != "" then .releaseId else "unknown" end' "$tool_metadata" 2>/dev/null || printf unknown)"
fi

run_log="$STATE_DIR/run-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
exec > >(tee -a "$run_log") 2>&1
ln -sfn "$(basename "$run_log")" "$STATE_DIR/latest.log"

log_publisher_pid=""
if [ -n "$REDIS_HOST" ]; then
	main_pid=$$
	(
		exec 6<&- 9>&- >/dev/null 2>&1
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
successful_tool_sync=false

run_target() {
	local label="$1"
	shift
	log ">>> $label"
	local protected name
	protected="$(protected_trees_for_target "$label")"
	if [ -n "$protected" ]; then
		while IFS= read -r name; do
			log "PROD/COMP/$name is protected, skipping the target without changing it"
		done <<< "$protected"
		last_status="SKIPPED:PROTECTED"
		log "<<< $label $last_status"
		return
	fi
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
	tool_backed_target=false
	case "$target" in
		esx)
			tool_backed_target=true
			run_target esx-image-library "$tool" esx "$ESX_MODE" "$ceip_opt" \
				"--depot-store=$DEPOT_DIR" "$auth_opt"
			;;
		install)
			tool_backed_target=true
			run_target vcf-install "$tool" binaries download "$ceip_opt" \
				"--depot-store=$DEPOT_DIR" "$auth_opt" "--vcf-version=$VCF_VERSION" \
				"--sku=$SKU" --automated-install --type=INSTALL
			;;
		upgrade)
			tool_backed_target=true
			run_target vcf-upgrade "$tool" binaries download "$ceip_opt" \
				"--depot-store=$DEPOT_DIR" "$auth_opt" "--vcf-version=$VCF_VERSION" \
				"--sku=$SKU" --type=UPGRADE
			;;
		patches)
			tool_backed_target=true
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
	record_new_product_trees
	if [ "$tool_backed_target" = true ] && [ "$last_status" = OK ]; then
		successful_tool_sync=true
	fi
	write_state '.lastRun[$target]={status:$status, finishedAt:$finished, toolVersion:(if $toolBacked then $toolVersion else "not applicable" end), toolReleaseId:(if $toolBacked then $toolReleaseId else "not applicable" end)}' \
		--arg target "$target" --arg status "$last_status" --arg finished "$(now)" \
		--arg toolVersion "$tool_version" --arg toolReleaseId "$tool_release_id" \
		--argjson toolBacked "$tool_backed_target"
done

if [ "$overall_rc" -eq 0 ] && [ "$successful_tool_sync" = true ]; then
	previous_link="$VCFDT_TOOL_STORE/previous"
	if [ -L "$previous_link" ]; then
		previous_target="$(readlink -f "$previous_link" 2>/dev/null || true)"
		case "$previous_target" in
			"$VCFDT_TOOL_STORE"/releases/*)
				rm -f "$previous_link"
				rm -rf -- "$previous_target"
				log "promoted tool $tool_version and removed the previous release"
				;;
			*) log "WARNING: previous tool link does not point inside the release store; it was not removed" ;;
		esac
	fi
fi

log "sync finished overall rc=$overall_rc"
exit "$overall_rc"
