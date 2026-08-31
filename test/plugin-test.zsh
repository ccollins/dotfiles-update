#!/usr/bin/env zsh
# Tests for the plugin's pure helpers (_df_slug, _df_due, _df_behind).
# Run non-interactively so the plugin's startup block is skipped.
emulate -L zsh

ROOT="${0:A:h}/.."
typeset -g _fail=0
ok()   { print -r -- "  ok: $1" }
bad()  { print -r -- "  FAIL: $1 — $2"; _fail=1 }
eq()   { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "expected [$2] got [$3]" }
has()  { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "[$2] missing [$3]" }
hasnt(){ [[ "$2" == *"$3"* ]] && bad "$1" "[$2] should not contain [$3]" || ok "$1" }
truthy() { if eval "$2"; then ok "$1"; else bad "$1" "expected success: $2"; fi }
falsy()  { if eval "$2"; then bad "$1" "expected failure: $2"; else ok "$1"; fi }

export ZSH_CACHE_DIR="$(mktemp -d)"
export DOTFILES="/nonexistent"   # keep the startup block dormant regardless
source "$ROOT/dotfiles-update.plugin.zsh"

print "== _df_slug =="
r1="$(mktemp -d)"; git -C "$r1" init -q; git -C "$r1" remote add origin "https://github.com/foo/bar.git"
eq "https slug" "foo/bar" "$(_df_slug "$r1" origin)"
r2="$(mktemp -d)"; git -C "$r2" init -q; git -C "$r2" remote add origin "git@github.com:baz/qux.git"
eq "ssh slug" "baz/qux" "$(_df_slug "$r2" origin)"

print "== _df_due (throttle) =="
stamp="$ZSH_CACHE_DIR/.t"
falsy "first call seeds, not due" "_df_due '$stamp' 1"
falsy "within window, not due" "_df_due '$stamp' 1"
print "LAST_EPOCH=0" >! "$stamp"
truthy "old stamp is due" "_df_due '$stamp' 1"

print "== _df_behind (offline via local bare remote) =="
rem="$(mktemp -d)/rem.git"; git init -q --bare "$rem"
work="$(mktemp -d)"; git -C "$work" init -q -b main
git -C "$work" config user.email t@t; git -C "$work" config user.name t
echo one > "$work/f"; git -C "$work" add -A; git -C "$work" commit -qm one
echo two >> "$work/f"; git -C "$work" commit -qam two
git -C "$work" remote add origin "$rem"; git -C "$work" push -q origin main
falsy "up to date -> not behind" "_df_behind '$work' origin main"
git -C "$work" reset --hard -q HEAD~1     # local now one commit behind remote
truthy "local behind remote -> behind" "_df_behind '$work' origin main"

print "== dotfiles-banner =="
typeset -a _art
_art=( ${(f)"$(dotfiles-banner --no-tagline 'applied at abc1234')"} )
_art=( ${(M)_art:#[█╚]*} )   # the art rows: every one starts with a block or a corner
eq "banner has 6 art rows" "6" "${#_art}"
typeset -A _w; for _r in $_art; do _w[${#_r}]=1; done
eq "art rows share one width" "1" "${#_w}"          # a mis-edited glyph would ragged it
eq "art is 61 columns wide" "61" "${(k)_w}"
zstyle ':dotfiles:banner' mode plain
eq "plain mode keeps the one-liner" "yes" \
  "$([[ "$(_df_celebrate 'msg' '✓ plain line')" == *'plain line'* ]] && print yes)"
eq "plain mode prints no art" "yes" \
  "$([[ "$(_df_celebrate 'msg' '✓ plain line')" != *█* ]] && print yes)"
eq "plain mode with no fallback is silent" "" "$(_df_celebrate 'msg' '')"
zstyle -d ':dotfiles:banner' mode
eq "fancy mode prints the art" "yes" \
  "$([[ "$(_df_celebrate 'msg' '✓ plain line')" == *█* ]] && print yes)"

print "== _df_changelog =="
cl="$(mktemp -d)"; git -C "$cl" init -q -b main
git -C "$cl" config user.email t@t; git -C "$cl" config user.name t
git -C "$cl" remote add origin "https://github.com/foo/bar.git"
for _m in "init" \
          "feat(cli): add a flag (#7)" \
          "fix: stop crashing (#8)" \
          "Brewfile: add ripgrep (#9)" \
          "plain subject with no prefix"; do
  print -r -- "$_m" >> "$cl/f"; git -C "$cl" add -A; git -C "$cl" commit -qm "$_m"
done
_cl="$(_df_changelog "$cl" HEAD~4 HEAD 'Updating dotfiles' origin)"
has "changelog prints the heading"     "$_cl" "Updating dotfiles"
has "changelog prints the branch"      "$_cl" "main"
has "conventional feat -> Features"    "$_cl" "Features:"
has "conventional fix -> Bug fixes"    "$_cl" "Bug fixes:"
has "untyped commits -> Changes"       "$_cl" "Changes:"
has "conventional scope is tagged"     "$_cl" "[cli]"
has "plain 'scope:' prefix is tagged"  "$_cl" "[Brewfile]"
has "prefix is stripped from subject"  "$_cl" "Add a flag"
hasnt "type prefix is not left inline" "$_cl" "feat(cli):"
has "squash PR ref is kept"            "$_cl" "(#7)"
has "unprefixed subject survives"      "$_cl" "Plain subject with no prefix"
has "compare URL from the remote"      "$_cl" "github.com/foo/bar/compare/"
hasnt "no color when not a tty"        "$_cl" "$(printf '\033')"
# alignment: every scope tag starts at the same column
typeset -a _cols; for _l in ${(f)_cl}; do [[ "$_l" == *\[* ]] && _cols+=( ${${_l%%\[*}##} ); done
typeset -A _u; for _c in $_cols; do _u[${#_c}]=1; done
eq "scope column is aligned" "1" "${#_u}"
falsy "empty range returns non-zero" "_df_changelog '$cl' HEAD HEAD '' origin >/dev/null"
eq "empty range prints nothing" "" "$(_df_changelog "$cl" HEAD HEAD '' origin)"
zstyle ':dotfiles:changelog' limit 2
_cl2="$(_df_changelog "$cl" HEAD~4 HEAD '' origin)"
has "limit truncates with a count" "$_cl2" "and 2 more commits"
zstyle -d ':dotfiles:changelog' limit

print "== dotfiles dispatcher =="
drem="$(mktemp -d)/d.git"; git init -q --bare -b main "$drem"
dwork="$(mktemp -d)"; git -C "$dwork" init -q -b main
git -C "$dwork" config user.email t@t; git -C "$dwork" config user.name t
echo x > "$dwork/f"; git -C "$dwork" add -A; git -C "$dwork" commit -qm init
git -C "$dwork" remote add origin "$drem"; git -C "$dwork" push -q -u origin main
export DOTFILES="$dwork"; _df_self="$dwork"          # keep every axis offline + green
dotfiles-apply-hook() { : }                          # make _df_can_apply true
git -C "$dwork" rev-parse HEAD >! "$ZSH_CACHE_DIR/.dotfiles-installed"
eq "help lists subcommands" "yes" "$([[ "$(dotfiles help 2>&1)" == *status* ]] && echo yes)"
eq "help lists vendored" "yes" "$([[ "$(dotfiles help 2>&1)" == *vendored* ]] && echo yes)"
eq "help lists changelog" "yes" "$([[ "$(dotfiles help 2>&1)" == *changelog* ]] && echo yes)"
falsy "vendored with no dirs hints" "dotfiles vendored >/dev/null 2>&1"
eq "status reports up to date" "yes" "$([[ "$(dotfiles status 2>&1)" == *'up to date'* ]] && echo yes)"
truthy "doctor passes on a healthy setup" "dotfiles doctor >/dev/null 2>&1"
falsy  "unknown subcommand errors" "dotfiles bogus >/dev/null 2>&1"
# with no args the default range is "since the commit last applied here", so a
# commit made after the marker was written is exactly what should show up
print -r -- 'pending' >> "$dwork/f"
git -C "$dwork" commit -qam "shell: add a pending change (#42)"
has "changelog defaults to unapplied work" "$(dotfiles changelog 2>&1)" "Add a pending change"
has "changelog tags the scope" "$(dotfiles changelog 2>&1)" "[shell]"

rm -rf "$ZSH_CACHE_DIR" "$r1" "$r2" "$work" "${rem:h}" "$dwork" "${drem:h}" "$cl"
print ""
if (( _fail )); then print "PLUGIN TESTS FAILED"; exit 1; else print "plugin tests passed"; fi
