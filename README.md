# omp-tmux

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Live tmux tabs for [Oh My Pi](https://github.com/can1357/oh-my-pi) agents.

Oh My Pi continuously writes its state into the pane title as `π <sep> <label>`, where the label is the auto generated session title and the separator encodes run state: `>` idle, `!` waiting for your input, a braille spinner while working. Because the title travels through the pty, it always belongs to the pane that emitted it, so no agent can ever relabel another agent's window. This config derives the whole tab bar from that title: live truncated names, the spinner animating in the tab, a yellow `?` when an agent needs you, and a green `+` on windows whose agent finished or asked while you were in another window, raised by the terminal bell and cleared the moment you visit.

Source it from your `~/.tmux.conf`:

```
source-file ~/github/omp-tmux/omp-tmux.conf
```

Keep the Oh My Pi settings `completion.notify`, `ask.notify`, and `tui.titleState` at their defaults (all on), since the bell flag and the title states come from them. The config also turns the mouse off because tmux mouse capture breaks native text selection and link clicking, so remove that line if you prefer clickable tabs.

`prefix A` opens a small key table: `h` marks the current window high priority (purple `^` in the tab), `c` clears it, and `p`, `w`, `d` open pickers filtered to priority, waiting for input, and flagged windows.

Verified on tmux 3.4. The formats rely on the `m/r` regex modifier and on tmux redrawing the status line when a pane title changes, so older releases are unverified.
