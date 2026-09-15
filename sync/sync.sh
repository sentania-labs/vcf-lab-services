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
	: "${SYNC_DIAGNOSTICS:=false}"
}

status_key="vcf-services:sync:status"
log_key="vcf-services:sync:log"
state_file="$STATE_DIR/state.json"
catalog_file="$STATE_DIR/catalog.json"
catalog_attempt_file="$STATE_DIR/catalog-attempt.json"
tool="$TOOL_ROOT/bin/vcf-download-tool"
mkdir -p "$STATE_DIR"

now() { date -u +%FT%TZ; }
log() { echo "[sync $(now)] $*"; }

# Verbose lock diagnostics are a logging switch rather than a run value, so
# the console's SYNC_DIAGNOSTICS flag is read before the depot lock is taken.
# Every value that shapes the run is still read under the settings snapshot
# lock further down. Off by default; a scheduler that dispatched this run
# exports the flag as well, and a direct invocation reads settings.env here.
sync_diagnostics=false
# shellcheck disable=SC1090
diagnostics_flag="$( (. "$settings_file" 2>/dev/null; printf '%s' "${SYNC_DIAGNOSTICS:-}") 2>/dev/null || true)"
case "${diagnostics_flag,,}" in
	true|yes|1) sync_diagnostics=true ;;
esac
diag() {
	[ "$sync_diagnostics" = true ] || return 0
	log "diag: $*"
}
# Name what a descriptor refers to the way /proc/locks does: major:minor and inode.
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

protected_trees() {
	[ -e "$DEPOT_OWNERSHIP_FILE" ] || [ -L "$DEPOT_OWNERSHIP_FILE" ] || return 0
	jq -er 'if (.trees | type) != "object" then error("invalid ownership manifest") else . end |
		[.trees | to_entries[] | select(.value.protected == true) | .key] | join("\n")' \
		"$DEPOT_OWNERSHIP_FILE" | LC_ALL=C sort -u
}

# Each Component value in the tool's binaries table is the PROD/COMP tree that
# binary lands in. The header names the column, so its position is read rather
# than assumed; a listing with no such table exits 3. After the header, lines
# without a '|' (rules, the element count, prose) are ignored, and every other
# line is a row whose trimmed Component cell is printed as it stands. A row
# with fewer cells than the header or an empty Component cell exits 3 rather
# than being dropped, since a dropped row could hide a protected tree. A Full
# Name containing ' | ' only adds cells after Component. `binaries list` and the
# "Binaries to be downloaded" table the download itself prints come from the
# same table printer in the tool, which labels that column 'Component' and
# delimits columns with ' | ', as the live download logs show. A listing
# without that header is therefore not a table this code can read, and the
# target fails closed as FAILED:UNVERIFIED rather than running unchecked.
components_from_listing() {
	awk -F'|' '
		function trim(text) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", text); return text }
		column == 0 {
			for (i = 1; i <= NF; i++) {
				if (trim($i) == "Component") { column = i; columns = NF }
			}
			next
		}
		index($0, "|") == 0 { next }
		{
			value = trim($column)
			if (NF < columns || value == "") { unparsed = 1; exit 3 }
			print value
		}
		END { if (column == 0 || unparsed) exit 3 }'
}

# The trees a target writes, one name per line. The ESX image library and the
# VKr mirror are single-tree commands: every lcm.esx.* path in the tool
# configuration sits under PROD/COMP/ESX_HOST, and targets/vkr.sh mirrors into
# PROD/COMP/VKR. A `binaries download` run spans whatever components its
# filter selects, so those targets ask the tool: `binaries list` with the same
# filter prints the table the download itself prints under "Binaries to be
# downloaded" before it starts writing. The tool's own help documents the same
# filter group for list as for download (--automated-install, --patches-only,
# --sku, --type, --vcf-version), so the download's filters are passed
# unchanged. Nothing about those targets is mapped by hand.
written_trees=""
scope_status=""
scope_rc=0
trees_written_by() {
	local label="$1"
	shift
	case "$label" in
		esx-image-library) written_trees=ESX_HOST ;;
		vkr-content-library) written_trees=VKR ;;
		*) components_for_download "$@" ;;
	esac
}

components_for_download() {
	local -a listing=()
	local argument output line rc=0
	for argument in "$@"; do
		case "$argument" in
			--depot-store=*) continue ;;
		esac
		listing+=("$argument")
	done
	if [ "${listing[1]:-}" != binaries ] || [ "${listing[2]:-}" != download ]; then
		log "ERROR: no listing exists for the command '${listing[*]}'"
		scope_status="FAILED:UNVERIFIED"
		scope_rc=1
		return 1
	fi
	listing[2]=list
	output="$("${listing[@]}" 2>&1)" || rc=$?
	if [ "$rc" -ne 0 ]; then
		log "ERROR: the tool could not list the binaries this target would download (exit $rc)"
		printf '%s\n' "$output" | tail -n 5 | while IFS= read -r line; do log "  tool: $line"; done
		scope_status="FAILED:$rc"
		scope_rc=$rc
		return 1
	fi
	if ! written_trees="$(printf '%s\n' "$output" | components_from_listing | LC_ALL=C sort -u)"; then
		log "ERROR: the tool listing has no component table, so the trees this target would write cannot be verified"
		printf '%s\n' "$output" | tail -n 5 | while IFS= read -r line; do log "  tool: $line"; done
		scope_status="FAILED:UNVERIFIED"
		scope_rc=1
		return 1
	fi
}

# A protected tree is fingerprinted by the type, mode, owner, size, mtime,
# link count, inode, path and link target of every entry below it. No bytes
# are read: any entry that is added, removed, replaced, renamed, resized,
# re-timed, re-linked or re-permissioned changes a line. The lines are
# streamed to a temporary file rather than held in the shell, and compared
# with streaming tools, so memory stays bounded however large the tree is.
# An entry find cannot read is logged as a warning naming its path and its
# error line stays in the fingerprint, so it compares equal before and after
# the run; only a fingerprint that cannot be written fails the snapshot.
fingerprint_dir=""
fingerprint_workspace() {
	[ -z "$fingerprint_dir" ] || return 0
	fingerprint_dir="$(mktemp -d "${TMPDIR:-/tmp}/vcf-services-fingerprint.XXXXXX")"
}

tree_fingerprint() {
	local tree="$comp_root/$1" output="$2" report="${3:-}"
	local entries="$2.entries" errors="$2.errors" count line
	if [ -e "$tree" ] || [ -L "$tree" ]; then
		find "$tree" -printf '%y %m %U %G %s %T@ %n %i %p -> %l\n' > "$entries" 2> "$errors"
		if ! LC_ALL=C sort "$entries" "$errors" > "$output"; then
			rm -f "$entries" "$errors"
			return 1
		fi
		if [ -n "$report" ] && [ -s "$errors" ]; then
			count="$(grep -c . "$errors")"
			log "WARNING: find could not read some entries under protected tree PROD/COMP/$1 ($count); the sync runs as the same user, so it cannot write inside them either"
			head -n 5 "$errors" | while IFS= read -r line; do log "  $line"; done
		fi
		rm -f "$entries" "$errors"
	else
		printf 'absent\n' > "$output" || return 1
	fi
}

snapshot_protected() {
	local name
	fingerprint_workspace || return 1
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		tree_fingerprint "$name" "$fingerprint_dir/$name.before" report || return 1
	done <<< "$1"
}

verify_protected_unchanged() {
	local trees="$1" label="$2"
	local name line changed=0 unverifiable=0 count before after
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		before="$fingerprint_dir/$name.before"
		after="$fingerprint_dir/$name.after"
		if ! tree_fingerprint "$name" "$after"; then
			unverifiable=1
			log "ERROR: could not take the after-run fingerprint of PROD/COMP/$name after $label ran, so the protected tree could not be verified"
			rm -f "$before" "$after"
			continue
		fi
		if cmp -s "$before" "$after"; then
			rm -f "$before" "$after"
			continue
		fi
		changed=1
		count="$(LC_ALL=C comm -3 "$before" "$after" | wc -l)"
		log "ERROR: protected tree PROD/COMP/$name changed while $label ran ($count entries differ); review it before the next run"
		LC_ALL=C comm -3 "$before" "$after" | head -n 5 | sed $'s/^\t/> /; t; s/^/< /' \
			| while IFS= read -r line; do log "  $line"; done
		rm -f "$before" "$after"
	done <<< "$trees"
	[ "$changed" -eq 0 ] || return 1
	[ "$unverifiable" -eq 0 ] || return 2
	return 0
}

record_tree_if_absent() {
	local name="$1"
	local ownership="$2"
	local protected="$3"
	local tmp
	(
		flock -x 5 || exit 1
		tmp="$(mktemp "$STATE_DIR/depot-ownership.json.XXXXXX")" || exit 1
		trap 'rm -f "$tmp"' EXIT
		if [ -e "$DEPOT_OWNERSHIP_FILE" ] || [ -L "$DEPOT_OWNERSHIP_FILE" ]; then
			jq -e --arg name "$name" --arg ownership "$ownership" --argjson protected "$protected" \
				'if (.trees | type) != "object" then error("invalid ownership manifest") else . end |
				 .version = 1 |
				 if .trees[$name] then .
				 else .trees[$name] = {ownership:$ownership, protected:$protected}
				 end' "$DEPOT_OWNERSHIP_FILE" > "$tmp" || exit 1
		else
			jq -en --arg name "$name" --arg ownership "$ownership" --argjson protected "$protected" \
				'{version:1, trees:{($name):{ownership:$ownership, protected:$protected}}}' \
				> "$tmp" || exit 1
		fi
		mv -- "$tmp" "$DEPOT_OWNERSHIP_FILE" || exit 1
	) 5>"$DEPOT_OWNERSHIP_LOCK" || {
		log "ERROR: could not record ownership for PROD/COMP/$name; refusing sync"
		return 1
	}
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
			record_product_tree "$name" || return 1
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

catalog_attempt_id=""
catalog_attempt_started=""
catalog_attempt_open=false
catalog_workspace=""

clear_catalog_workspace() {
	[ -z "$catalog_workspace" ] || rm -rf -- "$catalog_workspace"
	catalog_workspace=""
}

write_catalog_attempt() {
	local status="$1" error="${2:-}" finished="${3:-}" tmp
	tmp="$(mktemp "$STATE_DIR/catalog-attempt.json.XXXXXX")" || {
		log "WARNING: could not create catalog attempt metadata"
		return 0
	}
	if jq -n --arg id "$catalog_attempt_id" --arg status "$status" \
		--arg started "$catalog_attempt_started" --arg finished "$finished" \
		--arg error "$error" \
		'{version:1, attemptId:$id, status:$status, startedAt:$started}
		 | if $finished != "" then .finishedAt=$finished else . end
		 | if $error != "" then .error=$error else . end' > "$tmp" \
		&& mv -- "$tmp" "$catalog_attempt_file"; then
		[ "$status" = running ] || catalog_attempt_open=false
	else
		rm -f -- "$tmp"
		log "WARNING: could not publish catalog attempt metadata"
	fi
}

begin_catalog_attempt() {
	catalog_attempt_started="$(now)"
	catalog_attempt_id="catalog-$(date -u +%Y%m%dT%H%M%S)-$$-$RANDOM"
	catalog_attempt_open=true
	write_catalog_attempt running
}

fail_catalog_attempt() {
	[ "$catalog_attempt_open" = true ] || return 0
	write_catalog_attempt failed "$1" "$(now)"
}

finish_catalog_on_exit() {
	clear_catalog_workspace
	[ "$catalog_attempt_open" = true ] || return 0
	if [ "${sync_rc:-1}" -eq 0 ]; then
		fail_catalog_attempt "the sync ended before catalog generation completed"
	else
		fail_catalog_attempt "the sync ended before catalog generation completed (sync exit ${sync_rc:-1})"
	fi
}

# Read the tool's real table headings rather than assigning component or
# version names from the query that produced them. Component is fixed on the
# left of the table. Version, release date, size and type are fixed on the
# right, so a Full Name containing the delimiter is retained without shifting
# those verified fields.
catalog_rows() {
	awk -F'|' '
		function trim(text) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", text); return text }
		header == 0 {
			for (i = 1; i <= NF; i++) cell[i] = trim($i)
			if (NF == 7 && cell[1] == "ID" && cell[2] == "Component" &&
			    cell[3] == "Component Full Name" &&
			    cell[NF-3] == "Version" && cell[NF-2] == "Release Date" &&
			    cell[NF-1] == "Size" && cell[NF] == "Type") {
				header = NF
				name_column = 3
			}
			next
		}
		index($0, "|") == 0 { next }
		{
			id = trim($1)
			if (length(id) != 36 || id !~ /^[0-9A-Fa-f-]+$/ ||
			    substr(id,9,1) != "-" || substr(id,14,1) != "-" ||
			    substr(id,19,1) != "-" || substr(id,24,1) != "-") next
			hex = id
			gsub(/-/, "", hex)
			if (length(hex) != 32) next
			if (NF < header) { bad = 1; exit 4 }
			shift = NF - header
			version_column = header - 3 + shift
			component = trim($2)
			version = trim($version_column)
			date = trim($(version_column + 1))
			size = trim($(version_column + 2))
			type = trim($(version_column + 3))
			name = ""
			for (i = name_column; i < version_column; i++) {
				name = name (name == "" ? "" : " | ") trim($i)
			}
			if (component == "" || version == "" || type == "") { bad = 1; exit 4 }
			print id "\t" component "\t" name "\t" version "\t" date "\t" size "\t" type
		}
		END { if (header == 0) exit 3; if (bad) exit 4 }'
}

refresh_catalog() {
	local mode output rows rc=0 error="" updated tmp count previous
	local -a arguments=()
	catalog_workspace="$(mktemp -d "$STATE_DIR/catalog-build.XXXXXX")" || {
		catalog_workspace=""
		fail_catalog_attempt "catalog storage could not be prepared"
		return 0
	}
	for mode in install upgrade patch; do
		case "$mode" in
			install) arguments=("--vcf-version=$VCF_VERSION" "--sku=$SKU" --automated-install --type=INSTALL) ;;
			upgrade) arguments=("--vcf-version=$VCF_VERSION" "--sku=$SKU" --type=UPGRADE) ;;
			patch) arguments=("--vcf-version=$VCF_VERSION" "--sku=$SKU" --patches-only) ;;
		esac
		output="$catalog_workspace/$mode.out"
		CATALOG_QUERY_MODE="$mode" "$tool" binaries list "$ceip_opt" "$auth_opt" \
			"${arguments[@]}" > "$output" 2>&1 || rc=$?
		if [ "$rc" -ne 0 ]; then
			error="$mode inventory query failed with exit code $rc"
			break
		fi
		rows="$catalog_workspace/$mode.rows"
		if ! catalog_rows < "$output" > "$rows"; then
			error="$mode inventory returned an unreadable component table"
			break
		fi
		if ! jq -Rn \
			'[inputs | split("\t") | {id:.[0], component:.[1], name:.[2], version:.[3], date:.[4], size:.[5], type:.[6]}]' \
			< "$rows" > "$catalog_workspace/$mode.json"; then
			error="$mode inventory could not be encoded"
			break
		fi
	done
	if [ -n "$error" ]; then
		log "WARNING: catalog update failed: $error; keeping the previous successful catalog"
		fail_catalog_attempt "$error"
		clear_catalog_workspace
		return 0
	fi
	updated="$(now)"
	tmp="$(mktemp "$STATE_DIR/catalog.json.XXXXXX")" || {
		log "WARNING: catalog update failed: durable publish could not be prepared; keeping the previous successful catalog"
		fail_catalog_attempt "catalog storage could not be prepared"
		clear_catalog_workspace
		return 0
	}
	if ! jq -s --arg attempt "$catalog_attempt_id" --arg updated "$updated" \
		'{version:1, attemptId:$attempt, updatedAt:$updated,
		  items:([.[][]] | group_by([.id,.component,.version,.type]) | map(.[0]))}' \
		"$catalog_workspace/install.json" "$catalog_workspace/upgrade.json" \
		"$catalog_workspace/patch.json" > "$tmp"; then
		rm -f -- "$tmp"
		log "WARNING: catalog update failed during atomic publish; keeping the previous successful catalog"
		fail_catalog_attempt "catalog could not be published"
		clear_catalog_workspace
		return 0
	fi
	count="$(jq '.items | length' "$tmp" 2>/dev/null || true)"
	case "$count" in ''|*[!0-9]*) count=0 ;; esac
	previous="$(jq '.items | length' "$catalog_file" 2>/dev/null || true)"
	case "$previous" in ''|*[!0-9]*) previous=0 ;; esac
	if [ "$count" -eq 0 ] && [ "$previous" -gt 0 ]; then
		rm -f -- "$tmp"
		log "no components matched the current filter; keeping the previous catalog of $previous bundles"
		write_catalog_attempt empty "" "$updated"
	elif mv -- "$tmp" "$catalog_file"; then
		if [ "$count" -eq 0 ]; then
			log "no components matched the current filter, so the catalog lists nothing"
			write_catalog_attempt empty "" "$updated"
		else
			write_catalog_attempt success "" "$updated"
			log "catalog updated with $count available bundles from install, upgrade and patch inventories"
		fi
	else
		rm -f -- "$tmp"
		log "WARNING: catalog update failed during atomic publish; keeping the previous successful catalog"
		fail_catalog_attempt "catalog could not be published"
	fi
	clear_catalog_workspace
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

lock_file="$STATE_DIR/sync.lock"
# A scheduler that dispatched this run already holds the depot lock on fd 9
# and handed the locked descriptor down, so its own housekeeping cannot slip
# in ahead of the run it just launched (see dispatch_sync in entrypoint.sh).
# Any other invocation opens the lock file itself.
if [ -e /proc/self/fd/9 ] && [ /proc/self/fd/9 -ef "$lock_file" ]; then
	lock_source=inherited
elif { exec 9>"$lock_file"; } 2>/dev/null; then
	lock_source=opened
else
	open_error="$( { : >>"$lock_file"; } 2>&1 | sed 's/^[^:]*: line [0-9]*: //' || true)"
	open_error="${open_error#"$lock_file: "}"
	log "ERROR: could not open the depot lock $lock_file${open_error:+ ($open_error)}; refusing sync"
	diag "lock failed op=sync fd=9 pid=$$ ppid=$PPID reason=open"
	exit 1
fi
# util-linux flock exits 1 only when another descriptor holds the lock; any
# other status is a locking failure rather than a run in progress.
lock_rc=0
lock_error="$(flock -n 9 2>&1)" || lock_rc=$?
case "$lock_rc" in
	0)
		diag "lock acquired op=sync $(lock_identity 9) pid=$$ ppid=$PPID source=$lock_source"
		;;
	1)
		log "another sync already holds the depot lock, skipping this trigger"
		diag "lock contended op=sync $(lock_identity 9) pid=$$ ppid=$PPID source=$lock_source"
		exit 0
		;;
	*)
		log "ERROR: could not take the depot lock $lock_file (flock exit $lock_rc${lock_error:+: $lock_error}); refusing sync"
		diag "lock failed op=sync $(lock_identity 9) pid=$$ ppid=$PPID source=$lock_source reason=flock"
		exit 1
		;;
esac
sync_rc=0
diag_lock_release() {
	diag "lock released op=sync $(lock_identity 9) pid=$$ exit=$sync_rc"
}
begin_catalog_attempt
trap 'sync_rc=$?; finish_catalog_on_exit; diag_lock_release' EXIT

if [ -d "$comp_root" ]; then
	while IFS= read -r -d '' tree; do
		name="$(basename "$tree")"
		if [ -f "$tree/items.json" ] && [ -f "$tree/lib.json" ]; then
			record_tree_if_absent "$name" operator-provided true || exit 1
		else
			record_tree_if_absent "$name" unknown false || exit 1
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
	fail_catalog_attempt "VCF Download Tool is not installed"
	exit 1
fi
tool_lock="$VCFDT_TOOL_STORE/.update.lock"
if [ ! -e "$tool_lock" ]; then
	write_state '. + {running:false, currentTarget:null}'
	log "ERROR: the tool volume has no $tool_lock update lock; the tool store is incomplete"
	log "Re-upload the VCF Download Tool in the admin console to repair the tool volume."
	fail_catalog_attempt "the VCF Download Tool store is incomplete"
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
# The log writer must not inherit the run's lock descriptors, or it would keep
# the depot lock alive for the moment it outlives the run.
exec > >(exec 6<&- 7<&- 9>&-; exec tee -a "$run_log") 2>&1
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
trap 'sync_rc=$?; finish_catalog_on_exit; diag_lock_release; stop_log_publisher' EXIT

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
	fail_catalog_attempt "not armed: activation code missing"
	exit 0
fi

if [ "$CEIP" != "DISABLE" ] && [ "$CEIP" != "ENABLE" ]; then
	log "ERROR: CEIP must be explicitly set to ENABLE or DISABLE"
	fail_catalog_attempt "CEIP is not set to ENABLE or DISABLE"
	exit 2
fi

if [ ! -x "$tool" ]; then
	log "ERROR: VCF Download Tool is missing or not executable at $tool"
	exit 2
fi

write_state '. + {running:true, armed:true, currentTarget:null, startedAt:$t, targets:$targets}' \
	--arg t "$(now)" --arg targets "$SYNC_TARGETS"

finish_state() {
	finish_catalog_on_exit
	write_state '. + {running:false, currentTarget:null, finishedAt:$t}' --arg t "$(now)"
	[ -z "$fingerprint_dir" ] || rm -rf -- "$fingerprint_dir"
	diag_lock_release
	stop_log_publisher
}
trap 'sync_rc=$?; finish_state' EXIT
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
	local protected conflicts name count names
	if ! protected="$(protected_trees)"; then
		log "ERROR: could not read depot ownership; refusing sync"
		exit 1
	fi
	if [ -n "$protected" ]; then
		if ! trees_written_by "$label" "$@"; then
			log "protected trees exist and what $label would write is not proven, so the target is not run"
			last_status="$scope_status"
			overall_rc=$scope_rc
			log "<<< $label $last_status, continuing"
			return
		fi
		conflicts="$(LC_ALL=C comm -12 <(printf '%s\n' "$protected") <(printf '%s\n' "$written_trees"))"
		if [ -n "$conflicts" ]; then
			while IFS= read -r name; do
				log "PROD/COMP/$name is protected and $label writes it, skipping the target without changing it"
			done <<< "$conflicts"
			last_status="SKIPPED:PROTECTED"
			log "<<< $label $last_status"
			return
		fi
		if [ -n "$written_trees" ]; then
			count="$(printf '%s\n' "$written_trees" | grep -c .)"
			names="$(printf '%s\n' "$written_trees" | paste -sd, | sed 's/,/, /g')"
			log "$label writes $count trees under PROD/COMP ($names); none of them is protected"
		else
			log "$label lists nothing to download for its filter, so it writes no PROD/COMP tree"
		fi
		if ! snapshot_protected "$protected"; then
			log "ERROR: could not record the protected trees before running $label, so the target is not run"
			last_status="FAILED:UNVERIFIED"
			overall_rc=1
			log "<<< $label $last_status, continuing"
			return
		fi
	fi
	local target_rc=0
	"$@" || target_rc=$?
	if [ "$target_rc" -eq 0 ]; then
		last_status=OK
	else
		overall_rc=$target_rc
		last_status="FAILED:$target_rc"
	fi
	local verify_rc=0
	if [ -n "$protected" ]; then
		verify_protected_unchanged "$protected" "$label" || verify_rc=$?
	fi
	case "$verify_rc" in
		1)
			[ "$target_rc" -ne 0 ] || overall_rc=1
			last_status="FAILED:PROTECTED-CHANGED"
			;;
		2)
			if [ "$target_rc" -eq 0 ]; then
				overall_rc=1
				last_status="FAILED:UNVERIFIED"
			fi
			;;
	esac
	case "$last_status" in
		OK) log "<<< $label OK" ;;
		FAILED:UNVERIFIED) log "<<< $label $last_status, continuing" ;;
		FAILED:PROTECTED-CHANGED)
			if [ "$target_rc" -ne 0 ]; then
				log "<<< $label $last_status (tool rc=$target_rc), continuing"
			else
				log "<<< $label $last_status, continuing"
			fi
			;;
		*) log "<<< $label FAILED rc=$target_rc, continuing" ;;
	esac
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
	record_new_product_trees || exit 1
	if [ "$tool_backed_target" = true ] && [ "$last_status" = OK ]; then
		successful_tool_sync=true
	fi
	write_state '.lastRun[$target]={status:$status, finishedAt:$finished, toolVersion:(if $toolBacked then $toolVersion else "not applicable" end), toolReleaseId:(if $toolBacked then $toolReleaseId else "not applicable" end)}' \
		--arg target "$target" --arg status "$last_status" --arg finished "$(now)" \
		--arg toolVersion "$tool_version" --arg toolReleaseId "$tool_release_id" \
		--argjson toolBacked "$tool_backed_target"
done

# The run already owns the depot lock on fd 9 and the tool update lock on fd
# 7. Generate the catalog here without opening or flocking either file again.
# A catalog failure is reported separately and never changes the sync result.
refresh_catalog

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
