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
: "${SYNC_TARGETS:=esx install upgrade patches}"
: "${VCF_VERSION:=9.1.0}"
: "${SKU:=VCF}"
: "${ESX_MODE:=download}"
: "${CEIP:=DISABLE}"
: "${LOG_RETENTION:=20}"
: "${VKR_MATCH:=}"
: "${VKR_OS:=}"

state_file="$STATE_DIR/state.json"
tool="$TOOL_ROOT/bin/vcf-download-tool"
mkdir -p "$STATE_DIR"

now() { date -u +%FT%TZ; }
log() { echo "[sync $(now)] $*"; }

write_state() {
	local filter="$1"
	shift
	local tmp
	tmp="$(mktemp "$STATE_DIR/state.json.XXXXXX")" || return 0
	[ -s "$state_file" ] || printf '{}\n' > "$state_file"
	if jq "$@" "$filter" "$state_file" > "$tmp" 2>/dev/null; then
		mv "$tmp" "$state_file"
	else
		rm -f "$tmp"
	fi
}

not_armed_message() {
	log "not armed: activation code missing"
	log "Run '$tool configuration get --machineId', register that Software Depot ID in the Broadcom download tool registration flow, then rerun install.sh with the activation code."
}

if [ "${1:-}" = "--status" ]; then
	if [ -s "$AUTH_FILE" ]; then
		echo "armed: activation code present"
	else
		echo "not armed: activation code missing"
		echo "Register the Software Depot ID in the Broadcom download tool registration flow, then rerun install.sh."
	fi
	exit 0
fi

if [ "$#" -gt 0 ]; then SYNC_TARGETS="$*"; fi

exec 9>"$STATE_DIR/sync.lock"
if ! flock -n 9; then
	log "another sync is already running, skipping this trigger"
	exit 0
fi

run_log="$STATE_DIR/run-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
exec > >(tee -a "$run_log") 2>&1
ln -sfn "$(basename "$run_log")" "$STATE_DIR/latest.log"

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
