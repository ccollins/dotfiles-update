# dotfiles-update — an Oh My Zsh–style update check for a Git (+ GNU stow) dotfiles repo.
#
# On each interactive startup it surfaces, for your dotfiles repo ($DOTFILES):
#   1. uncommitted / unpushed local work         (no network)
#   2. local HEAD ahead of what's *installed*    (no network)  -> restow
#   3. local behind the tracked remote branch    (throttled)   -> pull
# ...and for the plugin itself:
#   4. a newer version of THIS plugin is available (throttled) -> update the plugin
#
# Configure BEFORE `source $ZSH/oh-my-zsh.sh` (same convention as OMZ's own
# update zstyles):
#   export DOTFILES=$HOME/dotfiles          # path to the repo (default ~/dotfiles)
#   DOTFILES_PACKAGES=(shell git ...)       # stow packages to restow on "apply"
#   zstyle ':dotfiles:update' mode prompt   # prompt(default)|auto|reminder|disabled
#   zstyle ':dotfiles:apply'  mode prompt   # prompt(default)|auto|reminder|disabled
#   zstyle ':dotfiles:plugin' mode reminder # self-update: prompt|auto|reminder(default)|disabled
#   zstyle ':dotfiles:update' frequency 1   # days between remote checks
#   zstyle ':dotfiles:update' remote origin # remote name (default origin)
#   zstyle ':dotfiles:update' branch main   # tracked branch (default main)
#
# Not using stow? Define a `dotfiles-apply-hook` function; it's called instead of
# stow for the "apply" step. If neither DOTFILES_PACKAGES nor a hook is set, the
# restow signal (2) is disabled.

: ${DOTFILES:=$HOME/dotfiles}
_df_self="${0:A:h}"                                   # this plugin's own install dir
# expose the bundled tools (merge-managed-json, capture-managed-json) on PATH
[[ -d "$_df_self/bin" ]] && path=("$_df_self/bin" $path)
_df_cache="${ZSH_CACHE_DIR:-$HOME/.cache/dotfiles-update}"
[[ -d "$_df_cache" ]] || mkdir -p "$_df_cache"
_df_update_file="$_df_cache/.dotfiles-update"
_df_plugin_file="$_df_cache/.dotfiles-plugin-update"
_df_installed_file="$_df_cache/.dotfiles-installed"
zstyle -s ':dotfiles:update' remote _df_remote || _df_remote=origin
zstyle -s ':dotfiles:update' branch _df_branch || _df_branch=main
_df_packages=( ${DOTFILES_PACKAGES:+"${DOTFILES_PACKAGES[@]}"} )   # nounset-safe when unset

_df_epoch() { zmodload zsh/datetime; echo $(( EPOCHSECONDS / 86400 )); }
_df_stamp() { echo "LAST_EPOCH=$(_df_epoch)" >! "$1"; }

# run a command under a short timeout when one is available, so a dead/captive
# network can't stall shell startup (Oh My Zsh caps its own check at 2s)
_df_run() {
  if (( ${+commands[timeout]} ));    then timeout 5 "$@"
  elif (( ${+commands[gtimeout]} )); then gtimeout 5 "$@"
  else "$@"; fi
}

# owner/repo slug from a repo's remote URL — $1=repo dir, $2=remote name
_df_slug() {
  local url; url=$(git -C "$1" config "remote.$2.url" 2>/dev/null) || return 1
  case "$url" in
    https://github.com/*)   echo "${${url#https://github.com/}%.git}" ;;
    git@github.com:*)       echo "${${url#git@github.com:}%.git}" ;;
    ssh://git@github.com/*) echo "${${url#ssh://git@github.com/}%.git}" ;;
    *) return 1 ;;
  esac
}

# is $1(repo dir) behind $3(branch) on $2(remote)? sets $_df_rsha to the remote SHA.
# Uses `git ls-remote` — works for public AND private repos via your git creds, no
# `gh`/API dependency. (Mirrors OMZ's is_update_available.)
_df_behind() {
  local dir=$1 remote=$2 branch=$3 lh base
  lh=$(git -C "$dir" rev-parse "$branch" 2>/dev/null) || return 1
  _df_rsha=$(_df_run git -C "$dir" ls-remote "$remote" "$branch" 2>/dev/null | awk 'NR==1{print $1}')
  [[ -n "$_df_rsha" ]] || return 1
  [[ "$lh" != "$_df_rsha" ]] || return 1               # equal -> up to date
  base=$(git -C "$dir" merge-base "$lh" "$_df_rsha" 2>/dev/null) || return 0
  [[ "$base" != "$_df_rsha" ]]                          # base==remote -> local is ahead
}

# 0 if the throttle window for $1(stamp file)/$2(freq days) has elapsed; seeds the
# stamp and returns 1 when it's missing/malformed (so the first run stays silent)
_df_due() {
  local stamp=$1 freq=$2 LAST_EPOCH
  if ! source "$stamp" 2>/dev/null || [[ -z "$LAST_EPOCH" ]]; then _df_stamp "$stamp"; return 1; fi
  (( ( $(_df_epoch) - LAST_EPOCH ) >= freq ))
}

_df_can_apply() { (( $+functions[dotfiles-apply-hook] )) || (( ${#_df_packages} )); }

# --- public helpers -----------------------------------------------------------

# apply the repo to the machine (restow packages or run the hook), then record
# the applied commit as "installed"
dotfiles-apply() {
  emulate -L zsh
  local did=0
  # 1. restow packages (if configured)
  if (( ${#_df_packages} )); then
    (( ${+commands[stow]} )) || { print -P "%F{red}✗ stow not installed%f"; return 1; }
    local pkg
    for pkg in $_df_packages; do
      [[ -d "$DOTFILES/$pkg" ]] && stow -d "$DOTFILES" -t "$HOME" --restow "$pkg"
    done
    did=1
  fi
  # 2. post-apply hook — runs AFTER stow (or standalone if no packages). Use it for
  #    apply steps stow can't express (e.g. generating a config file from a template).
  if (( $+functions[dotfiles-apply-hook] )); then
    dotfiles-apply-hook || return
    did=1
  fi
  if (( ! did )); then
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
  _df_stamp "$_df_update_file"
  _df_handle_apply
}

# update the plugin itself (fast-forward its own checkout)
dotfiles-plugin-update() {
  emulate -L zsh
  [[ -d "$_df_self/.git" ]] || { print -P "%F{yellow}⚠ plugin dir $_df_self is not a git checkout — reinstall to enable self-update%f"; return 1; }
  if git -C "$_df_self" pull --ff-only --quiet; then
    _df_stamp "$_df_plugin_file"
    print -P "%F{green}✓ dotfiles-update plugin updated to $(git -C "$_df_self" rev-parse --short HEAD) — run 'exec zsh' to load it%f"
  else
    print -P "%F{red}✗ plugin update was not a fast-forward — check $_df_self%f"
    return 1
  fi
}

# --- mode-driven checks (run at startup) --------------------------------------

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
  local freq; zstyle -s ':dotfiles:update' frequency freq || freq=1
  _df_due "$_df_update_file" "$freq" || return
  local lock="$_df_cache/.dotfiles-update.lock"
  command mkdir "$lock" 2>/dev/null || return
  {
    _df_behind "$DOTFILES" "$_df_remote" "$_df_branch" || { _df_stamp "$_df_update_file"; return }
    local lh slug
    lh=$(git -C "$DOTFILES" rev-parse --short "$_df_branch")
    slug=$(_df_slug "$DOTFILES" "$_df_remote")
    print -P "%F{cyan}⬆ dotfiles: updates available on $_df_remote/$_df_branch%f"
    [[ -n "$slug" ]] && print "  changelog: https://github.com/$slug/compare/${lh}...${_df_rsha[1,7]}"
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
    _df_stamp "$_df_update_file"
  } always {
    command rmdir "$lock" 2>/dev/null
  }
}

# the plugin's own repo is behind -> offer to update it (throttled)
_df_handle_plugin() {
  emulate -L zsh
  [[ -d "$_df_self/.git" ]] || return              # not a git checkout (e.g. vendored) -> skip
  local mode; zstyle -s ':dotfiles:plugin' mode mode || mode=reminder
  [[ "$mode" != disabled ]] || return
  local freq
  zstyle -s ':dotfiles:plugin' frequency freq \
    || zstyle -s ':dotfiles:update' frequency freq \
    || freq=1
  _df_due "$_df_plugin_file" "$freq" || return
  local lock="$_df_cache/.dotfiles-plugin.lock"
  command mkdir "$lock" 2>/dev/null || return
  {
    _df_behind "$_df_self" origin main || { _df_stamp "$_df_plugin_file"; return }
    local lh slug
    lh=$(git -C "$_df_self" rev-parse --short main 2>/dev/null)
    slug=$(_df_slug "$_df_self" origin)
    print -P "%F{magenta}⬆ dotfiles-update plugin: a new version is available%f"
    [[ -n "$slug" ]] && print "  changelog: https://github.com/$slug/compare/${lh}...${_df_rsha[1,7]}"
    case "$mode" in
      reminder) print -P "  run %F{green}dotfiles-plugin-update%f to update" ;;
      auto)     dotfiles-plugin-update ;;
      *)        printf "  Update the plugin now? [Y/n] "
                local ans; read -r -k 1 ans; [[ "$ans" == $'\n' ]] || echo
                case "$ans" in
                  [yY$'\n']) dotfiles-plugin-update ;;
                  *) print -P "  run %F{green}dotfiles-plugin-update%f later" ;;
                esac ;;
    esac
    _df_stamp "$_df_plugin_file"
  } always {
    command rmdir "$lock" 2>/dev/null
  }
}

# --- run the checks -----------------------------------------------------------
if [[ -o interactive && -t 1 ]] && (( ${+commands[git]} )); then
  if [[ -d "$DOTFILES/.git" ]]; then
    [[ -n "$(git -C "$DOTFILES" status --porcelain 2>/dev/null)" ]] &&
      print -P "%F{yellow}⚠ dotfiles have uncommitted changes — cd $DOTFILES && git status%f"
    [[ -n "$(git -C "$DOTFILES" log --oneline @{u}..HEAD 2>/dev/null)" ]] &&
      print -P "%F{yellow}⚠ dotfiles have unpushed commits — cd $DOTFILES && git push%f"
    # The apply/update lifecycle only makes sense on the tracked branch; skip it
    # while developing the dotfiles repo on a feature branch.
    if [[ "$(git -C "$DOTFILES" symbolic-ref --short -q HEAD)" == "$_df_branch" ]]; then
      _df_handle_apply
      _df_handle_update
    fi
  fi
  _df_handle_plugin
fi
