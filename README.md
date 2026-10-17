# omp-tmux

[![CI](https://github.com/LucaCappelletti94/omp-tmux/actions/workflows/ci.yml/badge.svg)](https://github.com/LucaCappelletti94/omp-tmux/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Live tmux status grid for [Oh My Pi](https://github.com/can1357/oh-my-pi) agents.

Oh My Pi keeps each pane title updated as `π <sep> <label>`, with `>` idle, `!` waiting for input and a braille spinner while working. Every window becomes a fixed-width cell showing that state, a purple `^` for manual priority, a green `+` for a bell you have not seen yet, its index and its live label. Titles travel through the pty, so no agent can ever relabel another's window.

Cells wrap onto extra status rows, up to five and never more than a fifth of the terminal height, above a summary row counting waiting agents, unseen bells and priority windows across the whole session. When the fleet still does not fit, the bar shows the page holding the current window. The layout follows resizes, attaching terminals and new, closed or moved windows by itself.

Source it from `~/.tmux.conf`:

```
source-file ~/github/omp-tmux/omp-tmux.conf
```

Keep the Oh My Pi settings `completion.notify`, `ask.notify`, and `tui.titleState` at their defaults. Set `@omp_max_rows` and `@omp_label_width` before sourcing to change the row cap and the label width, which default to `5` and `20`. `prefix A` marks window priority (`h` set, `c` clear), opens pickers showing each window's signals and full label (`p` priority, `w` waiting, `d` unseen bell), and `r` lays the bar out again after changing a setting.

The layout helper in `scripts/` needs `sh`, `awk` and `pkill`. Mouse is off because tmux mouse capture breaks native selection, drop that line if you prefer clickable tabs. CI runs the tests on tmux 3.2a through 3.8 on Linux, on Alpine with BusyBox, and on Homebrew's tmux on macOS.
