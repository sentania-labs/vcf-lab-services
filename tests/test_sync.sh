#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work_dir="$(mktemp -d /tmp/vcf-services-sync-test.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT

"$project_dir/tests/make-stub-vcfdt.sh" "$work_dir/vcf-download-tool-0.0.0-stub.tar.gz" >/dev/null
mkdir -p "$work_dir/tool" "$work_dir/depot" "$work_dir/state" "$work_dir/secrets"
tar -xzf "$work_dir/vcf-download-tool-0.0.0-stub.tar.gz" \
	-C "$work_dir/tool" --strip-components=1

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

set +e
STUB_FAIL_TARGET=install run_sync esx install patches > "$work_dir/sequential.log"
sync_rc=$?
set -e
[ "$sync_rc" -eq 23 ]
jq -e '.running == false and .armed == true and .lastRun.esx.status == "OK"
  and .lastRun.install.status == "FAILED:23" and .lastRun.patches.status == "OK"' \
	"$work_dir/state/state.json" >/dev/null
test -f "$work_dir/depot/STUB/patches/20000000.bin"

for _run in 1 2 3 4 5; do run_sync esx >/dev/null; done
log_count="$(find "$work_dir/state" -maxdepth 1 -type f -name 'run-*.log' | wc -l)"
[ "$log_count" -eq 3 ]
test -L "$work_dir/state/latest.log"

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

echo "sync behavior tests passed"
