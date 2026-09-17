# Roadmap

Written for an operator, not a developer. Plain terms: what runs today, what
is being worked on next and why, and what is intentionally not being built.

Current release: v0.3.1 (2026-09-15). See
[releases](https://github.com/sentania-labs/vcf-lab-services/releases) for the
full tag history.

## What is built and working

- A self-hosted Docker Compose appliance (and a supported single-Pod
  Kubernetes deployment) providing an HTTPS VCF binary depot, a scheduled
  sync engine, an SFTP backup target, and an admin console. See
  [First run](../README.md#first-run).
- GUI-first day-one setup: claim the appliance, install or adopt the licensed
  VCF Download Tool, set the sync schedule and filters, and run a sync,
  all from the console. No shell access needed for normal operation.
- Adopting an already-registered Software Depot ID before the tool is
  installed, so a migrated appliance keeps its existing activation instead of
  being issued a new one.
- Tool install, upgrade, and rollback from the console, including installing
  straight from an archive the sync already mirrored into the depot.
- Depot ownership tracking: a hand-placed tree holding both `items.json` and
  `lib.json` is detected as a content library and protected automatically, as
  is a tree uploaded through the console. Any other pre-existing tree is
  recorded as unknown and is not protected until protection is enabled in the
  Depot tab. The console's file explorer (browse, upload, delete) respects
  that protection.
- A fix so protecting one hand-placed tree no longer stops the download tool
  from running its other targets. Earlier, protecting any tree silently
  skipped every install, upgrade, and patch download.
- A durable catalog of available versions shown on the Sync tab after every
  sync, kept across restarts even if a later sync fails.
- Sign-in and the dashboard now read the appliance's saved identity instead
  of launching the download tool on every login. This removed a 5-15 second
  delay on login that was traced to the tool being started as a subprocess.
- A background lock-handoff fix so a dispatched sync no longer fails
  against its own lock a few milliseconds after starting (this was the root
  cause behind sporadic "another sync is already running" messages and a
  versions panel that looked permanently broken after one collision).

## What is next, in priority order

1. **Confirm issue #44's fix on the appliance** (the flock self-conflict
   report). The fix described above (handing the lock to the launched run
   instead of re-taking it) addresses the mechanism the issue reported, a
   dedicated test (`tests/test_scheduler_lock.sh`) guards it, and the issue
   was closed on 17 September 2026 against the v0.2.8 release. What remains
   is bookkeeping, not new work: watch a live sync on the deployed appliance
   and confirm the behaviour there.
2. **VKR content tree adoption into the sync target.** The appliance already
   inventories and protects an existing VKR content-library tree, but does
   not yet adopt it as the live sync target the way it does for other
   components. Recorded as a known gap in the README's prototype boundaries.
3. **Backup status by product and release.** The SFTP backup service runs,
   but the console does not yet check or report on backup health per
   product and release.
4. **Native in-product NFS configuration.** Storage is currently
   platform-provided (the operator points the appliance at existing mounts).
   Building NFS configuration into the product itself is deferred.

Priority order here follows what is already partly done (closing out #44)
ahead of what is fully new work, and follows the README's own listed
boundaries for the rest. There is no committed date for items 2-4; they are
next in line, not scheduled.

## Deliberately deferred or rejected

- **Restricting on-demand TLS certificate issuance to configured or observed
  hostnames.** The prototype keeps the current open-issuance behavior
  unchanged for now.
- **Dedicated-IP (macvlan) Docker networking mode.** Considered and closed
  as not planned: it would require either a privileged host control path or
  a restart orchestrator from the GUI, which conflicts with the appliance's
  deliberate no-Docker-socket design. Shared hosts use an external reverse
  proxy or the supported Kubernetes ingress path instead.
- **Proof against the real licensed tool and a real Broadcom download.** The
  repository's own test stubs validate the setup workflow, archive handling,
  and version parsing, but machine-ID output, a real activation code, and an
  actual sync serving real depot content to VCF consumers can only be proven
  with the captain's licensed archive and lab. This is not a backlog item to
  build; it is evidence that has to wait for that access.

## Where this traces from

Everything above traces to the repository itself (README "Prototype
boundaries" section, commit history, and `docs/`), to GitHub issue #44 (closed,
fixed by PR #46) and #47 (closed, fixed by PR #48), or to background diagnostic work already
folded into the shipped fixes (the login-latency and lock-race
investigations). Where earlier background notes described problems that the
repository has since fixed, this roadmap reflects the fix, not the older
note.
