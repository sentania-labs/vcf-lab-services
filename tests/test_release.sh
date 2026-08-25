#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work_dir="$(mktemp -d /tmp/vcf-services-release-test.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT

version=v0.0.0
repository=ghcr.io/example/vcf-lab-services
"$project_dir/scripts/package-release.sh" "$version" "$work_dir" "$repository" >/dev/null

archive="$work_dir/vcf-lab-services-$version.tar.gz"
[ -s "$archive" ]
[ -s "$archive.sha256" ]
[ -x "$work_dir/install.sh" ]
(
	cd "$work_dir"
	sha256sum -c "$(basename "$archive.sha256")"
)

required=(
	"vcf-lab-services-$version/.release.env"
	"vcf-lab-services-$version/install.sh"
	"vcf-lab-services-$version/compose.sh"
	"vcf-lab-services-$version/docker-compose.yml"
	"vcf-lab-services-$version/Dockerfile.sync"
	"vcf-lab-services-$version/Dockerfile.sync.dockerignore"
	"vcf-lab-services-$version/caddy/Caddyfile"
	"vcf-lab-services-$version/docs/releasing.md"
	"vcf-lab-services-$version/scripts/install-checks.sh"
	"vcf-lab-services-$version/scripts/import-vcfdt-state.sh"
	"vcf-lab-services-$version/scripts/validate-adopted-depot.sh"
)
listing="$(tar -tzf "$archive")"
for path in "${required[@]}"; do
	grep -qx "$path" <<< "$listing"
done
! grep -Eq 'Dockerfile\.sync-base|Dockerfile\.ui|(^|/)ui/|(^|/)sync/' <<< "$listing"

tar -xzf "$archive" -C "$work_dir"
[ -x "$work_dir/vcf-lab-services-$version/compose.sh" ]
grep -qx "VCF_SERVICES_VERSION=$version" "$work_dir/vcf-lab-services-$version/.release.env"
grep -qx "VCF_SERVICES_IMAGE_REPOSITORY=$repository" "$work_dir/vcf-lab-services-$version/.release.env"
grep -q 'pull_product_image "$ui_image"' "$project_dir/install.sh"
grep -q 'pull_product_image "$sync_base_image"' "$project_dir/install.sh"
grep -q 'pull_product_image "$sftp_image"' "$project_dir/install.sh"
grep -q 'docker pull "$image"' "$project_dir/install.sh"
grep -q 'could not pull \$image' "$project_dir/install.sh"
! grep -q 'docker build' "$project_dir/install.sh"
grep -q 'VCF_SERVICES_SYNC_IMAGE' "$project_dir/install.sh"
grep -q 'VCF_SERVICES_UI_IMAGE' "$project_dir/docker-compose.yml"
grep -q 'VCF_SERVICES_SYNC_IMAGE' "$project_dir/docker-compose.yml"
grep -q 'VCF_SERVICES_SFTP_IMAGE' "$project_dir/docker-compose.yml"
! grep -q 'build/vcfdt' "$project_dir/Dockerfile.sync" "$project_dir/Dockerfile.sync.dockerignore"

bundle_dir="$work_dir/vcf-lab-services-$version"
source_dir="$work_dir/source-checkout"
cp -a "$bundle_dir" "$source_dir"
rm -f "$source_dir/.release.env"

expect_failure() {
	local expected_status="$1" expected_text="$2" status=0 output
	shift 2
	output="$("$@" 2>&1 </dev/null)" || status=$?
	[ "$status" -eq "$expected_status" ] || {
		echo "expected exit $expected_status, got $status from: $*" >&2
		printf '%s\n' "$output" >&2
		exit 1
	}
	grep -q -e "$expected_text" <<< "$output" || {
		echo "expected output to mention: $expected_text" >&2
		printf '%s\n' "$output" >&2
		exit 1
	}
}

# A source checkout with no origin remote cannot derive images, and says so.
expect_failure 1 '--image-repository REPOSITORY' "$source_dir/install.sh"

# An explicit image repository restores installation from a source checkout:
# metadata resolution succeeds and the run reaches the first answer prompt.
expect_failure 2 'PRODUCT_FQDN is missing' \
	"$source_dir/install.sh" --image-repository ghcr.io/example/vcf-lab-services
expect_failure 2 'PRODUCT_FQDN is missing' \
	"$source_dir/install.sh" --image-repository ghcr.io/example/vcf-lab-services --version v9.9.9

# Overrides are still validated.
expect_failure 2 'not a valid Docker tag' \
	"$source_dir/install.sh" --image-repository ghcr.io/example/vcf-lab-services --version 'bad tag'
expect_failure 2 'not a valid lowercase repository path' \
	"$source_dir/install.sh" --image-repository 'GHCR.IO/Example/Repo'

# A bundle pins its own images, so the source-checkout overrides are rejected
# rather than silently mixing one release with another release's images.
expect_failure 2 'apply only to a source checkout' \
	"$bundle_dir/install.sh" --version v9.9.9
expect_failure 2 'apply only to a source checkout' \
	"$bundle_dir/install.sh" --image-repository ghcr.io/example/other

# Adoption cannot safely share a depot with the previous writer. A scripted
# run must make the shutdown assertion explicitly, while interactive runs stop
# at a prominent confirmation prompt.
expect_failure 2 'adoption requires confirmation that the previous writer is stopped' \
	"$bundle_dir/install.sh" --adopt-state-dir /tmp
expect_failure 2 'PRODUCT_FQDN is missing' \
	"$bundle_dir/install.sh" --adopt-state-dir /tmp --confirm-old-writer-stopped
expect_failure 2 'requires --adopt-state-dir or --adopt-state-volume' \
	"$bundle_dir/install.sh" --confirm-old-writer-stopped

# The interactive half of the same contract, driven over a real terminal.
adopt_answers="$work_dir/adopt-answers.env"
printf 'PRODUCT_FQDN=invalid name\n' > "$adopt_answers"

writer_prompt='Type STOPPED to confirm'

pty_expect() {
	local description="$1" expected_status="$2" expected_text="$3" feed="$4" status=0 output
	shift 4
	output="$(python3 "$project_dir/tests/pty-run.py" --wait-for "$writer_prompt" "$feed" "$@" 2>&1)" || status=$?
	[ "$status" -eq "$expected_status" ] || {
		echo "$description: expected exit $expected_status, got $status" >&2
		printf '%s\n' "$output" >&2
		exit 1
	}
	grep -q -e "$expected_text" <<< "$output" || {
		echo "$description: expected output to mention: $expected_text" >&2
		printf '%s\n' "$output" >&2
		exit 1
	}
}

pty_expect 'typing STOPPED proceeds' 2 'invalid FQDN' 'STOPPED\n' \
	"$bundle_dir/install.sh" --answers-file "$adopt_answers" --adopt-state-dir /tmp
pty_expect 'a lowercase reply refuses' 2 'adoption cancelled because writer shutdown was not confirmed' 'stopped\n' \
	"$bundle_dir/install.sh" --answers-file "$adopt_answers" --adopt-state-dir /tmp
pty_expect 'an unrelated reply refuses' 2 'adoption cancelled because writer shutdown was not confirmed' 'yes\n' \
	"$bundle_dir/install.sh" --answers-file "$adopt_answers" --adopt-state-dir /tmp
pty_expect 'an empty reply refuses' 2 'adoption cancelled because writer shutdown was not confirmed' '\n' \
	"$bundle_dir/install.sh" --answers-file "$adopt_answers" --adopt-state-dir /tmp
pty_expect 'end of input refuses' 2 'adoption cancelled because writer shutdown was not confirmed' '\x04' \
	"$bundle_dir/install.sh" --answers-file "$adopt_answers" --adopt-state-dir /tmp

# An interrupted confirmation must never fall through into the adoption path.
interrupt_status=0
interrupt_output="$(python3 "$project_dir/tests/pty-run.py" --wait-for "$writer_prompt" '\x03' \
	"$bundle_dir/install.sh" --answers-file "$adopt_answers" --adopt-state-dir /tmp 2>&1)" \
	|| interrupt_status=$?
[ "$interrupt_status" -ne 0 ] || {
	echo "an interrupted writer confirmation must not succeed" >&2
	exit 1
}
grep -q 'ADOPTION SAFETY CHECK' <<< "$interrupt_output" || {
	echo "the interrupted run never reached the writer confirmation prompt" >&2
	printf '%s\n' "$interrupt_output" >&2
	exit 1
}
grep -q "$writer_prompt" <<< "$interrupt_output" || {
	echo "the interrupted run never reached the writer confirmation prompt" >&2
	printf '%s\n' "$interrupt_output" >&2
	exit 1
}
if grep -q 'invalid FQDN' <<< "$interrupt_output"; then
	echo "an interrupted writer confirmation continued into adoption" >&2
	exit 1
fi

# Bundle metadata stays strict.
printf 'VCF_SERVICES_UNEXPECTED=1\n' > "$bundle_dir/.release.env"
expect_failure 1 'unsupported release metadata key' "$bundle_dir/install.sh"
printf 'VCF_SERVICES_VERSION=1.0\nVCF_SERVICES_IMAGE_REPOSITORY=%s\n' "$repository" > "$bundle_dir/.release.env"
expect_failure 1 'invalid version' "$bundle_dir/install.sh"
printf 'VCF_SERVICES_VERSION=%s\nVCF_SERVICES_IMAGE_REPOSITORY=docker.io/example/repo\n' "$version" > "$bundle_dir/.release.env"
expect_failure 1 'invalid image repository' "$bundle_dir/install.sh"

echo "release packaging and image-consumption contract tests passed"
