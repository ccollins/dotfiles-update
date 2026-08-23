# Recording the demo GIF and the banner still

`record-demo.sh` stages a throwaway sandbox that triggers **every** startup signal
(uncommitted, not-applied, update-available, plugin-update) and drops you into an
interactive zsh where opening the shell shows them. Everything lives in a temp dir and
is removed when you `exit`; your real `~/.claude`, `~/dotfiles`, and installed plugin are
never touched.

## One-time tooling

```sh
brew install asciinema agg   # agg converts the .cast recording to a .gif
brew install imagemagick     # only for the banner still (padding), below
```

## Record

### Recommended — auto mode (deterministic, tight framing)

```sh
# from the repo root
asciinema rec demo.cast --overwrite --window-size 92x16 -c "bash demo/record-demo.sh --auto"
```

Plays a fixed sequence — the four startup signals, then `dotfiles status` — and exits on
its own (stopping the recording and cleaning up the sandbox). No typing, and the fixed
`--window-size` avoids the empty rows a taller terminal would leave. Bump the rows a touch
if anything clips.

### Interactive (explore / custom takes)

```sh
asciinema rec demo.cast --overwrite --window-size 92x18 -c "bash demo/record-demo.sh"
```

Drops you into the sandbox shell showing the four signals; try a few commands, then `exit`:

```
dotfiles status          # on-demand state of every axis
dotfiles doctor          # health check
dotfiles-update          # pulls origin/main, then applies
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

## The banner still (`demo/banner.png`)

The README's banner section shows a picture rather than a plain code block, so the
rainbow actually reads. Same tooling, one frame:

```sh
# from the repo root
TERM=xterm-256color asciinema rec /tmp/banner.cast --overwrite --window-size 61x11 \
  -c "bash -c \"printf '\033[?25l'; bin/dotfiles-banner \
     --tagline 'your Mac, exactly as you left it' \
     'applied at a0db87a · 7 packages restowed'\""
agg --quiet --select 100% /tmp/banner.cast /tmp/banner.gif
magick /tmp/banner.gif -bordercolor '#282a36' -border 20x10 demo/banner.png
```

Why each bit:

- **`61x11`** is the banner's exact width (61 columns) and height, so nothing wraps and
  no empty rows are left over.
- **`printf '\033[?25l'`** hides the cursor, which would otherwise be captured as a
  block in the bottom-left corner.
- **`--select 100%`** renders only the final frame — a still, not an animation.
- **`magick … -border`** adds breathing room in agg's own background color
  (`#282a36`, the same theme as `demo.gif`); agg has no padding option.

Re-shoot it whenever the art, the message line, or the taglines change.

## Notes

- Signals run in **`reminder`** mode in the demo so nothing blocks on a prompt — good for
  showing the follow-up commands.
- The **changelog URL** line only appears when the remote is a GitHub repo; the sandbox
  uses a local bare remote, so it's omitted there. Against a real GitHub remote you'll see
  the `…/compare/<old>...<new>` link.
- For a clean frame, size your terminal (~90×24) and use a legible theme before recording.
