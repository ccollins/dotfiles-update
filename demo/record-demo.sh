#!/usr/bin/env bash
# record-demo.sh — stage a throwaway sandbox that triggers every dotfiles-update
# startup signal, then drop into an interactive zsh where opening the shell shows
# them. For recording a demo GIF (see demo/README.md).
#
# Fully sandboxed: a temp dir holds a fake dotfiles repo + its remote, a fake
# plugin checkout + its remote, and an isolated OMZ cache. Your real ~/.claude,
# ~/dotfiles, and installed plugin are never touched. The sandbox is removed when
# you exit the demo shell.
#
# Env:
#   DEMO_SETUP_ONLY=1   build the sandbox, print its path, and exit (for testing)
set -euo pipefail

PLUGIN_SRC="$(cd "$(dirname "$0")/.." && pwd)"
SBX="$(mktemp -d)"
gitq() { git -C "$1" -c user.email=demo@demo -c user.name=demo -c init.defaultBranch=main "${@:2}"; }

# --- fake dotfiles repo: local at commit2, origin ahead at commit3 -------------
REM="$SBX/dotfiles.git"; git init -q --bare -b main "$REM"
DF="$SBX/dotfiles"; git init -q -b main "$DF"; git -C "$DF" remote add origin "$REM"
mkdir -p "$DF/shell"
echo "one"   > "$DF/shell/demo.txt"; gitq "$DF" add -A; gitq "$DF" commit -qm "commit1: initial"
C1="$(git -C "$DF" rev-parse HEAD)"
echo "two"  >> "$DF/shell/demo.txt"; gitq "$DF" commit -qam "commit2: local change"
git -C "$DF" push -q -u origin main
# an upstream commit the local doesn't have -> "update available"
UP="$SBX/upstream"; git clone -q "$REM" "$UP"
echo "three" >> "$UP/shell/demo.txt"; gitq "$UP" commit -qam "commit3: upstream feature"; git -C "$UP" push -q origin main
# uncommitted change -> "dirty"
echo "wip"  >> "$DF/shell/demo.txt"

# --- fake plugin checkout, one commit behind its remote -> "plugin update" -----
PREM="$SBX/plugin.git"; git init -q --bare -b main "$PREM"
PLUG="$SBX/custom/plugins/dotfiles-update"; mkdir -p "$(dirname "$PLUG")"
cp -R "$PLUGIN_SRC" "$PLUG"; rm -rf "$PLUG/.git" "$PLUG/demo"
git init -q -b main "$PLUG"; git -C "$PLUG" remote add origin "$PREM"
gitq "$PLUG" add -A; gitq "$PLUG" commit -qm "plugin"; git -C "$PLUG" push -q -u origin main
PUP="$SBX/plugin-upstream"; git clone -q "$PREM" "$PUP"
echo "# newer" >> "$PUP/CHANGELOG.md"; gitq "$PUP" commit -qam "newer plugin"; git -C "$PUP" push -q origin main

# --- pre-seed state: marker behind HEAD (-> not applied), stamps old (-> due) ---
CACHE="$SBX/cache"; mkdir -p "$CACHE"
echo "$C1" > "$CACHE/.dotfiles-installed"          # installed=commit1, HEAD=commit2
echo "LAST_EPOCH=0" > "$CACHE/.dotfiles-update"    # remote check due now
echo "LAST_EPOCH=0" > "$CACHE/.dotfiles-plugin-update"

if [ "${DEMO_SETUP_ONLY:-0}" = "1" ]; then echo "$SBX"; exit 0; fi

# --- generate an isolated zshrc and launch the demo shell ----------------------
cat > "$SBX/.zshrc" <<EOF
export ZSH="\$HOME/.oh-my-zsh"
export ZSH_CUSTOM="$SBX/custom"
export ZSH_CACHE_DIR="$CACHE"
export DOTFILES="$DF"
ZSH_THEME="robbyrussell"
DOTFILES_PACKAGES=(shell)
zstyle ':dotfiles:update' mode reminder
zstyle ':dotfiles:apply'  mode reminder
zstyle ':dotfiles:plugin' mode reminder
plugins=(dotfiles-update)
source "\$ZSH/oh-my-zsh.sh"
print -P "\n%F{244}dotfiles-update demo sandbox — try: dotfiles-update · dotfiles-apply · dotfiles-plugin-update · exit%f"
zshexit() { rm -rf "$SBX"; }
EOF

echo "Launching demo shell (type 'exit' to clean up)…"
exec env ZDOTDIR="$SBX" zsh -i
