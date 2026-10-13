#!/bin/bash
set -euo pipefail

# STUB_VERSION lets a stub report a chosen version so a stub depot tree can
# carry several distinguishable tool archives (see make-stub-depot.sh).
output="${1:-vcf-download-tool-0.0.0-stub.tar.gz}"
stub_version="${STUB_VERSION:-9.1.1}"
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

# Java system properties arrive through JAVA_TOOL_OPTIONS. Durable identity
# and every other home-relative path resolve from user.home; only the listing
# stage resolves from lcm.bundle.download.root.dir, which the shipped tool
# configuration defaults to ${user.home}.
java_home="$HOME"
listing_root=""
for option in ${JAVA_TOOL_OPTIONS:-}; do
	case "$option" in
		-Duser.home=*) java_home="${option#*=}" ;;
		-Dlcm.bundle.download.root.dir=*) listing_root="${option#*=}" ;;
	esac
done
: "${listing_root:=$java_home}"

state_dir="$java_home/.local/share/vmware/vdt"
mkdir -p "$state_dir"
if [ ! -s "$state_dir/machine_id" ]; then
	cat /proc/sys/kernel/random/uuid > "$state_dir/machine_id"
fi
# A tool that cannot see the Software Depot ID it registered with mints a new,
# unregistered one. Tests that check every invocation kept the same identity
# name a file in STUB_IDENTITY_LOG.
[ -z "${STUB_IDENTITY_LOG:-}" ] || cat "$state_dir/machine_id" >> "$STUB_IDENTITY_LOG"

# The filter arguments name the inventory a listing asks for, both for the
# scope check a download target runs first and for the catalog refresh.
catalog_mode() {
	case " $* " in
		*" --automated-install "*) echo install ;;
		*" --patches-only "*) echo patch ;;
		*" --type=UPGRADE "*) echo upgrade ;;
		*) echo unknown ;;
	esac
}

# Tests that need to know which subcommands ran name a file in STUB_CALL_LOG.
if [ -n "${STUB_CALL_LOG:-}" ]; then
	if [ "${1:-}" = binaries ] && [ "${2:-}" = list ]; then
		printf 'binaries list %s\n' "$(catalog_mode "$@")" >> "$STUB_CALL_LOG"
	elif [ "${1:-}" = artifacts ] && [ "${2:-}" = list ]; then
		printf '%s\n' "artifacts list $*" >> "$STUB_CALL_LOG"
	elif [ "${1:-}" = artifacts ] && [ "${2:-}" = download ]; then
		printf '%s\n' "artifacts download $*" >> "$STUB_CALL_LOG"
	else
		printf '%s %s\n' "${1:-}" "${2:-}" >> "$STUB_CALL_LOG"
	fi
fi

if [ "${1:-}" = "--version" ]; then
	cat <<'VERSION'
*********Welcome to VCF Download Tool***********

Version: 0.0.0.0.20000000
0.0.0.0.20000000

Log file: /opt/vmware/vcfdt/log/vdt.log
VERSION
	exit 0
fi
if [ "${1:-}" = releases ] && [ "${2:-}" = list ]; then
    echo 'Depot credentials are valid.'
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
# STUB_LIST_RAW_ROWS is printed verbatim after the generated table rows, so
# tests can add rows the table printer might produce.
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

if [ "${1:-}" = artifacts ]; then
	operation="$2"; component=""; ids=""; depot=""
	shift 2
	for argument in "$@"; do
		case "$argument" in
			--component=*) component="${argument#*=}" ;;
			--id=*) ids="${argument#*=}" ;;
			--depot-store=*) depot="${argument#*=}" ;;
			--vcf-version=*|--sku=*|--ceip=*|--depot-download-activation-code-file=*) ;;
			*) echo "Unsupported artifacts argument: $argument"; exit 2 ;;
		esac
	done
	if [ "$operation" = list ]; then
		[ -z "$depot" ] && [ -z "$ids" ] || exit 2
		mkdir -p "$listing_root/tmpRootDir" || exit 23
		[ "${STUB_FAIL_TARGET:-}" != list ] || exit 23
		[ "${STUB_LIST_NO_TABLE:-0}" != 1 ] || { echo 'No artifacts table'; exit 0; }
		printf 'ID | Component | Component Full Name | Version | Size | Release Date | Type\n'
		case "$component" in
			VKR) n=3; versions='1.34 1.36.2' ;;
			SUPERVISOR) n=1; versions='9.1.0.0.20000000 9.1.1.0.25712839' ;;
			SUPERVISOR_SERVICE_VKS) n=5; versions='3.7.1+v1.36 3.7.2+v1.36' ;;
			*) exit 2 ;;
		esac
		for version in $versions; do
			printf '%08d-0000-4000-8000-%012d | %s | VMware | artifact | %s | 12 GiB | 05/11/2026 | INSTALL\n' "$n" "$n" "$component" "$version"
			n=$((n+1))
		done
		[ -z "${STUB_ARTIFACT_ROWS:-}" ] || printf '%s\n' "$STUB_ARTIFACT_ROWS"
		exit 0
	fi
	[ "$operation" = download ] && [ -n "$ids" ] && [ -n "$depot" ] && [ -z "$component" ] || exit 2
	IFS=, read -r -a selected <<< "$ids"
	for id in "${selected[@]}"; do
		case "$id" in
			00000001-*) component=SUPERVISOR; version=9.1.0.0.20000000 ;;
			00000002-*) component=SUPERVISOR; version=9.1.1.0.25712839 ;;
			00000003-*) component=VKR; version=1.34 ;;
			00000004-*) component=VKR; version=1.36.2 ;;
			00000005-*) component=SUPERVISOR_SERVICE_VKS; version=3.7.1+v1.36 ;;
			00000006-*) component=SUPERVISOR_SERVICE_VKS; version=3.7.2+v1.36 ;;
			*) exit 2 ;;
		esac
		tree="$depot/PROD/COMP/$component"
		mkdir -p "$tree/$version"
		printf 'stub %s %s\n' "$component" "$version" > "$tree/$version/payload.bin"
		printf '{"id":"urn:uuid:stub-library"}\n' > "$tree/lib.json"
		printf '{}\n' > "$tree/$version/item.json"
		payload_size="$(stat -c %s "$tree/$version/payload.bin")"
		printf '{"items":[{"selfHref":"%s/item.json","files":[{"hrefs":["%s/payload.bin"],"size":%s}]}]}\n' "$version" "$version" "$payload_size" > "$tree/items.json"
		if [ "${STUB_INCOMPLETE_MANIFEST:-0}" = 1 ]; then
			printf '{"items":[{"selfHref":"missing/item.json","files":[{"hrefs":["missing/image.vmdk"],"size":10}]}]}\n' > "$tree/items.json"
		fi
	done
	for name in ${STUB_WRITE_TREES:-}; do
		mkdir -p "$depot/PROD/COMP/$name"
		printf 'unexpected write\n' > "$depot/PROD/COMP/$name/unexpected.bin"
	done
	if [ "${STUB_FAIL_TARGET:-}" = artifacts ]; then
		printf '%s\n' "${STUB_ARTIFACT_ERROR:-ERROR: binaries checksum validation failed}"
		exit 23
	fi
	[ "${STUB_SLEEP:-0}" = 0 ] || sleep "$STUB_SLEEP"
	echo 'Successfully downloaded artifacts binaries and OCI images.'
	exit 0
fi

if [ "${1:-}" = binaries ] && [ "${2:-}" = list ]; then
	# The licensed tool stages listing metadata below its download root even
	# though the list command does not accept --depot-store. Model that
	# behavior so image tests exercise the hardened container's real boundary,
	# and model a manifest an earlier listing left staged there being read as
	# it stands, which is what makes a shared stage stale evidence.
	listing_manifest="$listing_root/tmpRootDir/PROD/metadata/manifest/v1/vcfManifest.json"
	if [ -s "$listing_manifest" ]; then
		staged_components="$(cat "$listing_manifest")"
	elif mkdir -p "$(dirname "$listing_manifest")" 2>/dev/null \
		&& components_for_filter "$@" > "$listing_manifest" 2>/dev/null; then
		staged_components="$(cat "$listing_manifest")"
	else
		echo "Could not list the binaries." >&2
		exit 23
	fi
	query_mode="$(catalog_mode "$@")"
	[ -z "${STUB_FAIL_CATALOG_MODE:-}" ] \
		|| [ "${STUB_FAIL_CATALOG_MODE}" != "$query_mode" ] || exit 23
	[ "${STUB_FAIL_TARGET:-}" != list ] || exit 23
	printf '*********Welcome to VCF Download Tool***********\n\nVersion: 0.0.0.0.20000000\n'
	printf 'Validating depot credentials.\nDepot credentials are valid.\n'
	if [ "${STUB_LIST_NO_TABLE:-0}" = 1 ]; then
		echo "No binaries matched the given filter."
		exit 0
	fi
	# shellcheck disable=SC2086
	set -- $staged_components
	case "$query_mode" in
		install) row_type=INSTALL ;;
		patch) row_type=PATCH ;;
		*) row_type=UPGRADE ;;
	esac
	printf 'ID                                   | Component | Component Full Name | Version | Release Date | Size | Type\n'
	printf -- '-----\n'
	index=0
	for component in "$@"; do
		index=$((index + 1))
		printf '%08x-0000-4000-8000-%012d | %s | Stub %s | 9.1.0.0.20000000 | 2026-01-01 | 1 KiB | %s\n' \
			"$index" "$index" "$component" "$component" "$row_type"
	done
	[ -z "${STUB_LIST_RAW_ROWS:-}" ] || printf '%s\n' "$STUB_LIST_RAW_ROWS"
	printf -- '-----\n%s elements\n' "$#"
	# A vendor process can leave its stage behind, and STUB_LOCK_LISTING_STAGE
	# leaves it behind without write permission, so the caller's cleanup fails.
	if [ "${STUB_LOCK_LISTING_STAGE:-0}" = 1 ]; then
		chmod 0555 "$listing_root"
	elif [ "${STUB_LEAVE_LISTING_STAGE:-0}" != 1 ]; then
		rm -rf -- "$listing_root/tmpRootDir"
	fi
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
printf '%s\n' "$stub_version" > "$work_dir/vcf-download-tool-stub/conf/tool-version.txt"
tar -czf "$output" -C "$work_dir" vcf-download-tool-stub
echo "$output"
