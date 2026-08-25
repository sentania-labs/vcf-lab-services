# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- The licensed VCF Download Tool must never be committed or redistributed. Use
  `tests/make-stub-vcfdt.sh` for local and CI validation.
- Run `tests/test_sync.sh`, `tests/test_scheduler.sh`,
  `tests/test_install_checks.sh`, `tests/test_compose.sh`,
  `tests/test_release.sh`, `tests/test_sftp.sh`, the UI unit test documented in
  `docs/validation.md`, and the installer's live Range check before release.
- Release tags are the product version authority. Follow `docs/releasing.md`
  and keep the published sync base free of licensed VCFDT content.
- Preserve the storage contracts in `docker-compose.yml`: the depot is `/depot`
  in both consumers, backup storage is separate and read-write at `/mnt/backup`,
  `vcf-services-vcfdt-tool` is disposable and distinct from the protected
  `vcf-services-vcfdt-state`, and the state plus SFTP host-key volumes are
  external so a recreate cannot discard registered identity or fingerprints.
- The admin console and sync service exchange jobs only over the internal
  password-protected Redis bus defined in `docs/redis-contract.md`. No
  container mounts the Docker socket and macvlan networking is out of scope.
- `config/settings.env` is the file-backed settings contract for later GUI
  editing. New operator-facing settings need a GUI control when their slice is
  implemented.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
