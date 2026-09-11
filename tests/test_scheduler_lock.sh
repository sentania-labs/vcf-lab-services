#!/bin/bash
# Regression coverage for depot-lock coordination between the scheduler and
# the runs it launches. It drives the real scheduler (sync/entrypoint.sh) and
# the real sync.sh with a stub download tool, replacing only the Redis bus
# with a queue file. The scheduler's own housekeeping read of state.json is
# slowed by 50ms, exactly as in the reproduction where a scheduler that let
# housekeeping take the lock ahead of a run it had just launched made that
# run skip itself on every trial. With the lock handed to the run at launch,
# every trial runs, while genuinely concurrent syncs and versions refreshes
# stay excluded, a killed run releases the lock, and a lock that cannot be
# opened is reported as a failure rather than as a run in progress.
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work_dir="$(mktemp -d /tmp/vcf-services-scheduler-lock-test.XXXXXX)"
scheduler_pid=""
cleanup() {
	if [ -n "$scheduler_pid" ]; then
		kill "$scheduler_pid" 2>/dev/null || true
		wait "$scheduler_pid" 2>/dev/null || true
	fi
	pkill -9 -f "$work_dir/tool/bin/vcf-download-tool" 2>/dev/null || true
	rm -rf "$work_dir"
}
trap cleanup EXIT
# shellcheck disable=SC2154
trap 'status=$?; echo "FAIL: line $LINENO exited $status" >&2; [ ! -s "${scheduler_log:-}" ] || cat "$scheduler_log" >&2; exit "$status"' ERR

real_jq="$(command -v jq)"
stub_bin="$work_dir/bin"
control_dir="$work_dir/control"
mkdir -p "$stub_bin" "$control_dir" "$work_dir/config" "$work_dir/state" \
	"$work_dir/tool/bin" "$work_dir/depot"
export FAKE_QUEUE_FILE="$work_dir/queue"
export FAKE_SET_LOG="$work_dir/set.log"
touch "$FAKE_QUEUE_FILE" "$FAKE_SET_LOG"

cat > "$stub_bin/redis-cli" <<'STUB'
#!/bin/bash
args=("$@")
command_index=-1
for i in "${!args[@]}"; do
	case "${args[$i]}" in
		BRPOP|SET|PING|EXISTS) command_index=$i; break ;;
	esac
done
[ "$command_index" -ge 0 ] || exit 0
case "${args[$command_index]}" in
	PING)
		echo PONG
		;;
	EXISTS)
		echo 0
		;;
	BRPOP)
		if [ -s "$FAKE_QUEUE_FILE" ]; then
			echo "${args[$((command_index + 1))]}"
			head -n 1 "$FAKE_QUEUE_FILE"
			tail -n +2 "$FAKE_QUEUE_FILE" > "$FAKE_QUEUE_FILE.next"
			mv "$FAKE_QUEUE_FILE.next" "$FAKE_QUEUE_FILE"
		else
			sleep 1
		fi
		;;
	SET)
		cat > /dev/null
		echo "${args[$((command_index + 1))]}" >> "$FAKE_SET_LOG"
		echo OK
		;;
esac
STUB
chmod 0755 "$stub_bin/redis-cli"

# The reproduction's controlled variant: the scheduler's housekeeping read of
# state.json takes a little longer, so its lock is held long enough to be
# noticed by a run launched a moment earlier.
cat > "$stub_bin/jq" <<EOF
#!/bin/bash
if [ "\${1:-}" = -r ] && [ "\${2:-}" = .armed ]; then sleep 0.05; fi
exec "$real_jq" "\$@"
EOF
chmod 0755 "$stub_bin/jq"

cat > "$work_dir/tool/bin/vcf-download-tool" <<'STUB'
#!/bin/bash
control_dir="${STUB_CONTROL_DIR:?}"
if [ "${1:-}" = binaries ] && [ "${2:-}" = list ]; then
	echo "list $$" >> "$control_dir/tool-calls.log"
	sleep "$(cat "$control_dir/list-sleep" 2>/dev/null || echo 0)"
	echo "stub versions output"
	exit 0
fi
echo "download $$" >> "$control_dir/tool-calls.log"
sleep "$(cat "$control_dir/download-sleep" 2>/dev/null || echo 0)"
echo "stub completed"
STUB
chmod 0755 "$work_dir/tool/bin/vcf-download-tool"
touch "$work_dir/tool/.update.lock"
printf 'stub-code\n' > "$work_dir/activation-code.txt"
settings="$work_dir/config/settings.env"
write_settings() {
	local next
	next="$(mktemp "$work_dir/config/settings.env.XXXXXX")"
	printf 'CRON_SCHEDULE="%s"\nSYNC_DIAGNOSTICS="%s"\n' "$1" "$2" > "$next"
	mv "$next" "$settings"
}
write_settings '0 0 31 2 *' true
printf '%s' '{"running":false,"armed":false,"currentTarget":null,"lastRun":{}}' \
	> "$work_dir/state/state.json"

scheduler_log="$work_dir/scheduler.log"
tool_calls="$control_dir/tool-calls.log"
touch "$tool_calls"
PATH="$stub_bin:$PATH" \
SETTINGS_FILE="$settings" \
STATE_DIR="$work_dir/state" \
AUTH_FILE="$work_dir/activation-code.txt" \
TOOL_ROOT="$work_dir/tool" \
DEPOT_DIR="$work_dir/depot" \
SYNC_COMMAND="$project_dir/sync/sync.sh" \
REDIS_HOST=stub \
REDIS_PASSWORD_FILE=/dev/null \
POLL_SECONDS=1 \
STUB_CONTROL_DIR="$control_dir" \
bash "$project_dir/sync/entrypoint.sh" > "$scheduler_log" 2>&1 &
scheduler_pid=$!

completed='sync finished overall rc=0'
skipped='another sync or versions refresh already holds the depot lock, skipping this trigger'
admitted='diag: lock acquired op=sync fd=9'
enqueue() { printf '%s\n' "$1" >> "$FAKE_QUEUE_FILE"; }
# A negated command is exempt from errexit, so absence is asserted explicitly.
absent() {
	if grep -q -- "$1" "$2"; then
		echo "FAIL: found '$1' in $2" >&2
		exit 1
	fi
}
count() { grep -c -- "$1" "$scheduler_log" || true; }
wait_until() {
	local deadline=$((SECONDS + $2))
	until eval "$1"; do
		if [ "$SECONDS" -ge "$deadline" ]; then
			echo "FAIL: $3" >&2
			cat "$scheduler_log" >&2
			exit 1
		fi
		sleep 0.1
	done
}

wait_until "grep -q 'connected to the Redis job bus' '$scheduler_log'" 15 \
	"the scheduler did not start"

# Manual dispatch with housekeeping active: every requested run is admitted.
for trial in 1 2 3 4 5 6 7 8 9 10; do
	enqueue '{"kind":"sync","targets":["esx"]}'
	wait_until "[ \$(( \$(count '$completed') + \$(count '$skipped') )) -ge $trial ]" 20 \
		"trial $trial produced neither a completed run nor a skip"
done
[ "$(count "$completed")" -eq 10 ]
[ "$(count "$skipped")" -eq 0 ]
[ "$(grep -c '^download ' "$tool_calls")" -eq 10 ]
jq -e '.running == false and .armed == true and .lastRun.esx.status == "OK"' \
	"$work_dir/state/state.json" >/dev/null
# The lock the run holds is the one the scheduler took for it: same file, same
# process identity on both sides of the hand-off.
lock_inode="$(stat -c %i "$work_dir/state/sync.lock")"
launched="$(grep -o 'diag: sync launched pid=[0-9]*' "$scheduler_log" | head -n 1 | cut -d= -f2)"
grep -Eq "\[scheduler\] diag: lock acquired op=sync-dispatch fd=9 dev=[0-9a-f]+:[0-9a-f]+ ino=$lock_inode pid=$scheduler_pid handoff=fd9$" \
	"$scheduler_log"
grep -Eq "diag: sync launched pid=$launched ppid=$scheduler_pid targets=esx$" "$scheduler_log"
grep -Eq "\[scheduler\] diag: lock handed off op=sync-dispatch fd=9 pid=$scheduler_pid to=$launched$" \
	"$scheduler_log"
grep -Eq "\[sync [^]]*\] diag: lock acquired op=sync fd=9 dev=[0-9a-f]+:[0-9a-f]+ ino=$lock_inode pid=$launched ppid=$scheduler_pid source=inherited$" \
	"$scheduler_log"
grep -Eq "\[sync [^]]*\] diag: lock released op=sync fd=9 dev=[0-9a-f]+:[0-9a-f]+ ino=$lock_inode pid=$launched exit=0$" \
	"$scheduler_log"
echo "dispatch under active housekeeping tests passed: $(count "$completed") of 10 requested runs admitted, $(count "$skipped") skipped"

# A versions refresh requested while housekeeping is active runs every time
# as well, instead of being refused by the loop that launched it.
for trial in 1 2 3 4 5; do
	enqueue '{"kind":"versions"}'
	wait_until "[ \$(grep -c '^list ' '$tool_calls' || true) -ge $trial ] || grep -q 'versions refresh skipped' '$scheduler_log'" 20 \
		"versions trial $trial neither ran nor was refused"
done
[ "$(grep -c '^list ' "$tool_calls")" -eq 5 ]
absent 'versions refresh skipped' "$scheduler_log"
wait_until "[ \$(count 'diag: lock released op=versions-refresh fd=8') -ge 5 ]" 10 \
	"a versions refresh did not release the lock"
grep -Eq "\[scheduler\] diag: lock acquired op=versions-refresh fd=8 dev=[0-9a-f]+:[0-9a-f]+ ino=$lock_inode pid=$scheduler_pid$" \
	"$scheduler_log"
grep -Eq "\[scheduler\] diag: lock handed off op=versions-refresh fd=8 pid=$scheduler_pid to=[0-9]+$" \
	"$scheduler_log"
echo "versions refresh under active housekeeping tests passed: $(grep -c '^list ' "$tool_calls") of 5 requested refreshes ran"

# The scheduler polls its queue about every two seconds, so each held window
# below is long enough for a request made at its start to be picked up inside it.
# A second sync requested while one is running is excluded and says so, and
# housekeeping reports the same contention instead of touching state.
echo 5 > "$control_dir/download-sleep"
enqueue '{"kind":"sync","targets":["esx"]}'
wait_until "[ \$(count '$admitted') -ge 11 ]" 10 "the long run was not admitted"
enqueue '{"kind":"sync","targets":["patches"]}'
wait_until "[ \$(count '$skipped') -ge 1 ]" 10 "the concurrent run was not refused"
wait_until "[ \$(count '$completed') -ge 11 ]" 15 "the long run did not finish"
[ "$(count "$skipped")" -eq 1 ]
[ "$(grep -c '^download ' "$tool_calls")" -eq 11 ]
grep -q 'diag: lock contended op=sync-dispatch fd=9 .*; the run reports it' "$scheduler_log"
grep -Eq '\[sync [^]]*\] diag: lock contended op=sync fd=9 .* source=inherited$' "$scheduler_log"
grep -q '\[scheduler\] diag: lock contended op=armed-refresh fd=8' "$scheduler_log"
absent 'ERROR: could not' "$scheduler_log"
echo "concurrent sync exclusion tests passed"

# A versions refresh during a run is skipped without calling the tool, and a
# run requested during a versions refresh is refused while the refresh finishes.
enqueue '{"kind":"sync","targets":["esx"]}'
wait_until "[ \$(count '$admitted') -ge 12 ]" 10 "the second long run was not admitted"
enqueue '{"kind":"versions"}'
wait_until "grep -q 'versions refresh skipped: a sync or refresh already holds the depot lock' '$scheduler_log'" 10 \
	"the versions refresh was not refused during a run"
wait_until "[ \$(count '$completed') -ge 12 ]" 15 "the second long run did not finish"
[ "$(grep -c '^list ' "$tool_calls")" -eq 5 ]
echo 0 > "$control_dir/download-sleep"
echo 5 > "$control_dir/list-sleep"
enqueue '{"kind":"versions"}'
wait_until "grep -q '^list ' '$tool_calls'" 10 "the versions refresh did not start"
enqueue '{"kind":"sync","targets":["esx"]}'
wait_until "[ \$(count '$skipped') -ge 2 ]" 10 "the run was not refused during a versions refresh"
wait_until "[ \$(count 'diag: lock released op=versions-refresh fd=8') -ge 6 ]" 15 \
	"the versions refresh did not finish"
echo 0 > "$control_dir/list-sleep"
[ "$(count "$completed")" -eq 12 ]
[ "$(grep -c '^list ' "$tool_calls")" -eq 6 ]
grep -q 'vcf-services:sync:versions' "$FAKE_SET_LOG"
echo "versions refresh exclusion tests passed"

# A run killed outright releases the lock once its download stops, and the
# next request is admitted; nothing has to be removed to recover.
echo 4 > "$control_dir/download-sleep"
enqueue '{"kind":"sync","targets":["esx"]}'
wait_until "[ \$(count '$admitted') -ge 13 ]" 10 "the run to be killed was not admitted"
run_pid="$(grep -o 'diag: sync launched pid=[0-9]*' "$scheduler_log" | tail -n 1 | cut -d= -f2)"
# The run records its identity just after taking the lock; wait for its own.
wait_until "[ \"\$(cut -d- -f3 '$work_dir/state/settings-snapshot.run' 2>/dev/null)\" = '$run_pid' ]" 5 \
	"the run did not record its identity"
kill -9 "$run_pid"
wait_until "flock -n '$work_dir/state/sync.lock' true" 10 \
	"the depot lock stayed held after the run was killed"
echo 0 > "$control_dir/download-sleep"
enqueue '{"kind":"sync","targets":["esx"]}'
wait_until "[ \$(count '$completed') -ge 13 ]" 10 "no run was admitted after the killed run"
[ "$(count "$skipped")" -eq 2 ]
echo "killed run lock release tests passed"

# Turning diagnostics off in the console's settings file silences both the
# scheduler and the runs it launches, without a restart.
write_settings '0 0 31 2 *' false
sleep 3
before="$(wc -l < "$scheduler_log")"
enqueue '{"kind":"sync","targets":["esx"]}'
wait_until "[ \$(count '$completed') -ge 14 ]" 10 "the run after switching diagnostics off did not finish"
[ "$(tail -n "+$((before + 1))" "$scheduler_log" | grep -c 'diag:' || true)" -eq 0 ]
echo "diagnostics toggle tests passed"

# A scheduled run takes the same hand-off as a requested one.
write_settings '* * * * *' true
wait_until "grep -q 'matched, dispatching sync' '$scheduler_log'" 10 "the schedule did not dispatch"
wait_until "[ \$(count '$completed') -ge 15 ]" 10 "the scheduled run did not finish"
write_settings '0 0 31 2 *' true
grep -Eq 'diag: sync launched pid=[0-9]+ ppid=[0-9]+ targets=configured$' "$scheduler_log"
[ "$(count "$skipped")" -eq 2 ]
echo "scheduled dispatch hand-off tests passed"

# A lock that cannot be opened is a reported failure, not a run in progress,
# for housekeeping (reported once per reason) and for a versions refresh.
broken_state="$work_dir/broken-state"
mkdir -p "$broken_state/sync.lock"
broken_set_log="$work_dir/broken-set.log"
touch "$broken_set_log"
(
	export PATH="$stub_bin:$PATH"
	export FAKE_SET_LOG="$broken_set_log"
	export SETTINGS_FILE="$settings"
	export STATE_DIR="$broken_state"
	export AUTH_FILE="$work_dir/activation-code.txt"
	export TOOL_ROOT="$work_dir/tool"
	export REDIS_HOST=stub
	export REDIS_PASSWORD_FILE=/dev/null
	# shellcheck source=/dev/null
	source "$project_dir/sync/entrypoint.sh"
	refresh_armed_state
	refresh_armed_state
	refresh_versions
	echo "scheduler-functions-survived"
) > "$work_dir/broken.log" 2>&1
grep -q 'scheduler-functions-survived' "$work_dir/broken.log"
[ "$(grep -c "ERROR: armed-state refresh could not take the depot lock: could not open $broken_state/sync.lock (Is a directory)" "$work_dir/broken.log")" -eq 1 ]
grep -q "ERROR: versions refresh could not take the depot lock: could not open $broken_state/sync.lock (Is a directory)" \
	"$work_dir/broken.log"
absent 'already holds the depot lock' "$work_dir/broken.log"
grep -q 'vcf-services:sync:versions' "$broken_set_log"
[ -d "$broken_state/sync.lock" ]
echo "lock failure reporting tests passed"

echo "scheduler lock coordination tests passed"
