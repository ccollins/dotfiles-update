# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.1.1] - 2026-08-07

### Fixed
- `dotfiles status` and the startup reminders now suggest the dispatcher form
  (`dotfiles update` / `apply` / `plugin-update`) instead of the hyphenated commands.

## [1.1.0] - 2026-08-07

### Added
- **`vendored-check <dir>…`** + **`dotfiles vendored`** — check vendored (pinned,
  copied-in) dependencies for upstream updates via a `.vendor` provenance file
  (`repo`/`ref`/`branch`) next to each copy. `dotfiles vendored` reads dirs from
  `DOTFILES_VENDORED_DIRS` or its args; read-only, `git ls-remote`-based, with a GitHub
  compare URL for anything behind.

## [1.0.0] - 2026-08-05

### Added
- Startup update/apply check for a Git (+ GNU stow) dotfiles repo — uncommitted/unpushed,
  local-ahead-of-installed (restow), and local-behind-remote (pull) signals — with
  `prompt` (default) / `auto` / `reminder` / `disabled` modes and a once-per-frequency
  throttle.
- **Plugin self-update** — a fourth startup signal checking the plugin's own checkout,
  with the `:dotfiles:plugin` mode and the `dotfiles-plugin-update` command.
- **`dotfiles` command** — a dispatcher with `status` (on-demand state of every axis),
  `doctor` (health check for a fresh machine), and `update` / `apply` / `plugin-update`
  / `help` subcommands.
- **Version display** — `dotfiles status` and `dotfiles-plugin-update` show the installed
  version via `git describe --tags`.
- Bundled, tool-agnostic helpers **`merge-managed-json`** / **`capture-managed-json`** (on
  `PATH` when the plugin loads) for reconciling app-managed JSON config from a tracked
  base while preserving machine-local keys; `merge` warns loudly instead of silently
  reverting un-promoted shared changes.
- **Post-apply hook** — `dotfiles-apply-hook` runs after `stow --restow` (or standalone
  when no packages).
- Test suite (`test/run.sh`, `test/plugin-test.zsh`), demo (`demo/record-demo.sh`), and CI
  (shellcheck + syntax + tests).

### Changed
- The remote checks read the remote HEAD with `git ls-remote`, so they work for public
  and private repos via your git credentials — no `gh` or GitHub API dependency — and run
  under `timeout`/`gtimeout` so a dead network can't stall shell startup.
