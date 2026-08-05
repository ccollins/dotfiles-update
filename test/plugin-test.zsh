#!/usr/bin/env zsh
# Tests for the plugin's pure helpers (_df_slug, _df_due, _df_behind).
# Run non-interactively so the plugin's startup block is skipped.
emulate -L zsh

ROOT="${0:A:h}/.."
typeset -g _fail=0
ok()   { print -r -- "  ok: $1" }
bad()  { print -r -- "  FAIL: $1 — $2"; _fail=1 }
eq()   { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "expected [$2] got [$3]" }
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
eq "status reports up to date" "yes" "$([[ "$(dotfiles status 2>&1)" == *'up to date'* ]] && echo yes)"
truthy "doctor passes on a healthy setup" "dotfiles doctor >/dev/null 2>&1"
falsy  "unknown subcommand errors" "dotfiles bogus >/dev/null 2>&1"

rm -rf "$ZSH_CACHE_DIR" "$r1" "$r2" "$work" "${rem:h}" "$dwork" "${drem:h}"
print ""
if (( _fail )); then print "PLUGIN TESTS FAILED"; exit 1; else print "plugin tests passed"; fi
