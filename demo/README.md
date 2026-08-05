# Recording the demo GIF

`record-demo.sh` stages a throwaway sandbox that triggers **every** startup signal
(uncommitted, not-applied, update-available, plugin-update) and drops you into an
interactive zsh where opening the shell shows them. Everything lives in a temp dir and
is removed when you `exit`; your real `~/.claude`, `~/dotfiles`, and installed plugin are
never touched.

## One-time tooling

```sh
brew install asciinema agg   # agg converts the .cast recording to a .gif
```

## Record

```sh
# from the repo root
asciinema rec demo.cast -c "bash demo/record-demo.sh"
```

This starts recording, runs the demo, and drops you into the sandbox shell — the four
signals print as it launches. To show the tool doing something, type a few commands, then
`exit` (which stops the recording and cleans up the sandbox):

```
dotfiles-update          # pulls origin/main, then applies
dotfiles-apply           # restow + record installed commit
dotfiles-plugin-update   # fast-forward the plugin
exit
```

## Convert & embed

```sh
agg demo.cast demo/demo.gif
```

Then reference it near the top of the top-level `README.md`:

```md
![dotfiles-update in action](demo/demo.gif)
```

## Notes

- Signals run in **`reminder`** mode in the demo so nothing blocks on a prompt — good for
  showing the follow-up commands.
- The **changelog URL** line only appears when the remote is a GitHub repo; the sandbox
  uses a local bare remote, so it's omitted there. Against a real GitHub remote you'll see
  the `…/compare/<old>...<new>` link.
- For a clean frame, size your terminal (~90×24) and use a legible theme before recording.
