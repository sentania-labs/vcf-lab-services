#!/bin/bash
# Build a stub depot tree that models the reference Broadcom depot layout for
# the download tool itself: PROD/COMP/VCFDT/vcf-download-tool-<version>.tar.gz,
# flat, one archive per tool version (no version subdirectories). The console
# offers these archives on the Setup tab as "Install from depot".
set -euo pipefail

depot_dir="${1:?usage: make-stub-depot.sh <depot_dir> [version ...]}"
shift || true
versions=("$@")
if [ "${#versions[@]}" -eq 0 ]; then
	versions=(9.1.0.0.25371089 9.1.0.0100.25429019)
fi
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool_dir="$depot_dir/PROD/COMP/VCFDT"
mkdir -p "$tool_dir" "$depot_dir/PROD/COMP/ESX_HOST/patch-store"
for version in "${versions[@]}"; do
	STUB_VERSION="$version" "$script_dir/make-stub-vcfdt.sh" \
		"$tool_dir/vcf-download-tool-$version.tar.gz" >/dev/null
done
ls -1 "$tool_dir"
