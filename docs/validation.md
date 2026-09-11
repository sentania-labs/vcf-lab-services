# Validation boundaries

Run the repository gates before release:

```bash
./tests/test_sync.sh
./tests/test_scheduler.sh
./tests/test_scheduler_lock.sh
./tests/test_install_checks.sh
./tests/test_compose.sh
./tests/test_release.sh
./tests/test_sftp.sh
./tests/test_kubernetes.sh
docker build -t vcf-services-sync-base:local -f Dockerfile.sync-base .
./scripts/verify-license-boundary.sh vcf-services-sync-base:local
./tests/test_sync_image.sh vcf-services-sync-base:local
docker build -t vcf-services-ui:local -f Dockerfile.ui .
docker build -t vcf-services-sftp:local -f Dockerfile.sftp .
docker run --rm -v "$PWD:/work:ro" -w /work vcf-services-ui:local \
  python tests/test_ui.py
VCF_SERVICES_UI_IMAGE=vcf-services-ui:local \
VCF_SERVICES_SYNC_IMAGE=vcf-services-sync-base:local \
VCF_SERVICES_SFTP_IMAGE=vcf-services-sftp:local \
  ./tests/test_compose_boot.sh
```

The UI test covers first-person ownership, login, live depot authentication,
licensed archive staging by upload, listing and installing tool archives
from a stub `PROD/COMP/VCFDT` depot tree through the same locked release swap
(with the depot left untouched, paths outside that tree refused, and a
running sync refused), previous-release retention and rollback, Software Depot
ID adoption before installation, confirmation by the first tool probe,
refusal with a tool already present, invalid ID, active-sync and tool-update
refusals, installation-probe mismatch reporting and activation blocking,
persistent Software Depot ID retrieval, activation
secret storage, storage confirmation, recurring schedule and endpoint editing,
content-library ownership detection and default protection,
refusal of inventory and mutations on unreadable or invalid ownership state
without replacing the manifest,
depot browsing, guarded file and folder-archive upload, explicit delete
confirmation with size and file count, protected-tree enforcement, path
traversal and symlink escape refusal, contained directory-link access,
public patch-store notices for direct uploads and directory restores, and mutation refusal
during a running sync or tool update,
the schedule preview endpoint computing an unsaved schedule's next run in
the configured or supplied timezone and rejecting bad input,
setup completion, shared password replacement, sync dispatch, partial settings
merges over the stored document, settings saved during a running sync being
persisted and flagged for the next run while the tool-backed endpoints stay
blocked, a save that lands under the run's settings snapshot lock before the
run publishes its state still being flagged for the next run, the live backup
service settings being reported as applied now instead of deferred, the tabbed
console rendering every control including the daily, weekly, and custom cron
schedule picker with its next-run readout, advisory tool probes as described in
[release validation](releasing.md), forward config migration with an
in-volume backup, and newer-version downgrade refusal. The Compose test
enforces the latest-tracking published-image defaults,
their always-pull behavior, and their override variables,
first-boot state initialization, internal TLS, the platform-provided storage
boundary, protected Redis, fixed mount contracts, version mismatch safe-stop
wiring, and the absence of a Docker socket. Shell tests cover scheduler timing,
single-writer sync behavior, sync safe-stop on a version mismatch, log
retention, tool-version run state, post-success release promotion, retention
after a successful VKR-only run with non-tool provenance, lifecycle
script behavior through a stub Compose command, SFTP identity and host keys,
Range serving, packaging, the release
tag gate (well formed tags on main pass, malformed or unmerged tags are
refused), idempotent release publication, and license isolation. The
Kubernetes manifest test also asserts that product images default to the
latest tags with an always-pull policy.

`tests/test_sync.sh` also runs `tests/test_sync_protection.py`, which checks
that protected content libraries stay byte, link and metadata identical while
unrelated install, upgrade and patches downloads run, that a target whose
tool listing names a protected tree skips and names only that tree, that an
unobtainable listing leaves the target unrun, that a write or link change
inside a protected tree during a run is reported, plus dispatch refusal and
manifest preservation when ownership reads or persistence fail. It also proves that a depot lock which cannot be
opened is reported as a locking failure rather than as a run in progress, and
that the verbose lock diagnostics stay silent until the console turns them on.

`tests/test_scheduler_lock.sh` is the executable form of the scheduler lock
reproduction. It runs the real scheduler and the real `sync.sh` with a stub
tool and a queue-file bus, slows the scheduler's housekeeping read the way
the reproduction did, and requires every requested run and every requested
versions refresh to be admitted. It
then proves that a second sync during a run, a versions refresh during a run,
and a run during a versions refresh are each refused with the contention
message, that a run killed outright releases the lock once its download
stops, that a scheduled dispatch takes the same hand-off, that the console's
diagnostics switch is picked up without a restart, and that scheduler
housekeeping and versions refresh report an unopenable lock once instead of
claiming a run is in progress.

`tests/test_sync_image.sh IMAGE` runs the `sync.sh` shipped inside a built
sync image, with that image's own jq and awk, against a stub tool and a
protected operator tree: targets that do not write the tree run, targets whose
listing names it skip. Debian bookworm ships jq 1.6, which rejects a query the
host's jq 1.7 accepts, and mawk rather than GNU awk, so this proof has to run
in the image; CI runs it against the freshly built `vcf-services-sync-base:ci`.

`tests/make-stub-depot.sh <dir> [version ...]` builds a stub depot tree that
models the reference depot layout for the tool itself, a flat
`PROD/COMP/VCFDT/vcf-download-tool-<version>.tar.gz` per tool version, so the
console's "Install from depot" control can be exercised locally without the
licensed archive. Bind-mount that directory in place of the depot volume (in a
Compose stack, or at `/depot:ro` on the ui image together with the writable
tool store at `/opt/vcfdt`, a settings.env at `/config`, and a secrets
directory holding at least the session secret, which the image refuses to start
without) to see the Setup tab list and install the stub versions.

`tests/test_compose_boot.sh` uses an isolated project, container names, network,
and fresh volumes. Before applying its override, it checks that the shipped
Compose configuration publishes the expected HTTPS and SFTP TCP port mappings,
so the override cannot hide missing or misrouted publications. It publishes
HTTPS and SFTP only on Docker-assigned loopback
ports, so it can run beside an installed appliance without reconciling or
removing the appliance containers. The test requires the console login page to
be reachable over the published HTTPS port and requires the published SFTP port
to return an SSH banner after enabling backups through the console API. It also
starts the complete Compose appliance with
locally built images, requires each long-running service to become healthy or
running, installs and activates the stub tool, and runs a sync that rewrites its
telemetry flag through the shared tool mount. The one-shot bootstrap service
must exit successfully. The normal GitHub-hosted CI job runs this proof with a
real Docker daemon after building the three product images.

CI renders the Kubernetes manifests, validates them against strict Kubernetes
schemas, and asserts the storage, secret-path, ingress, and single-Pod network
contracts in the rendered output. Unit and container tests separately prove
that bootstrap and SFTP return fsGroup-style private-file modes to `0600`.
The manifest test also rejects Pod-wide `fsGroup` and any backup mount in the
volume-permissions init container. The SFTP test uses populated backup content
to prove an ordinary restart takes the constant-time ownership path without
recursively changing stored files. A deliberate GUI UID:GID change remains the
only operation that recursively migrates backup ownership.

`tests/test_kubernetes_live.sh` is the command-line runtime proof for a
disposable kind cluster after the three local product images have been tagged
with `:ci`. Local execution is the required author prediction, and the
GitHub-hosted CI job independently runs the same repository-owned proof. The
test takes a host-wide fail-fast lock, then creates, verifies, and deletes its
own cluster. It
waits for the five-container Pod, exercises HTTPS and Redis over Pod loopback,
checks ServiceAccount isolation, injects fsGroup-style `0660` modes, restarts
the Pod, and verifies private secrets and SFTP host keys return to `0600`.

This throwaway kind proof establishes that the manifests are valid and the
appliance boots. It does not verify real storage classes, Longhorn, NFS,
shared-storage access modes, load balancers, or other cluster-specific
behavior. It also does not exercise ownership startup cost on a populated
backup store. That guarantee comes from the manifest ownership contract and
the populated-store SFTP regression test. Those remain deployment-environment
validation responsibilities.

`tests/test_install_checks.sh` runs the supported upgrade and uninstall
commands against a stub Docker and Compose executable. It proves upgrade pulls
and recreates services, then refuses to claim success when persistent-state
migration is blocked. It proves default uninstall omits volume removal, reports
Compose-resolved volume names, removes only product images, and retains shared
Caddy and Redis images. A cancelled purge changes nothing, and a confirmed
purge requests volume removal. The same test remains the regression guard for
the depot-adoption scripts (`scripts/install-checks.sh`,
`scripts/import-vcfdt-state.sh`, and `scripts/validate-adopted-depot.sh`) that
let an existing VCFDT depot and Software Depot ID be adopted without
re-downloading. Those retained scripts remain the file-level migration and
regression path. For the console identity-adoption workflow and required
ordering, see [First run](../README.md#first-run).

Release validation also requires a live HTTP walk through claim, upload,
registration, and settings, plus an authenticated HTTPS Range request. The
release workflow repeats this proof against the published tagged images on
clean volumes before creating the GitHub release. Healthy containers alone are
not sufficient.

The stub cannot verify these claims:

- Actual machine ID output from the licensed VCF Download Tool. Version
  output is already confirmed against captured licensed tool output (see
  `docs/releasing.md`).
- Registration and download with a real activation code.
- Adopting the `infra.int` depot's ID on a fresh appliance, then completing a
  sync with its existing activation code.
- A real content sync and consumption by VCF Installer, SDDC Manager, UMDS, or
  Fleet.
- Consumer trust import for the Caddy internal CA.
- NSX, vCenter, and SDDC Manager backup uploads against the live SFTP service.

Those remain captain UAT items and must be named in the PR and release notes.
