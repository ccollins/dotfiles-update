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
#   zstyle ':dotfiles:banner' mode fancy    # fancy(default)|plain — the ASCII banner
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
# human-readable version of the installed plugin (tag if any, else short sha)
_df_version() { git -C "$_df_self" describe --tags --always 2>/dev/null; }

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

# Mark a milestone (applied / updated / all green) with the big rainbow banner —
# the art lives in bin/dotfiles-banner so a bootstrap script can print the same
# thing. Falls back to a one-line message when the banner is off or unavailable.
#   $1 = banner message  $2 = plain fallback (print -P; empty = print nothing)
#   $3 = tagline override (default: a random one from the banner's own list)
_df_celebrate() {
  emulate -L zsh
  local mode; zstyle -s ':dotfiles:banner' mode mode || mode=fancy
  if [[ "$mode" == fancy ]] && (( ${+commands[dotfiles-banner]} )); then
    local -a extra
    [[ -n "${3-}" ]] && extra=(--tagline "$3")
    dotfiles-banner "${extra[@]}" "$1"
  elif [[ -n "${2-}" ]]; then
    print -P "$2"
  fi
}

# --- changelog ----------------------------------------------------------------

# Render an Oh My Zsh-style changelog for a commit range.
#
# Commit subjects are read two ways, because dotfiles repos split about evenly
# between the conventions: a Conventional Commit (`feat(scope): subject`) groups
# the commit under its type, while a plain `scope: subject` just gets tagged with
# its prefix. A subject with neither still lists fine, untagged. A trailing
# `(#123)` from a squash merge is pulled out and colored like a PR ref.
#
#   $1 = repo dir  $2 = from rev  $3 = to rev (default HEAD)
#   $4 = heading   $5 = remote for the compare URL (default origin)
# Returns 1 when the range holds no commits, so callers can stay quiet.
_df_changelog() {
  emulate -L zsh
  setopt local_options extended_glob
  local dir=$1 from=$2 to=${3:-HEAD} heading=${4-} remote=${5:-origin}
  [[ -d "$dir/.git" ]] || return 1
  local f_s t_s
  f_s=$(git -C "$dir" rev-parse --short "$from" 2>/dev/null) || return 1
  t_s=$(git -C "$dir" rev-parse --short "$to" 2>/dev/null) || return 1

  local -a raw
  raw=( ${(f)"$(git -C "$dir" log --no-merges --format='%h%x1f%s' "$from..$to" 2>/dev/null)"} )
  raw=( ${raw:#} )
  (( ${#raw} )) || return 1

  local limit; zstyle -s ':dotfiles:changelog' limit limit || limit=50
  local -i extra=0
  if (( ${#raw} > limit )); then
    extra=$(( ${#raw} - limit ))
    raw=( ${raw[1,limit]} )
  fi

  # Conventional Commit types we recognize, in the order they're printed. A
  # prefix that isn't one of these is treated as a scope, not a type.
  local -a TYPES=(feat fix perf revert refactor docs test build ci style chore)
  local -A TITLE=(
    feat "Features" fix "Bug fixes" perf "Performance" revert "Reverts"
    refactor "Refactors" docs "Documentation" test "Tests" build "Build"
    ci "CI" style "Style" chore "Chores" _other "Changes"
  )

  local C_SHA='' C_SCOPE='' C_REF='' C_HEAD='' C_BR='' C_DIM='' C_OFF=''
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    local depth; depth=$(TERM="${TERM:-dumb}" tput colors 2>/dev/null || echo 0)
    if (( depth >= 8 )); then
      C_SHA=$'\e[33m'; C_SCOPE=$'\e[1;33m'; C_REF=$'\e[32m'
      C_HEAD=$'\e[1;34m'; C_BR=$'\e[1;4m'; C_DIM=$'\e[2m'; C_OFF=$'\e[0m'
    fi
  fi

  local -A bucket
  local -i width=0 seq=0
  local l sha subj prefix head rest ref cscope ctype key
  for l in $raw; do
    sha=${l%%$'\x1f'*}; subj=${l#*$'\x1f'}
    # trailing "(#123)" from a squash merge -> its own column
    ref=''
    if [[ "$subj" == *' (#'<->')' ]]; then
      ref=${subj##* }
      subj=${subj[1,-$(( ${#ref} + 2 ))]}
    fi
    ctype=''; cscope=''
    prefix=${subj%%:*}
    # a prefix is only a prefix if there was a colon and it's a single token
    if [[ "$prefix" != "$subj" && -n "$prefix" && "$prefix" != *[[:space:]]* ]]; then
      rest=${subj#*:}; rest=${rest##[[:space:]]#}
      head=${${prefix%%\(*}%\!}
      if (( ${TYPES[(Ie)$head]} )); then
        ctype=$head
        [[ "$prefix" == *\(*\)* ]] && cscope=${${prefix#*\(}%\)*}
      else
        cscope=$prefix
      fi
      [[ -n "$rest" ]] && subj=$rest
    fi
    [[ -n "$subj" ]] && subj="${(U)subj[1]}${subj[2,-1]}"
    (( ${#cscope} > width )) && width=${#cscope}
    key=${ctype:-_other}
    # Scope leads the record so each group sorts by it (as OMZ does), which keeps
    # the [scope] column reading down the page. The counter behind it is the
    # tiebreaker: zsh's sort isn't stable, and without it commits sharing a scope
    # (in particular the unscoped ones) would come out ordered by sha, not by date.
    bucket[$key]+="${cscope}"$'\x1f'"${(l:6::0:)seq}"$'\x1f'"${sha}"$'\x1f'"${subj}"$'\x1f'"${ref}"$'\n'
    (( ++seq ))
  done

  local br; br=$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null)
  [[ -n "$heading" ]] && print -r -- "${C_HEAD}${heading}${C_OFF}"
  print -r -- "${C_BR}${br:-$t_s}${C_OFF}  ${C_DIM}${f_s}..${t_s}${C_OFF}"

  local pad='' t rec rsha rsc rsub rref tag
  local -i n
  for t in $TYPES _other; do
    [[ -n "${bucket[$t]}" ]] || continue
    print -r --
    print -r -- "${C_HEAD}${TITLE[$t]}:${C_OFF}"
    print -r --
    for rec in ${(oi)${(f)bucket[$t]}}; do
      [[ -n "$rec" ]] || continue
      rsc=${rec%%$'\x1f'*};  rec=${rec#*$'\x1f'}
      rec=${rec#*$'\x1f'}                       # drop the sort tiebreaker
      rsha=${rec%%$'\x1f'*}; rec=${rec#*$'\x1f'}
      rsub=${rec%%$'\x1f'*}; rref=${rec#*$'\x1f'}
      tag=''
      if (( width )); then
        if [[ -n "$rsc" ]]; then
          n=$(( width - ${#rsc} ))
          tag="${C_SCOPE}[${rsc}]${C_OFF}${(l:$n:)pad} "
        else
          n=$(( width + 2 ))
          tag="${(l:$n:)pad} "
        fi
      fi
      print -r -- "  - ${C_SHA}${rsha}${C_OFF} ${tag}${rsub}${rref:+ ${C_REF}${rref}${C_OFF}}"
    done
  done

  print -r --
  (( extra )) && print -r -- "  ${C_DIM}... and $extra more commit$( (( extra == 1 )) || print -n s )${C_OFF}"
  local slug; slug=$(_df_slug "$dir" "$remote")
  [[ -n "$slug" ]] && print -r -- "  ${C_DIM}full diff: https://github.com/$slug/compare/${f_s}...${t_s}${C_OFF}"
  return 0
}

# `dotfiles changelog [from [to]]`. With no args: what's landed since the
# commit that was last applied to this machine, falling back to recent history
# when the repo is already applied.
_df_changelog_cmd() {
  emulate -L zsh
  local from=${1-} to=${2:-HEAD}
  [[ -d "$DOTFILES/.git" ]] || { print -P "%F{red}✗ $DOTFILES is not a git repo%f"; return 1 }
  if [[ -z "$from" ]]; then
    if [[ -f "$_df_installed_file" ]]; then
      from=$(<"$_df_installed_file")
      [[ "$(git -C "$DOTFILES" rev-parse HEAD 2>/dev/null)" != "$from" ]] || from=''
    fi
    [[ -n "$from" ]] || from='HEAD~10'
    git -C "$DOTFILES" rev-parse --verify -q "$from^{commit}" >/dev/null 2>&1 ||
      from=$(git -C "$DOTFILES" rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)
  fi
  _df_changelog "$DOTFILES" "$from" "$to" "" "$_df_remote" ||
    { print -P "%F{yellow}no commits between ${from:-?} and $to%f"; return 1 }
}

# --- public helpers -----------------------------------------------------------

# apply the repo to the machine (restow packages or run the hook), then record
# the applied commit as "installed"
dotfiles-apply() {
  emulate -L zsh
  local did=0 n=0
  # 1. restow packages (if configured)
  if (( ${#_df_packages} )); then
    (( ${+commands[stow]} )) || { print -P "%F{red}✗ stow not installed%f"; return 1; }
    local pkg
    for pkg in $_df_packages; do
      [[ -d "$DOTFILES/$pkg" ]] || continue
      stow -d "$DOTFILES" -t "$HOME" --restow "$pkg"
      (( ++n ))
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
  local sha; sha=$(git -C "$DOTFILES" rev-parse --short HEAD)
  local msg="applied at $sha"
  (( n )) && msg+=" · $n package$( (( n == 1 )) || print -n s ) restowed"
  _df_celebrate "$msg" "%F{green}✓ dotfiles applied at $sha%f"
}

# pull remote updates (fast-forward only), then apply per :dotfiles:apply mode
dotfiles-update() {
  emulate -L zsh
  local cur; cur=$(git -C "$DOTFILES" symbolic-ref --short -q HEAD)
  if [[ "$cur" != "$_df_branch" ]]; then
    print -P "%F{yellow}⚠ dotfiles is on '${cur:-detached HEAD}', not $_df_branch — not auto-pulling. Switch to $_df_branch first.%f"
    return 1
  fi
  local before; before=$(git -C "$DOTFILES" rev-parse HEAD 2>/dev/null)
  git -C "$DOTFILES" pull --ff-only --quiet "$_df_remote" "$_df_branch" || {
    print -P "%F{red}✗ dotfiles pull was not a fast-forward — resolve manually in $DOTFILES%f"
    return 1
  }
  _df_stamp "$_df_update_file"
  local after; after=$(git -C "$DOTFILES" rev-parse HEAD 2>/dev/null)
  [[ "$before" != "$after" ]] &&
    _df_changelog "$DOTFILES" "$before" "$after" "Updating dotfiles" "$_df_remote"
  _df_handle_apply
}

# update the plugin itself (fast-forward its own checkout)
dotfiles-plugin-update() {
  emulate -L zsh
  [[ -d "$_df_self/.git" ]] || { print -P "%F{yellow}⚠ plugin dir $_df_self is not a git checkout — reinstall to enable self-update%f"; return 1; }
  local before; before=$(git -C "$_df_self" rev-parse HEAD 2>/dev/null)
  if git -C "$_df_self" pull --ff-only --quiet; then
    _df_stamp "$_df_plugin_file"
    local after; after=$(git -C "$_df_self" rev-parse HEAD 2>/dev/null)
    [[ "$before" != "$after" ]] &&
      _df_changelog "$_df_self" "$before" "$after" "Updating the dotfiles-update plugin" origin
    _df_celebrate "plugin updated to $(_df_version)" \
      "%F{green}✓ dotfiles-update plugin updated to $(_df_version) — run 'exec zsh' to load it%f" \
      "run 'exec zsh' to load it"
  else
    print -P "%F{red}✗ plugin update was not a fast-forward — check $_df_self%f"
    return 1
  fi
}

# --- `dotfiles` command (on-demand dispatcher) -------------------------------

_df_help() {
  print -r -- 'dotfiles — manage your dotfiles repo
  status         show current state (dirty · unpushed · not-applied · behind · plugin)
  update         pull the tracked branch, then apply
  changelog      what changed [from [to]] (default: since the applied commit)
  apply          restow packages / run apply hook, record installed commit
  plugin-update  update the dotfiles-update plugin itself
  doctor         check the setup is healthy
  vendored       check vendored (pinned) dependencies for upstream updates
  help           this message'
}

# on-demand status of every axis (ignores the startup throttle)
_df_status() {
  emulate -L zsh
  local ok="%F{green}✓%f" warn="%F{yellow}⚠%f" warns=0
  print -P "%Bdotfiles%b  $DOTFILES"
  [[ -d "$DOTFILES/.git" ]] || { print -P "  $warn not a git repo"; return 1 }
  if [[ -n "$(git -C "$DOTFILES" status --porcelain 2>/dev/null)" ]]; then
    print -P "  $warn uncommitted changes"; (( ++warns ))
  else
    print -P "  $ok working tree clean"
  fi
  if [[ -n "$(git -C "$DOTFILES" log --oneline @{u}..HEAD 2>/dev/null)" ]]; then
    print -P "  $warn unpushed commits"; (( ++warns ))
  else
    print -P "  $ok nothing unpushed"
  fi
  if _df_can_apply; then
    local head installed
    head=$(git -C "$DOTFILES" rev-parse --short HEAD 2>/dev/null)
    [[ -f "$_df_installed_file" ]] && installed=$(<"$_df_installed_file")
    if [[ "$(git -C "$DOTFILES" rev-parse HEAD 2>/dev/null)" == "$installed" ]]; then
      print -P "  $ok applied ($head)"
    else
      print -P "  $warn not applied (repo $head ≠ installed ${installed[1,7]:-none}) — dotfiles apply"
      (( ++warns ))
    fi
  fi
  if _df_behind "$DOTFILES" "$_df_remote" "$_df_branch"; then
    print -P "  $warn update available on $_df_remote/$_df_branch — dotfiles update"
    (( ++warns ))
  else
    print -P "  $ok up to date with $_df_remote/$_df_branch"
  fi
  if [[ -d "$_df_self/.git" ]]; then
    if _df_behind "$_df_self" origin main; then
      print -P "  $warn plugin update available — dotfiles plugin-update"; (( ++warns ))
    else
      print -P "  $ok plugin up to date ($(_df_version))"
    fi
  fi
  # nothing to nag about — take the win
  (( warns )) || _df_celebrate \
    "everything in sync · $(git -C "$DOTFILES" rev-parse --short HEAD 2>/dev/null)" ""
}

# check the setup is healthy (generic plumbing; app-specific configs are yours)
_df_doctor() {
  emulate -L zsh
  local ok="%F{green}✓%f" bad="%F{red}✗%f" n=0
  print -P "%Bdotfiles doctor%b"
  _df_chk() { if eval "$2"; then print -P "  $ok $1"; else print -P "  $bad $1"; (( n++ )); fi }
  _df_chk "git available"                          '(( $+commands[git] ))'
  _df_chk "jq available"                           '(( $+commands[jq] ))'
  _df_chk "timeout available (bounds the net check)" '(( $+commands[timeout] || $+commands[gtimeout] ))'
  _df_chk "DOTFILES is a git repo ($DOTFILES)"     '[[ -d "$DOTFILES/.git" ]]'
  _df_chk "on tracked branch ($_df_branch)"        '[[ "$(git -C "$DOTFILES" symbolic-ref --short -q HEAD)" == "$_df_branch" ]]'
  _df_chk "plugin is a git checkout (self-update)" '[[ -d "$_df_self/.git" ]]'
  _df_chk "engine on PATH (merge-managed-json)"    '(( $+commands[merge-managed-json] ))'
  _df_chk "cache dir writable ($_df_cache)"        '[[ -w "$_df_cache" ]]'
  unfunction _df_chk
  (( n == 0 )) && print -P "  %F{green}all good%f" || print -P "  %F{yellow}$n issue(s) above%f"
  return $(( n > 0 ))
}

# check vendored (pinned) dependencies for upstream updates. Dirs come from the
# args, else from the DOTFILES_VENDORED_DIRS array (each dir holds <name>/.vendor).
_df_vendored() {
  emulate -L zsh
  local -a dirs
  if (( $# )); then dirs=("$@")
  else dirs=( ${DOTFILES_VENDORED_DIRS:+"${DOTFILES_VENDORED_DIRS[@]}"} ); fi
  if (( ! ${#dirs} )); then
    print -P "%F{yellow}dotfiles vendored: pass a dir, or set DOTFILES_VENDORED_DIRS (dirs holding <name>/.vendor)%f"
    return 1
  fi
  (( ${+commands[vendored-check]} )) || { print -P "%F{red}vendored-check not found (is the plugin bin on PATH?)%f"; return 1 }
  vendored-check "${dirs[@]}"
}

dotfiles() {
  emulate -L zsh
  local cmd="${1:-help}"; (( $# )) && shift
  case "$cmd" in
    status)        _df_status ;;
    doctor)        _df_doctor ;;
    update)        dotfiles-update "$@" ;;
    changelog|log) _df_changelog_cmd "$@" ;;
    apply)         dotfiles-apply "$@" ;;
    plugin-update) dotfiles-plugin-update "$@" ;;
    vendored)      _df_vendored "$@" ;;
    help|-h|--help) _df_help ;;
    *) print -P "%F{red}dotfiles: unknown command '$cmd'%f"; _df_help; return 1 ;;
  esac
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
    reminder) print -P "  run %F{green}dotfiles apply%f to restow" ;;
    auto)     dotfiles-apply ;;
    *)        printf "  Apply (restow) now? [Y/n] "
              local ans; read -r -k 1 ans; [[ "$ans" == $'\n' ]] || echo
              case "$ans" in
                [yY$'\n']) dotfiles-apply ;;
                *) print -P "  run %F{green}dotfiles apply%f later" ;;
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
      reminder) print -P "  run %F{green}dotfiles update%f to pull" ;;
      auto)     dotfiles-update ;;
      *)        printf "  Pull now? [Y/n] "
                local ans; read -r -k 1 ans; [[ "$ans" == $'\n' ]] || echo
                case "$ans" in
                  [yY$'\n']) dotfiles-update ;;
                  *) print -P "  run %F{green}dotfiles update%f later" ;;
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
      reminder) print -P "  run %F{green}dotfiles plugin-update%f to update" ;;
      auto)     dotfiles-plugin-update ;;
      *)        printf "  Update the plugin now? [Y/n] "
                local ans; read -r -k 1 ans; [[ "$ans" == $'\n' ]] || echo
                case "$ans" in
                  [yY$'\n']) dotfiles-plugin-update ;;
                  *) print -P "  run %F{green}dotfiles plugin-update%f later" ;;
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
