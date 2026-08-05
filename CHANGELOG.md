# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Version display: `dotfiles status` and `dotfiles-plugin-update` show the installed
  version (`git describe --tags`, so tagged releases read as `v1.0.0`).
- **`dotfiles` command** — a single dispatcher with `status` (on-demand state of every
  axis, ignoring the throttle), `doctor` (health check for a fresh machine), and
  `update` / `apply` / `plugin-update` / `help` subcommands.
- Bundled, tool-agnostic helpers **`merge-managed-json`** and **`capture-managed-json`**
  (in `bin/`, added to `PATH` when the plugin loads) for reconciling app-managed JSON
  config files from a tracked base while preserving machine-local keys. `merge` warns
  loudly instead of silently reverting un-promoted shared changes.
- **Plugin self-update** — a fourth startup signal that checks the plugin's own checkout
  against its remote, with the `:dotfiles:plugin` mode and the `dotfiles-plugin-update`
  command.
- **Post-apply hook** — `dotfiles-apply-hook` now runs after `stow --restow` (or standalone
  when no packages), so apply can include steps stow can't express.
- Test suite (`test/run.sh`, `test/plugin-test.zsh`) and CI (shellcheck, syntax, tests).

### Changed
- The remote update check reads the remote HEAD with `git ls-remote`, so it works for
  public and private repos via your git credentials — no `gh` or GitHub API dependency.
- The network check runs under `timeout`/`gtimeout` when available, so a dead network
  can't stall shell startup.
