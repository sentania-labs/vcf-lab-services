#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work_dir="$(mktemp -d /tmp/vcf-services-scheduler-test.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT

# shellcheck source=/dev/null
source "$project_dir/sync/entrypoint.sh"

cron_matches "0 3 * * 0" 0 3 15 6 0
! cron_matches "0 3 * * 0" 0 3 15 6 1
! cron_matches "0 3 * * 0" 1 3 15 6 0
cron_matches "*/15 * * * *" 30 12 1 1 3
! cron_matches "*/15 * * * *" 31 12 1 1 3
cron_matches "0 3 * * 7" 0 3 1 1 0
cron_matches "30 4 1 * *" 30 4 1 9 5
! cron_matches "30 4 2 * *" 30 4 1 9 5
cron_matches "0 0 1 * 1" 0 0 1 5 3
cron_matches "5-10 * * * *" 7 0 1 1 1
! cron_matches "5-10 * * * *" 11 0 1 1 1
! cron_matches "not a cron" 0 0 1 1 1
! cron_matches "0 3 * *" 0 3 1 1 1
echo "cron matcher tests passed"

stub_bin="$work_dir/bin"
mkdir -p "$stub_bin"
export FAKE_QUEUE_FILE="$work_dir/queue"
export FAKE_SET_LOG="$work_dir/set.log"
touch "$FAKE_QUEUE_FILE" "$FAKE_SET_LOG"

cat > "$stub_bin/redis-cli" <<'STUB'
#!/bin/bash
args=("$@")
command_index=-1
for i in "${!args[@]}"; do
	case "${args[$i]}" in
		BRPOP|SET|PING) command_index=$i; break ;;
	esac
done
[ "$command_index" -ge 0 ] || exit 0
case "${args[$command_index]}" in
	PING)
		echo PONG
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

dispatch_log="$work_dir/dispatch.log"
cat > "$stub_bin/fake-sync.sh" <<EOF
#!/bin/bash
echo "dispatch:\$*" >> "$dispatch_log"
EOF
chmod 0755 "$stub_bin/fake-sync.sh"

mkdir -p "$work_dir/config" "$work_dir/state" "$work_dir/tool/bin"
settings="$work_dir/config/settings.env"
printf 'CRON_SCHEDULE="0 0 31 2 *"\n' > "$settings"
cat > "$work_dir/tool/bin/vcf-download-tool" <<'EOF'
#!/bin/bash
echo "stub versions output"
EOF
chmod 0755 "$work_dir/tool/bin/vcf-download-tool"
printf 'stub-code\n' > "$work_dir/activation-code.txt"

printf '%s\n' '{"kind":"sync","targets":["patches","bogus"]}' > "$FAKE_QUEUE_FILE"
printf '%s\n' '{"kind":"versions"}' >> "$FAKE_QUEUE_FILE"

PATH="$stub_bin:$PATH" \
SETTINGS_FILE="$settings" \
STATE_DIR="$work_dir/state" \
AUTH_FILE="$work_dir/activation-code.txt" \
TOOL_ROOT="$work_dir/tool" \
SYNC_COMMAND="$stub_bin/fake-sync.sh" \
REDIS_HOST=stub \
POLL_SECONDS=1 \
timeout 20 bash "$project_dir/sync/entrypoint.sh" > "$work_dir/scheduler.log" 2>&1 &
scheduler_pid=$!

sleep 4
grep -q 'vcf-services:sync:status' "$FAKE_SET_LOG"
grep -q '^dispatch:patches$' "$dispatch_log"
! grep -q bogus "$dispatch_log"
grep -q 'vcf-services:sync:versions' "$FAKE_SET_LOG"
! grep -q '^dispatch:$' "$dispatch_log"
jq -e '.running == false' "$work_dir/state/state.json" >/dev/null

minute_before="$(date +%Y%m%d%H%M)"
settings_next="$(mktemp "$work_dir/config/settings.env.XXXXXX")"
printf 'CRON_SCHEDULE="* * * * *"\n' > "$settings_next"
mv "$settings_next" "$settings"
sleep 4
minute_after="$(date +%Y%m%d%H%M)"

kill "$scheduler_pid" 2>/dev/null || true
wait "$scheduler_pid" 2>/dev/null || true

scheduled_count="$(grep -c '^dispatch:$' "$dispatch_log")"
if [ "$minute_before" = "$minute_after" ]; then
	[ "$scheduled_count" -eq 1 ]
else
	[ "$scheduled_count" -ge 1 ] && [ "$scheduled_count" -le 2 ]
fi

echo "scheduler behavior tests passed"
