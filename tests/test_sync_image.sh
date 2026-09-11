#!/bin/bash
# Runs the sync script shipped inside a built sync image, with that image's
# own jq, against a stub tool and a representative depot-ownership manifest.
# Debian bookworm ships jq 1.6, which reserves "label" as a keyword and refused
# to compile the ownership query that the host's jq 1.7 accepts, so the
# host-side shell tests could not see that failure; its awk is mawk, which
# reads the tool's component table here. The protected tree must be left
# alone, targets that do not write it must still run, targets that the tool
# says would write it must skip, and once the operator unprotects the tree
# those targets must run.
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

# With ESX_HOST protected, the ESX image library skips, install runs because
# the tool's listing for it names no ESX_HOST, and patches skips because that
# listing does. The protected tree is byte and metadata identical afterwards.
before="$(find "$work_dir/depot/PROD/COMP/ESX_HOST" -printf '%y %m %s %T@ %i %p -> %l\n' | sort)"
run_shipped_sync "$work_dir/protected.log" esx install patches
grep -q 'PROD/COMP/ESX_HOST is protected and esx-image-library writes it, skipping the target without changing it' "$work_dir/protected.log"
grep -q '<<< esx-image-library SKIPPED:PROTECTED' "$work_dir/protected.log"
grep -q 'vcf-install writes 3 trees under PROD/COMP (NSX_T_MANAGER, SDDC_MANAGER_VCF, VCENTER); none of them is protected' "$work_dir/protected.log"
grep -q '<<< vcf-install OK' "$work_dir/protected.log"
grep -q 'PROD/COMP/ESX_HOST is protected and vcf-patches writes it, skipping the target without changing it' "$work_dir/protected.log"
grep -q '<<< vcf-patches SKIPPED:PROTECTED' "$work_dir/protected.log"
absent 'UNVERIFIED' "$work_dir/protected.log"
grep -qx 'operator content' "$work_dir/depot/PROD/COMP/ESX_HOST/operator.bin"
after="$(find "$work_dir/depot/PROD/COMP/ESX_HOST" -printf '%y %m %s %T@ %i %p -> %l\n' | sort)"
[ "$before" = "$after" ]
test -f "$work_dir/depot/STUB/install/20000000.bin"
test -f "$work_dir/depot/PROD/COMP/VCENTER/stub-install.bin"
[ ! -e "$work_dir/depot/STUB/esx" ]
[ ! -e "$work_dir/depot/STUB/patches" ]
jq -e '.version == 1 and .trees.ESX_HOST == {ownership:"operator-provided", protected:true}
  and .trees.VCENTER == {ownership:"product-managed", protected:false}' \
	"$work_dir/state/depot-ownership.json" >/dev/null
jq -e '.running == false and .lastRun.esx.status == "SKIPPED:PROTECTED"
  and .lastRun.install.status == "OK"
  and .lastRun.patches.status == "SKIPPED:PROTECTED"' "$work_dir/state/state.json" >/dev/null

# Once the operator unprotects the tree, the same targets run.
printf '%s\n' '{"version":1,"trees":{"ESX_HOST":{"ownership":"operator-provided","protected":false}}}' \
	> "$work_dir/state/depot-ownership.json"
run_shipped_sync "$work_dir/unprotected.log" esx patches
grep -q '<<< esx-image-library OK' "$work_dir/unprotected.log"
grep -q '<<< vcf-patches OK' "$work_dir/unprotected.log"
test -f "$work_dir/depot/STUB/patches/20000000.bin"
test -f "$work_dir/depot/PROD/COMP/ESX_HOST/stub-patches.bin"
grep -qx 'operator content' "$work_dir/depot/PROD/COMP/ESX_HOST/operator.bin"
jq -e '.trees.ESX_HOST == {ownership:"operator-provided", protected:false}' \
	"$work_dir/state/depot-ownership.json" >/dev/null
jq -e '.lastRun.esx.status == "OK" and .lastRun.patches.status == "OK"' "$work_dir/state/state.json" >/dev/null
echo "sync image ownership tests passed on $image ($image_jq)"
