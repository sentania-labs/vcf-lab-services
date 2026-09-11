#!/bin/bash
set -euo pipefail

# STUB_VERSION lets a stub report a chosen version so a stub depot tree can
# carry several distinguishable tool archives (see make-stub-depot.sh).
output="${1:-vcf-download-tool-0.0.0-stub.tar.gz}"
stub_version="${STUB_VERSION:-0.0.0.0.20000000}"
work_dir="$(mktemp -d /tmp/vcf-services-stub.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT
mkdir -p "$work_dir/vcf-download-tool-stub/bin" \
	"$work_dir/vcf-download-tool-stub/conf/telemetry"

cat > "$work_dir/vcf-download-tool-stub/bin/vcf-download-tool" <<'STUB'
#!/bin/bash
set -euo pipefail

tool_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
printf '%s\n' 'written' \
	> "$tool_root/conf/telemetry/telemetry.flag"

state_dir="${HOME}/.local/share/vmware/vdt"
mkdir -p "$state_dir"
if [ ! -s "$state_dir/machine_id" ]; then
	cat /proc/sys/kernel/random/uuid > "$state_dir/machine_id"
fi

# Tests that need to know which subcommands ran name a file in STUB_CALL_LOG.
[ -z "${STUB_CALL_LOG:-}" ] || printf '%s %s\n' "${1:-}" "${2:-}" >> "$STUB_CALL_LOG"

if [ "${1:-}" = "--version" ]; then
	cat <<'VERSION'
*********Welcome to VCF Download Tool***********

Version: 0.0.0.0.20000000
0.0.0.0.20000000

Log file: /opt/vmware/vcfdt/log/vdt.log
VERSION
	exit 0
fi
if [ "${1:-}" = configuration ] && [ "${2:-}" = get ] && [ "${3:-}" = --machineId ]; then
	cat "$state_dir/machine_id"
	exit 0
fi
# The components a filter selects follow what the real tool listed on the
# lab depot (issue #47): the installer set has no ESX_HOST, upgrades and
# patches include ESX_HOST and the tool's own VCFDT archive. Tests override
# the set with STUB_LIST_COMPONENTS (space separated), fail the listing with
# STUB_FAIL_TARGET=list, or drop the table with STUB_LIST_NO_TABLE=1.
components_for_filter() {
	if [ -n "${STUB_LIST_COMPONENTS+set}" ]; then
		printf '%s\n' "$STUB_LIST_COMPONENTS"
		return
	fi
	case " $* " in
		*" --automated-install "*) echo "SDDC_MANAGER_VCF VCENTER NSX_T_MANAGER" ;;
		*" --patches-only "*) echo "ESX_HOST VCENTER NSX_T_MANAGER VCFDT" ;;
		*" --type=UPGRADE "*) echo "SDDC_MANAGER_VCF VCENTER ESX_HOST VCFDT" ;;
		*) echo "SDDC_MANAGER_VCF" ;;
	esac
}

if [ "${1:-}" = binaries ] && [ "${2:-}" = list ]; then
	[ "${STUB_FAIL_TARGET:-}" != list ] || exit 23
	printf '*********Welcome to VCF Download Tool***********\n\nVersion: 0.0.0.0.20000000\n'
	printf 'Validating depot credentials.\nDepot credentials are valid.\n'
	if [ "${STUB_LIST_NO_TABLE:-0}" = 1 ]; then
		echo "No binaries matched the given filter."
		exit 0
	fi
	# shellcheck disable=SC2046
	set -- $(components_for_filter "$@")
	printf 'ID                                   | Component | Component Full Name | Version | Release Date | Size | Type\n'
	printf -- '-----\n'
	index=0
	for component in "$@"; do
		index=$((index + 1))
		printf '%08x-0000-4000-8000-%012d | %s | Stub %s | 9.1.0.0.20000000 | 2026-01-01 | 1 KiB | UPGRADE\n' \
			"$index" "$index" "$component" "$component"
	done
	printf -- '-----\n%s elements\n' "$#"
	exit 0
fi

target=unknown
case "${1:-} ${2:-}" in
	"esx download"|"esx metadata") target=esx ;;
	"binaries download")
		case " $* " in
			*" --automated-install "*) target=install ;;
			*" --type=UPGRADE "*) target=upgrade ;;
			*" --patches-only "*) target=patches ;;
		esac
		;;
esac
depot=/depot
for argument in "$@"; do
	case "$argument" in --depot-store=*) depot="${argument#*=}" ;; esac
done
# A misbehaving tool for the protection tests: STUB_WRITE_TREES adds a file
# to each named tree and STUB_RETARGET_LINKS re-points each named tree's
# "current" link, both outside what the listing declared and before any
# STUB_FAIL_TARGET exit, so a failing tool can misbehave too.
for component in ${STUB_WRITE_TREES:-}; do
	mkdir -p "$depot/PROD/COMP/$component"
	printf 'unexpected write by %s\n' "$target" > "$depot/PROD/COMP/$component/unexpected.bin"
done
for component in ${STUB_RETARGET_LINKS:-}; do
	ln -sfn elsewhere "$depot/PROD/COMP/$component/current"
done
[ "${STUB_FAIL_TARGET:-}" != "$target" ] || exit 23
if [ "${STUB_SLEEP:-0}" != 0 ]; then sleep "$STUB_SLEEP"; fi
# A download writes exactly the trees its listing names, plus this stub's own
# marker tree. The ESX image library is a single-tree command.
written=""
if [ "$target" = esx ]; then
	written=ESX_HOST
elif [ "${1:-}" = binaries ]; then
	written="$(components_for_filter "$@")"
fi
for component in $written; do
	mkdir -p "$depot/PROD/COMP/$component"
	printf 'stub %s content for %s\n' "$component" "$target" > "$depot/PROD/COMP/$component/stub-$target.bin"
	if [ "$component" = ESX_HOST ]; then
		mkdir -p "$depot/PROD/COMP/ESX_HOST/patch-store"
		ln -sfn "$depot/PROD/COMP/ESX_HOST/patch-store" "$depot/umds-patch-store"
	fi
done
mkdir -p "$depot/STUB/$target"
printf 'stub content for %s\n' "$target" > "$depot/STUB/$target/20000000.bin"
echo "stub completed target $target"
STUB
sed -i "s/0\.0\.0\.0\.20000000/$stub_version/g" "$work_dir/vcf-download-tool-stub/bin/vcf-download-tool"
chmod 0755 "$work_dir/vcf-download-tool-stub/bin/vcf-download-tool"
cat > "$work_dir/vcf-download-tool-stub/conf/application-prod.properties" <<'PROPERTIES'
lcm.depot.adapter.host=dl.broadcom.com
lcm.access_token.broadcom.authorization.server.url=https://eapi.broadcom.com/vcf/generateToken
PROPERTIES
cat > "$work_dir/vcf-download-tool-stub/conf/application-prodv2.properties" <<'PROPERTIES'
lcm.depot.adapter.host=dl.broadcom.com
lcm.access_token.broadcom.authorization.server.url=https://eapi.broadcom.com/vcf/generateToken
PROPERTIES
tar -czf "$output" -C "$work_dir" vcf-download-tool-stub
echo "$output"
