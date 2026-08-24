# Validation boundaries

Slice 1 is testable without the licensed VCF Download Tool by running:

```bash
./tests/test_sync.sh
./tests/test_scheduler.sh
./tests/test_install_checks.sh
./tests/test_compose.sh
./tests/test_release.sh
./tests/test_sftp.sh
docker build -t vcf-services-sync-base:local -f Dockerfile.sync-base .
./scripts/verify-license-boundary.sh vcf-services-sync-base:local
docker build -t vcf-services-ui:local -f Dockerfile.ui .
docker build -t vcf-services-sftp:local -f Dockerfile.sftp .
docker run --rm -v "$PWD:/work:ro" -w /work vcf-services-ui:local \
  python tests/test_ui.py
```

These shell tests need a working Docker daemon and a host `python3`: the
install checks exercise depot and state adoption in real containers, and the
release test drives the interactive adoption prompt over a pseudo-terminal
through `tests/pty-run.py`.

The repository stub covers installer archive validation, persistent machine-ID
storage, dormant operation, per-target sequencing after a failure, state JSON,
log retention, version parsing, HTTPS authentication, the open UMDS route, and
byte-exact Range responses. The scheduler test covers cron matching, dynamic
schedule reload, duplicate-dispatch prevention, Redis request dispatch through
a stub `redis-cli`, recovery from a malformed `state.json`, and
versions-refresh serialization behind the sync lock. The install checks test
covers cron field bounds (minute, hour, day-of-month, month, day-of-week) and
provided-TLS validation including hostname coverage, key match, and expiry. It
also covers SFTP port and UID:GID validation plus bound-port detection. The
installer checks also mount valid-looking and invalid depot fixtures at
`/depot` and prove that adoption rejects missing VCFDT structure, absolute
symlinks rooted somewhere other than `/depot`, normalized absolute and relative
escapes, and unreadable symlinks, while a dangling symlink whose normalized
target stays inside `/depot` only warns and adoption continues. They also prove
the whole tree is scanned in one pass so every offending path is reported,
grouped separately for escaping and contained-but-broken links. The same test
imports state from a directory and a Docker volume, verifies the Software Depot
ID after copying, proves a rerun is idempotent, and proves that a conflicting
target ID is preserved. They also prove the fixed state volume is never emptied
on behalf of state this run does not own: a stale import marker sitting beside
genuine but unreadable state is refused with the volume byte-for-byte intact, a
stale marker beside a matching ID is treated as an interrupted import and
reimported from the source rather than declared complete, a volume holding only
an abandoned staging directory is cleared and retried, a copy failure leaves no
half-imported content in a volume this run created, and a target holding a
different ID is refused before any copy is attempted, with its contents
untouched. The release test proves non-interactive adoption refuses to proceed
without an explicit previous-writer shutdown assertion and that
`--confirm-old-writer-stopped` advances only scripted adoption. It drives the
interactive branch over a real pseudo-terminal through `tests/pty-run.py`:
each reply is typed only once the confirmation prompt itself has appeared, so
typing exactly `STOPPED` proceeds, while a case-mismatched reply, an unrelated
reply, an empty reply, end of input, and an interrupt all refuse before either
source is read. The UI
test covers next-run calculation in the configured timezone and the backup
settings API: safe defaults that never return the password, refusal to enable
backup without one, atomic settings and password writes, UID:GID and port
validation, rejection of a backup path inside the depot or a `..` segment,
preservation of the unused storage mode's paths, and preservation of the stored
SFTP password when a settings write fails. The compose test statically
enforces the captain decisions: no Docker socket mount, no Docker client
dependency, no macvlan, a non-published password-protected Redis service, only
the configured HTTPS and alternate SFTP ports published, and directory-based
config mounts compatible with atomic settings replacement. It also drives
`compose.sh` against a stubbed `docker` to prove the startup preflight names
each missing install-created prerequisite, points the operator at `install.sh`,
blames a stopped daemon separately, still preflights when Compose global
options precede the `up` command, and passes day-to-day commands and all
original arguments straight through. Live Redis authentication and
non-exposure are also hard gates in `install.sh`. The stub
is test-only and is not copied into a product image unless an operator
explicitly supplies its generated archive to the installer.

The SFTP runtime test builds and starts the real backup image, uploads through
password-authenticated SFTP to an absolute `/mnt/backup/vcenter` path, rejects
an incorrect password, verifies all three host-key types and logged
fingerprints, proves the account cannot run a shell or a remote command, proves
a UID:GID change re-owns the existing backup tree and records the persistent
re-own marker, proves that disabling the service stops the listener and every
already-authenticated session and that re-enabling brings the listener back,
and proves those keys remain unchanged across container recreation.

The release test dry-runs the versioned installation bundle, verifies its
checksum and required entry points, and proves that the bundle consumes the
published UI, sync base, and SFTP images. The license-boundary check locks the
sync base to an allowlisted build context and inspects the built filesystem for
vendor binary or archive names. CI stages a stub vendor tool into the build
context first, so the license-safe images are built and inspected while
vendor-shaped content is present, then builds the local licensed sync layer
against that verified base and runs the tool out of it. CI runs the same checks
before any image can be published.

The following items require captain UAT and are not claimed as verified:

- Actual downloads using the licensed VCFDT binary and a real activation code
- The vendor binary's real machine-ID and version output shapes
- A live NFS export, including capacity reporting and hard-mount behavior
- Consumer trust import in VCF Installer and SDDC Manager
- NSX acceptance of the published nonstandard SFTP port
- SDDC Manager acceptance of the published nonstandard SFTP port

The delivered reference named a VKr mirror file that was absent from its
archive, while the slice scope defers the guided VKr flow. This slice keeps VKr
as an explicit pluggable target, excludes it from defaults, and records a clear
failed target if selected before the later extension is installed.
