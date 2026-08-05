#!/usr/bin/env bash
# Dependency-free test runner for the bundled tools + the plugin helpers.
# Usage: test/run.sh   (requires jq and zsh)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT/bin:$PATH"
fail=0

ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1 — $2"; fail=1; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }
has() { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "[$2] missing [$3]";; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "[$2] should not contain [$3]";; *) ok "$1";; esac; }

command -v jq  >/dev/null || { echo "jq required"; exit 2; }
command -v zsh >/dev/null || { echo "zsh required"; exit 2; }

echo "== merge-managed-json =="
d="$(mktemp -d)"

# 1. fresh: no live file -> base only, real file, model unset
echo '{"theme":"dark","enabledPlugins":{}}' > "$d/base.json"
merge-managed-json "$d/base.json" "$d/live1.json" model >/dev/null
eq "fresh: model unset" "null" "$(jq -r '.model // "null"' "$d/live1.json")"
eq "fresh: theme from base" "dark" "$(jq -r .theme "$d/live1.json")"
[ -L "$d/live1.json" ] && bad "fresh: real file" "is symlink" || ok "fresh: real file"

# 2. preserve multiple local keys; base authoritative; stale dropped
echo '{"theme":"dark","enabledPlugins":{"x":true}}' > "$d/base2.json"
echo '{"model":"opus","account":"work","stale":1,"theme":"light"}' > "$d/live2.json"
merge-managed-json "$d/base2.json" "$d/live2.json" model account >/dev/null 2>&1
eq "preserve model" "opus" "$(jq -r .model "$d/live2.json")"
eq "preserve account" "work" "$(jq -r .account "$d/live2.json")"
eq "base wins theme" "dark" "$(jq -r .theme "$d/live2.json")"
eq "stale dropped" "null" "$(jq -r '.stale // "null"' "$d/live2.json")"

# 3. legacy symlink migration; source untouched
echo '{"theme":"dark"}' > "$d/base3.json"
echo '{"model":"sonnet","enabledPlugins":{"old":true}}' > "$d/target3.json"
ln -s "$d/target3.json" "$d/live3.json"
merge-managed-json "$d/base3.json" "$d/live3.json" model >/dev/null 2>&1
[ -L "$d/live3.json" ] && bad "migration: real file" "still symlink" || ok "migration: real file"
eq "migration: model kept" "sonnet" "$(jq -r .model "$d/live3.json")"
eq "migration: source untouched" "sonnet" "$(jq -r .model "$d/target3.json")"

# 4. invalid JSON live -> recover to base
echo '{"theme":"dark"}' > "$d/base4.json"; printf 'not json{' > "$d/live4.json"
merge-managed-json "$d/base4.json" "$d/live4.json" model >/dev/null 2>&1
eq "invalid recovers" "dark" "$(jq -r .theme "$d/live4.json")"

# 5. drift warning present when live has an un-promoted shared key
echo '{"enabledPlugins":{}}' > "$d/base5.json"
echo '{"model":"opus","enabledPlugins":{"foo":true}}' > "$d/live5.json"
out5="$(merge-managed-json "$d/base5.json" "$d/live5.json" model 2>&1 >/dev/null)"
has "drift warns" "$out5" "shared changes not in the base"
has "drift names key" "$out5" "enabledPlugins"
eq "drift: base still wins" "null" "$(jq -r '.enabledPlugins.foo // "null"' "$d/live5.json")"

# 6. no drift -> no warning
echo '{"enabledPlugins":{"foo":true}}' > "$d/base6.json"
echo '{"model":"opus","enabledPlugins":{"foo":true}}' > "$d/live6.json"
out6="$(merge-managed-json "$d/base6.json" "$d/live6.json" model 2>&1 >/dev/null)"
hasnt "no false drift" "$out6" "shared changes not in the base"

echo "== capture-managed-json =="
echo '{"old":true}' > "$d/cbase.json"
echo '{"model":"opus","enabledPlugins":{"foo":true},"theme":"dark"}' > "$d/clive.json"
capture-managed-json "$d/cbase.json" "$d/clive.json" model >/dev/null 2>&1
eq "capture excludes model" "null" "$(jq -r '.model // "null"' "$d/cbase.json")"
eq "capture keeps plugin" "true" "$(jq -r '.enabledPlugins.foo' "$d/cbase.json")"
eq "capture keeps theme" "dark" "$(jq -r .theme "$d/cbase.json")"

rm -rf "$d"

echo "== plugin helpers (zsh) =="
zsh "$ROOT/test/plugin-test.zsh" || fail=1

echo ""
if [ "$fail" -ne 0 ]; then echo "TESTS FAILED"; exit 1; fi
echo "ALL TESTS PASSED"
