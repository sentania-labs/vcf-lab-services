#!/bin/bash
# Runs the sync script shipped inside a built sync image, with that image's
# own jq, against a stub tool and a representative depot-ownership manifest.
# Debian bookworm ships jq 1.6, which reserves "label" as a keyword and refused
# to compile the ownership query that the host's jq 1.7 accepts, so the
# host-side shell tests could not see that failure. The protected tree must be
# left alone, the run must finish, and once the operator unprotects the tree
# the target must run.
set -euo pipefail

image="${1:?usage: test_sync_image.sh IMAGE}"
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work_dir="$(mktemp -d /tmp/vcf-services-sync-image-test.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT
# A negated command is exempt from errexit, so absence is asserted explicitly.
absent() {
	if grep -q -- "$1" "$2"; then
		echo "FAIL: found '$1' in $2" >&2
		exit 1
	fi
}

"$project_dir/tests/make-stub-vcfdt.sh" "$work_dir/vcf-download-tool-0.0.0-stub.tar.gz" >/dev/null
mkdir -p "$work_dir/tool" "$work_dir/state" "$work_dir/secrets" \
	"$work_dir/depot/PROD/COMP/ESX_HOST"
tar -xzf "$work_dir/vcf-download-tool-0.0.0-stub.tar.gz" \
	-C "$work_dir/tool" --strip-components=1
touch "$work_dir/tool/.update.lock"
printf '[]\n' > "$work_dir/depot/PROD/COMP/ESX_HOST/items.json"
printf '{}\n' > "$work_dir/depot/PROD/COMP/ESX_HOST/lib.json"
printf 'operator content\n' > "$work_dir/depot/PROD/COMP/ESX_HOST/operator.bin"
printf 'stub-activation-code\n' > "$work_dir/secrets/activation-code.txt"
printf '%s\n' '{"version":1,"trees":{"ESX_HOST":{"ownership":"operator-provided","protected":true}}}' \
	> "$work_dir/state/depot-ownership.json"

image_jq="$(docker run --rm --entrypoint jq "$image" --version)"
run_shipped_sync() {
	local log="$1"
	shift
	local rc=0
	docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
		-e SETTINGS_FILE=/nonexistent/settings.env \
		-v "$work_dir/tool:/opt/vcfdt" \
		-v "$work_dir/depot:/depot" \
		-v "$work_dir/state:/state" \
		-v "$work_dir/secrets:/etc/vcf-services/secrets:ro" \
		--entrypoint /usr/local/bin/sync.sh "$image" "$@" > "$log" 2>&1 || rc=$?
	cat "$log"
	if [ "$rc" -ne 0 ]; then
		echo "FAIL: the shipped sync exited $rc on $image_jq" >&2
		exit 1
	fi
	absent 'syntax error' "$log"
	absent 'could not read depot ownership' "$log"
	grep -q 'sync finished overall rc=0' "$log"
}

# A protected operator tree keeps every tool-backed target away from the depot.
run_shipped_sync "$work_dir/protected.log" esx install
grep -q 'PROD/COMP/ESX_HOST is protected, skipping the target without changing it' "$work_dir/protected.log"
grep -q '<<< esx-image-library SKIPPED:PROTECTED' "$work_dir/protected.log"
grep -q '<<< vcf-install SKIPPED:PROTECTED' "$work_dir/protected.log"
grep -qx 'operator content' "$work_dir/depot/PROD/COMP/ESX_HOST/operator.bin"
[ ! -e "$work_dir/depot/STUB" ]
jq -e '.version == 1 and .trees.ESX_HOST == {ownership:"operator-provided", protected:true}' \
	"$work_dir/state/depot-ownership.json" >/dev/null
jq -e '.running == false and .lastRun.esx.status == "SKIPPED:PROTECTED"
  and .lastRun.install.status == "SKIPPED:PROTECTED"' "$work_dir/state/state.json" >/dev/null

# Once the operator unprotects the tree, the same query lets the target run.
printf '%s\n' '{"version":1,"trees":{"ESX_HOST":{"ownership":"operator-provided","protected":false}}}' \
	> "$work_dir/state/depot-ownership.json"
run_shipped_sync "$work_dir/unprotected.log" install
grep -q '<<< vcf-install OK' "$work_dir/unprotected.log"
test -f "$work_dir/depot/STUB/install/20000000.bin"
grep -qx 'operator content' "$work_dir/depot/PROD/COMP/ESX_HOST/operator.bin"
jq -e '.trees.ESX_HOST == {ownership:"operator-provided", protected:false}' \
	"$work_dir/state/depot-ownership.json" >/dev/null
jq -e '.lastRun.install.status == "OK"' "$work_dir/state/state.json" >/dev/null
echo "sync image ownership tests passed on $image ($image_jq)"
