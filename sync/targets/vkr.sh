#!/bin/bash
set -uo pipefail

depot_dir="$1"
matches="${2:-}"
os_variant="${3:-}"

if [ -x /opt/vcf-services/extensions/vkr-mirror ]; then
	exec /opt/vcf-services/extensions/vkr-mirror \
		--dest "$depot_dir/PROD/COMP/VKR" --match "$matches" --os "$os_variant"
fi

echo "VKr sync is configured as a pluggable target, but the guided mirror extension is not included in slice 1."
echo "Remove vkr from SYNC_TARGETS until the VKr content flow is installed."
exit 2
