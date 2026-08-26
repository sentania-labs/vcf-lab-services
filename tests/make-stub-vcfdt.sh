#!/bin/bash
set -euo pipefail

output="${1:-vcf-download-tool-0.0.0-stub.tar.gz}"
work_dir="$(mktemp -d /tmp/vcf-services-stub.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT
mkdir -p "$work_dir/vcf-download-tool-stub/bin" "$work_dir/vcf-download-tool-stub/conf"

cat > "$work_dir/vcf-download-tool-stub/bin/vcf-download-tool" <<'STUB'
#!/bin/bash
set -euo pipefail

state_dir="${HOME}/.local/share/vmware/vdt"
mkdir -p "$state_dir"
if [ ! -s "$state_dir/machine_id" ]; then
	cat /proc/sys/kernel/random/uuid > "$state_dir/machine_id"
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
if [ "${1:-}" = configuration ] && [ "${2:-}" = get ] && [ "${3:-}" = --machineId ]; then
	cat "$state_dir/machine_id"
	exit 0
fi
if [ "${1:-}" = binaries ] && [ "${2:-}" = list ]; then
	echo "11111111-1111-4111-8111-111111111111 | SDDC_MANAGER | Stub bundle | 9.1.0.0.20000000 | 2026-01-01 | 1 KiB | UPGRADE"
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
[ "${STUB_FAIL_TARGET:-}" != "$target" ] || exit 23
if [ "${STUB_SLEEP:-0}" != 0 ]; then sleep "$STUB_SLEEP"; fi
depot=/depot
for argument in "$@"; do
	case "$argument" in --depot-store=*) depot="${argument#*=}" ;; esac
done
mkdir -p "$depot/PROD/COMP/ESX_HOST/patch-store" "$depot/STUB/$target"
printf 'stub content for %s\n' "$target" > "$depot/STUB/$target/20000000.bin"
ln -sfn "$depot/PROD/COMP/ESX_HOST/patch-store" "$depot/umds-patch-store"
echo "stub completed target $target"
STUB
chmod 0755 "$work_dir/vcf-download-tool-stub/bin/vcf-download-tool"
cat > "$work_dir/vcf-download-tool-stub/conf/application-prodv2.properties" <<'PROPERTIES'
lcm.depot.adapter.host=dl.broadcom.com
lcm.access_token.broadcom.authorization.server.url=https://eapi.broadcom.com/vcf/generateToken
PROPERTIES
tar -czf "$output" -C "$work_dir" vcf-download-tool-stub
echo "$output"
