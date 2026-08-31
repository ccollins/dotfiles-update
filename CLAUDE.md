# CLAUDE.md

The **`dotfiles-update`** Oh My Zsh plugin: an update/apply check for a Git (+ GNU stow)
dotfiles repo, plus the small generic tools that ship with it. Public repo, effectively
solo, with CI.

## Related repositories

This is one of **three** repos that make up the same system. Work out which one a change
belongs in before editing:

| Repo | Local clone | What lives there | Visibility |
|------|-------------|------------------|------------|
| **this repo** (`dotfiles-update`) | `~/Projects/dotfiles-update` | the update/apply *mechanism*: the zsh plugin and its bundled engines | public |
| `dotfiles` | `~/dotfiles` | personal content: the actual stowed config, Brewfile, identity, secrets wiring, Claude skills/settings | private |
| `dotfiles-template` | `~/Projects/dotfiles-template` | the public starter skeleton + its README (a GitHub template) | public |

Routing rule, from this side:

- A change to **how the check behaves** (startup signals, modes, throttle, the `dotfiles`
  subcommands, the changelog renderer) belongs **here**.
- A change to the **shared engine** (`merge-managed-json`, `capture-managed-json`,
  `vendored-check`, `dotfiles-banner`) belongs **here**. This repo is **canonical** for
  them; the other two consume them from the installed plugin's `bin/` and must never
  vendor a copy. The plugin self-updates, so a fix here reaches every machine.
- Someone's **actual config** (a stow package, a shell tweak, a Brewfile entry, a skill)
  belongs in `dotfiles`, never here.
- The **public starter** or its docs belongs in `dotfiles-template`. Keep its generic
  conventions in step with what is proven here, but never copy personal content into it.

## Layout

```
dotfiles-update.plugin.zsh   # the whole plugin: helpers, subcommands, startup checks
bin/
  merge-managed-json         # base -> live merge for app-managed JSON (preserves keys)
  capture-managed-json       # the inverse: promote live shared changes into the base
  vendored-check             # check .vendor-pinned copies against upstream
  dotfiles-banner            # the rainbow block-letter banner
test/
  run.sh                     # dependency-free runner for the bundled tools
  plugin-test.zsh            # the plugin's pure helpers, run non-interactively
demo/                        # the README GIF and how it was recorded
CHANGELOG.md                 # Keep a Changelog; new work goes under [Unreleased]
```

## Working here

- **`test/run.sh` must pass before you open a PR.** It needs `jq` and `zsh`. CI
  (`.github/workflows/ci.yml`) runs shellcheck over the bash tools, `bash -n` / `zsh -n`
  syntax checks, and then the same suite.
- **Add a test with a behavior change.** Plugin helpers are testable because they are
  pure and the startup block is skipped non-interactively (`plugin-test.zsh` sets
  `DOTFILES` to a nonexistent path to keep it dormant). Tools get tested through
  `run.sh` against temp dirs and local bare remotes, so the suite never touches the
  network.
- **Update `CHANGELOG.md` under `## [Unreleased]`** in the same PR as the change.
- **Startup cost is the budget that matters.** This runs on every interactive shell. Keep
  network calls behind `_df_run` (which bounds them with `timeout`) and behind the
  throttle, and prefer `git ls-remote` over a real `fetch`. That constraint is why the
  startup notice links a compare URL rather than listing commits: the objects are not
  local yet.
- Color must degrade on non-tty, `NO_COLOR`, and below 8 colors. Follow what
  `dotfiles-banner` and `_df_changelog` already do.

## Conventions

- **Changes to `main` go through a PR, not a direct commit.** Branch, PR, squash-merge.
  The PR keeps a reviewable, linear history even solo.
- Never break the public interface (`zstyle` names, `DOTFILES_*` variables, subcommand
  names, the bundled tools' argument order) without a CHANGELOG note. Other repos and
  other people's bootstrap scripts call into these.

### Landing a change

```bash
git checkout -b <short-branch-name>
# ...edit, add tests, update CHANGELOG.md...
test/run.sh
git commit -m "wip"                                  # branch commits are scratch
git push -u origin <short-branch-name>
gh pr create --title "<scope>: <subject>" --body "..." --base main
gh pr merge --squash --delete-branch
git checkout main && git pull --ff-only
```

**The PR title is the permanent record.** Squash-merging collapses the branch into one
commit whose subject is the PR title verbatim, plus `(#N)`. That string is what `git log`
shows forever and what this plugin's own `dotfiles changelog` prints for anyone updating,
so write it for a reader six months out. Branch commit messages are discarded by the
squash; spend the effort on the title instead.

**Format: `<scope>: <subject>`.**

- **Scope** is a single lowercase token, no spaces, naming the part of the plugin the
  change touches. A multi-word prefix does **not** parse as a scope and leaves the
  changelog's tag column blank for that row.
- **Subject** starts lowercase (the changelog capitalizes it) and says what changed and
  why it matters, not which lines moved.
- No trailing period.

| Scope | Covers |
|-------|--------|
| `update` / `apply` / `plugin` | the three lifecycle signals and their handlers |
| `status` / `doctor` / `vendored` / `changelog` | those subcommands |
| `banner` | `bin/dotfiles-banner` and `_df_celebrate` |
| `managed` | `merge-managed-json` and `capture-managed-json` |
| `demo` | the recording sandbox and the README GIF |
| `test` / `ci` | the suite and the workflow |
| `docs` | README, this file, CHANGELOG-only edits |

`docs`, `fix`, `perf`, `refactor`, `test`, `ci` and `build` are Conventional Commit types,
so the changelog files them under their own headings (`Documentation:`, `Bug fixes:`, and
so on) instead of the flat `Changes:` list. Use them when they genuinely fit. Don't force
`feat:` / `chore:` onto changes they describe badly; an accurate subject under `Changes:`
beats a mislabeled one under a heading.

**The repo has to be set to use the PR title, or none of the above holds.** GitHub's
default squash setting is `COMMIT_OR_PR_TITLE`, which silently uses the *branch commit's*
message whenever the branch has exactly one commit. On that default a branch committed as
`wip` lands on `main` as `wip (#19)`, and the title you wrote is discarded. This repo is
set to `PR_TITLE` / `PR_BODY`. Verify, or fix a new repo, with:

```bash
gh api repos/<owner>/<repo> --jq '.squash_merge_commit_title'      # want PR_TITLE
gh api -X PATCH repos/<owner>/<repo> \
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY
```

**Wait for `test` before merging.** It is a required check, so a merge attempted while it
is still running is refused, and `gh` unhelpfully suggests `--admin`. That message means
"the check has not reported yet", not "you need admin rights". Wait and re-run the merge.

**On `gh pr merge --auto`:** GitHub accepts the flag here, because a required check exists
to wait on. The `dotfiles` repo has none, so a fresh PR is already mergeable there and the
flag is rejected outright with `GraphQL: Pull request is in clean status`. Accepting it is
not the same as merging, though: on #18 auto-merge was enabled and the PR was still open a
minute after `test` went green, and a plain `gh pr merge --squash --delete-branch` is what
landed it. I don't know why it didn't fire; assume nothing and check the PR state.
