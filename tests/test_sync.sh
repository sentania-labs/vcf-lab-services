#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work_dir="$(mktemp -d /tmp/vcf-services-sync-test.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT

"$project_dir/tests/make-stub-vcfdt.sh" "$work_dir/vcf-download-tool-0.0.0-stub.tar.gz" >/dev/null
mkdir -p "$work_dir/tool" "$work_dir/depot" "$work_dir/state" "$work_dir/secrets"
tar -xzf "$work_dir/vcf-download-tool-0.0.0-stub.tar.gz" \
	-C "$work_dir/tool" --strip-components=1
touch "$work_dir/tool/.update.lock"
printf '%s\n' '{"releaseId":"base-stub","version":"0.0.0-stub","installedAt":"2026-09-08T00:00:00Z"}' \
	> "$work_dir/tool/.vcf-services.json"

run_sync() {
	SETTINGS_FILE="$work_dir/missing-settings.env" \
	DEPOT_DIR="$work_dir/depot" \
	STATE_DIR="$work_dir/state" \
	AUTH_FILE="$work_dir/secrets/activation-code.txt" \
	TOOL_ROOT="$work_dir/tool" \
	LOG_RETENTION=3 \
	"$project_dir/sync/sync.sh" "$@"
}

run_sync esx > "$work_dir/dormant.log"
grep -q '^\[sync .*\] not armed: activation code missing$' "$work_dir/dormant.log"
jq -e '.running == false and .armed == false' "$work_dir/state/state.json" >/dev/null

printf 'stub-activation-code\n' > "$work_dir/secrets/activation-code.txt"
STUB_SLEEP=1 run_sync esx > "$work_dir/locked-primary.log" &
primary_pid=$!
sleep 0.1
run_sync patches > "$work_dir/locked-secondary.log"
wait "$primary_pid"
grep -q 'another sync is already running' "$work_dir/locked-secondary.log"
grep -qx 'written' "$work_dir/tool/conf/telemetry/telemetry.flag"

set +e
STUB_FAIL_TARGET=install run_sync esx install patches > "$work_dir/sequential.log"
sync_rc=$?
set -e
[ "$sync_rc" -eq 23 ]
jq -e '.running == false and .armed == true and .lastRun.esx.status == "OK"
  and .lastRun.install.status == "FAILED:23" and .lastRun.patches.status == "OK"
  and .lastRun.esx.toolVersion == "0.0.0-stub"
  and .lastRun.install.toolVersion == "0.0.0-stub"' \
	"$work_dir/state/state.json" >/dev/null
test -f "$work_dir/depot/STUB/patches/20000000.bin"

for _run in 1 2 3 4 5; do run_sync esx >/dev/null; done
log_count="$(find "$work_dir/state" -maxdepth 1 -type f -name 'run-*.log' | wc -l)"
[ "$log_count" -eq 3 ]
test -L "$work_dir/state/latest.log"

# settings.env is read after the run lock is taken, and a key the console left
# blank still falls back to its default.
printf 'SYNC_TARGETS="patches"\nCEIP=""\nLOG_RETENTION=""\n' > "$work_dir/settings.env"
SETTINGS_FILE="$work_dir/settings.env" \
DEPOT_DIR="$work_dir/depot" \
STATE_DIR="$work_dir/state" \
AUTH_FILE="$work_dir/secrets/activation-code.txt" \
TOOL_ROOT="$work_dir/tool" \
"$project_dir/sync/sync.sh" > "$work_dir/from-settings.log"
grep -q '>>> vcf-patches' "$work_dir/from-settings.log"
[ "$(grep -c '>>> ' "$work_dir/from-settings.log")" -eq 1 ]
grep -q 'sync finished overall rc=0' "$work_dir/from-settings.log"

# A run holds the settings snapshot lock from before it reads settings.env
# until it exits, which is how the console tells a save that applies to this
# run from one that applies to the next.
snapshot_lock="$work_dir/state/settings-snapshot.lock"
STUB_SLEEP=2 run_sync esx > "$work_dir/snapshot-lock.log" &
snapshot_pid=$!
sleep 0.5
test -e "$snapshot_lock"
if flock -n -s "$snapshot_lock" true 2>/dev/null; then
	echo "FAIL: the running sync did not hold $snapshot_lock" >&2
	exit 1
fi
wait "$snapshot_pid"
flock -n -s "$snapshot_lock" true

stub_bin="$work_dir/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/redis-cli" <<'STUB'
#!/bin/bash
for argument in "$@"; do
	if [ "$argument" = SET ]; then
		cat > /dev/null
		break
	fi
done
echo OK
STUB
chmod 0755 "$stub_bin/redis-cli"

SETTINGS_FILE="$work_dir/missing-settings.env" \
DEPOT_DIR="$work_dir/depot" \
STATE_DIR="$work_dir/state" \
AUTH_FILE="$work_dir/secrets/activation-code.txt" \
TOOL_ROOT="$work_dir/tool" \
LOG_RETENTION=3 \
REDIS_HOST=stub \
REDIS_PASSWORD_FILE=/dev/null \
PATH="$stub_bin:$PATH" \
STUB_SLEEP=2 \
bash "$project_dir/sync/sync.sh" esx > "$work_dir/kill9.log" 2>&1 &
victim_pid=$!
sleep 1
kill -9 "$victim_pid"
sleep 3.5
run_sync patches > "$work_dir/after-kill9.log"
! grep -q 'another sync is already running' "$work_dir/after-kill9.log"
grep -q 'sync finished overall rc=0' "$work_dir/after-kill9.log"

mv "$work_dir/tool/.update.lock" "$work_dir/tool/update.lock.saved"
set +e
run_sync esx > "$work_dir/missing-lock.log" 2>&1
missing_lock_rc=$?
set -e
[ "$missing_lock_rc" -eq 1 ]
grep -q 'Re-upload the VCF Download Tool in the admin console' "$work_dir/missing-lock.log"
jq -e '.running == false' "$work_dir/state/state.json" >/dev/null
mv "$work_dir/tool/update.lock.saved" "$work_dir/tool/.update.lock"

# A replacement keeps one prior release through failed runs, then a fully
# successful run records its producing version and removes the retained copy.
tool_store="$work_dir/tool-store"
mkdir -p "$tool_store/releases/current-release" "$tool_store/releases/previous-release" \
	"$work_dir/promotion-state"
cp -a "$work_dir/tool/." "$tool_store/releases/current-release/"
cp -a "$work_dir/tool/." "$tool_store/releases/previous-release/"
printf '%s\n' '{"releaseId":"current-release","version":"0.0.1-stub","installedAt":"2026-09-08T01:00:00Z"}' \
	> "$tool_store/releases/current-release/.vcf-services.json"
printf '%s\n' '{"releaseId":"previous-release","version":"0.0.0-stub","installedAt":"2026-09-08T00:00:00Z"}' \
	> "$tool_store/releases/previous-release/.vcf-services.json"
ln -s releases/current-release "$tool_store/current"
ln -s releases/previous-release "$tool_store/previous"
touch "$tool_store/.update.lock"

run_promoted_sync() {
	SETTINGS_FILE="$work_dir/missing-settings.env" \
	DEPOT_DIR="$work_dir/depot" \
	STATE_DIR="$work_dir/promotion-state" \
	AUTH_FILE="$work_dir/secrets/activation-code.txt" \
	TOOL_ROOT="$tool_store/current" \
	VCFDT_TOOL_STORE="$tool_store" \
	LOG_RETENTION=3 \
	"$project_dir/sync/sync.sh" "$@"
}

set +e
STUB_FAIL_TARGET=patches run_promoted_sync patches > "$work_dir/promotion-failed.log"
promotion_rc=$?
set -e
[ "$promotion_rc" -eq 23 ]
test -L "$tool_store/previous"
test -d "$tool_store/releases/previous-release"

run_promoted_sync patches > "$work_dir/promotion-success.log"
test ! -e "$tool_store/previous"
test ! -e "$tool_store/releases/previous-release"
test -d "$tool_store/releases/current-release"
jq -e '.lastRun.patches.toolVersion == "0.0.1-stub"
  and .lastRun.patches.toolReleaseId == "current-release"
  and (has("depotContentToolVersion") | not)
  and (has("depotContentToolReleaseId") | not)' \
	"$work_dir/promotion-state/state.json" >/dev/null

# A successful target must have used the installed download tool before the
# retained release can be promoted away. VKR is handled by a separate helper.
grep -q 'tool_backed_target=false' "$project_dir/sync/sync.sh"
grep -q '\[ "$tool_backed_target" = true \].*\[ "$last_status" = OK \]' \
	"$project_dir/sync/sync.sh"
grep -q '\[ "$overall_rc" -eq 0 \].*\[ "$successful_tool_sync" = true \]' \
	"$project_dir/sync/sync.sh"

echo "sync behavior tests passed"
