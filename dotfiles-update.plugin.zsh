# dotfiles-update — an Oh My Zsh–style update check for a Git (+ GNU stow) dotfiles repo.
#
# On each interactive startup it surfaces three independent signals for your
# dotfiles repo ($DOTFILES):
#   1. uncommitted / unpushed local work         (no network)
#   2. local HEAD ahead of what's *installed*    (no network)  -> restow
#   3. local behind the tracked remote branch    (throttled)   -> pull
#
# Configure BEFORE `source $ZSH/oh-my-zsh.sh` (same convention as OMZ's own
# update zstyles):
#   export DOTFILES=$HOME/dotfiles          # path to the repo (default ~/dotfiles)
#   DOTFILES_PACKAGES=(shell git ...)       # stow packages to restow on "apply"
#   zstyle ':dotfiles:update' mode prompt   # prompt(default)|auto|reminder|disabled
#   zstyle ':dotfiles:apply'  mode prompt   # prompt(default)|auto|reminder|disabled
#   zstyle ':dotfiles:update' frequency 1   # days between remote checks
#   zstyle ':dotfiles:update' remote origin # remote name (default origin)
#   zstyle ':dotfiles:update' branch main   # tracked branch (default main)
#
# Not using stow? Define a `dotfiles-apply-hook` function; it's called instead of
# stow for the "apply" step (return non-zero to abort). If neither DOTFILES_PACKAGES
# nor a hook is set, the restow signal (2) is disabled.

: ${DOTFILES:=$HOME/dotfiles}
_df_cache="${ZSH_CACHE_DIR:-$HOME/.cache/dotfiles-update}"
[[ -d "$_df_cache" ]] || mkdir -p "$_df_cache"
_df_update_file="$_df_cache/.dotfiles-update"
_df_installed_file="$_df_cache/.dotfiles-installed"
zstyle -s ':dotfiles:update' remote _df_remote || _df_remote=origin
zstyle -s ':dotfiles:update' branch _df_branch || _df_branch=main
_df_packages=(${DOTFILES_PACKAGES[@]})

_df_epoch() { zmodload zsh/datetime; echo $(( EPOCHSECONDS / 86400 )); }
_df_update_stamp() { echo "LAST_EPOCH=$(_df_epoch)" >! "$_df_update_file"; }

# run a command under a short timeout when one is available, so a dead/captive
# network can't stall shell startup (Oh My Zsh caps its own check at 2s)
_df_run() {
  if (( ${+commands[timeout]} ));    then timeout 5 "$@"
  elif (( ${+commands[gtimeout]} )); then gtimeout 5 "$@"
  else "$@"; fi
}

# owner/repo slug from the remote URL (used only to build a GitHub changelog link)
_df_repo_slug() {
  local url; url=$(git -C "$DOTFILES" config "remote.$_df_remote.url" 2>/dev/null) || return 1
  case "$url" in
    https://github.com/*)   echo "${${url#https://github.com/}%.git}" ;;
    git@github.com:*)       echo "${${url#git@github.com:}%.git}" ;;
    ssh://git@github.com/*) echo "${${url#ssh://git@github.com/}%.git}" ;;
    *) return 1 ;;
  esac
}

# remote branch SHA via `git ls-remote` — works for public AND private repos using
# your existing git credentials, with no dependency on `gh` or the GitHub API
_df_remote_sha() {
  _df_run git -C "$DOTFILES" ls-remote "$_df_remote" "$_df_branch" 2>/dev/null | awk 'NR==1{print $1}'
}

# 0 == the remote branch is ahead of local (mirrors OMZ's is_update_available)
_df_update_available() {
  local local_head base
  local_head=$(git -C "$DOTFILES" rev-parse "$_df_branch" 2>/dev/null) || return 1
  _df_last_remote_sha=$(_df_remote_sha) || return 1
  [[ -n "$_df_last_remote_sha" ]] || return 1
  [[ "$local_head" != "$_df_last_remote_sha" ]] || return 1        # equal -> up to date
  base=$(git -C "$DOTFILES" merge-base "$local_head" "$_df_last_remote_sha" 2>/dev/null) || return 0
  [[ "$base" != "$_df_last_remote_sha" ]]                          # base==remote -> local is ahead
}

_df_can_apply() { (( $+functions[dotfiles-apply-hook] )) || (( ${#_df_packages} )); }

# --- public helpers -----------------------------------------------------------

# apply the repo to the machine (restow packages or run the hook), then record
# the applied commit as "installed"
dotfiles-apply() {
  emulate -L zsh
  if (( $+functions[dotfiles-apply-hook] )); then
    dotfiles-apply-hook || return
  elif (( ${#_df_packages} )); then
    (( ${+commands[stow]} )) || { print -P "%F{red}✗ stow not installed%f"; return 1; }
    local pkg
    for pkg in $_df_packages; do
      [[ -d "$DOTFILES/$pkg" ]] && stow -d "$DOTFILES" -t "$HOME" --restow "$pkg"
    done
  else
    print -P "%F{yellow}⚠ nothing to apply: set DOTFILES_PACKAGES or define dotfiles-apply-hook%f"
    return 1
  fi
  git -C "$DOTFILES" rev-parse HEAD >! "$_df_installed_file"
  print -P "%F{green}✓ dotfiles applied at $(git -C "$DOTFILES" rev-parse --short HEAD)%f"
}

# pull remote updates (fast-forward only), then apply per :dotfiles:apply mode
dotfiles-update() {
  emulate -L zsh
  local cur; cur=$(git -C "$DOTFILES" symbolic-ref --short -q HEAD)
  if [[ "$cur" != "$_df_branch" ]]; then
    print -P "%F{yellow}⚠ dotfiles is on '${cur:-detached HEAD}', not $_df_branch — not auto-pulling. Switch to $_df_branch first.%f"
    return 1
  fi
  git -C "$DOTFILES" pull --ff-only --quiet "$_df_remote" "$_df_branch" || {
    print -P "%F{red}✗ dotfiles pull was not a fast-forward — resolve manually in $DOTFILES%f"
    return 1
  }
  _df_update_stamp
  _df_handle_apply
}

# --- mode-driven decisions ----------------------------------------------------

# local HEAD moved past what's installed -> offer to restow
_df_handle_apply() {
  emulate -L zsh
  _df_can_apply || return                          # no applier configured -> no signal
  local mode; zstyle -s ':dotfiles:apply' mode mode || mode=prompt
  [[ "$mode" != disabled ]] || return
  local head installed
  head=$(git -C "$DOTFILES" rev-parse HEAD 2>/dev/null) || return
  if [[ ! -f "$_df_installed_file" ]]; then         # seed silently, never nag retroactively
    echo "$head" >! "$_df_installed_file"; return
  fi
  installed=$(<"$_df_installed_file")
  [[ "$head" != "$installed" ]] || return
  print -P "%F{yellow}⬇ dotfiles: repo (${head[1,7]}) is newer than installed (${installed[1,7]})%f"
  case "$mode" in
    reminder) print -P "  run %F{green}dotfiles-apply%f to restow" ;;
    auto)     dotfiles-apply ;;
    *)        printf "  Apply (restow) now? [Y/n] "
              local ans; read -r -k 1 ans; [[ "$ans" == $'\n' ]] || echo
              case "$ans" in
                [yY$'\n']) dotfiles-apply ;;
                *) print -P "  run %F{green}dotfiles-apply%f later" ;;
              esac ;;
  esac
}

# remote is ahead of local -> offer to pull (throttled; mirrors OMZ handle_update)
_df_handle_update() {
  emulate -L zsh
  local mode; zstyle -s ':dotfiles:update' mode mode || mode=prompt
  [[ "$mode" != disabled ]] || return
  local LAST_EPOCH
  if ! source "$_df_update_file" 2>/dev/null || [[ -z "$LAST_EPOCH" ]]; then
    _df_update_stamp; return
  fi
  local freq; zstyle -s ':dotfiles:update' frequency freq || freq=1
  (( ( $(_df_epoch) - LAST_EPOCH ) >= freq )) || return
  local lock="$_df_cache/.dotfiles-update.lock"
  command mkdir "$lock" 2>/dev/null || return
  {
    _df_update_available || { _df_update_stamp; return }
    local lh slug
    lh=$(git -C "$DOTFILES" rev-parse --short "$_df_branch")
    slug=$(_df_repo_slug)
    print -P "%F{cyan}⬆ dotfiles: updates available on $_df_remote/$_df_branch%f"
    [[ -n "$slug" ]] && print "  changelog: https://github.com/$slug/compare/${lh}...${_df_last_remote_sha[1,7]}"
    case "$mode" in
      reminder) print -P "  run %F{green}dotfiles-update%f to pull" ;;
      auto)     dotfiles-update ;;
      *)        printf "  Pull now? [Y/n] "
                local ans; read -r -k 1 ans; [[ "$ans" == $'\n' ]] || echo
                case "$ans" in
                  [yY$'\n']) dotfiles-update ;;
                  *) print -P "  run %F{green}dotfiles-update%f later" ;;
                esac ;;
    esac
    _df_update_stamp
  } always {
    command rmdir "$lock" 2>/dev/null
  }
}

# --- run the checks -----------------------------------------------------------
if [[ -o interactive && -t 1 && -d "$DOTFILES/.git" ]] && (( ${+commands[git]} )); then
  [[ -n "$(git -C "$DOTFILES" status --porcelain 2>/dev/null)" ]] &&
    print -P "%F{yellow}⚠ dotfiles have uncommitted changes — cd $DOTFILES && git status%f"
  [[ -n "$(git -C "$DOTFILES" log --oneline @{u}..HEAD 2>/dev/null)" ]] &&
    print -P "%F{yellow}⚠ dotfiles have unpushed commits — cd $DOTFILES && git push%f"
  # The apply/update lifecycle only makes sense on the tracked branch; skip it
  # while developing dotfiles on a feature branch.
  if [[ "$(git -C "$DOTFILES" symbolic-ref --short -q HEAD)" == "$_df_branch" ]]; then
    _df_handle_apply
    _df_handle_update
  fi
fi
