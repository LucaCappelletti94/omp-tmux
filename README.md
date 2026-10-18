# omp-tmux

[![CI](https://github.com/LucaCappelletti94/omp-tmux/actions/workflows/ci.yml/badge.svg)](https://github.com/LucaCappelletti94/omp-tmux/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Live tmux status grid for [Oh My Pi](https://github.com/can1357/oh-my-pi) agents.

Oh My Pi keeps each pane title updated as `π <sep> <label>`, with `>` idle, `!` waiting for input and a braille spinner while working. Every window becomes a fixed-width cell showing that state, waiting as soon as any of its panes waits, a purple `^` for manual priority, a green `+` for a bell you have not seen yet, its index and its live label. Titles travel through the pty, so no agent can ever relabel another's window.

Cells wrap onto extra status rows, up to five and never more than a fifth of the terminal height, above a summary row counting waiting agents, unseen bells and priority windows across the whole session. When the fleet still does not fit, the bar shows the page holding the current window. The layout follows resizes, attaching terminals and new, closed or moved windows by itself.

Source it from `~/.tmux.conf`, or install it with [TPM](https://github.com/tmux-plugins/tpm) as `set -g @plugin 'LucaCappelletti94/omp-tmux'`:

```
source-file ~/github/omp-tmux/omp-tmux.conf
```

Keep the Oh My Pi settings `completion.notify`, `ask.notify`, and `tui.titleState` at their defaults. `prefix A` opens a menu that marks priority (`h` set, `c` clear), opens pickers showing each window's signals and full label (`w` waiting, `d` unseen bell, `p` priority), hides or shows the bar (`s`) and lays it out again (`r`).

`@omp_max_rows` (`5`), `@omp_label_width` (`20`), `@omp_key` (`A`) and the styles `@omp_style_waiting`, `@omp_style_bell`, `@omp_style_priority`, `@omp_style_working`, `@omp_style_muted` and `@omp_style_current` take effect when set before sourcing. omp-tmux owns the whole status bar, so `status-left` and `status-right` do not show. It leaves the mouse alone, best kept off for native selection and link clicking.

The layout helper in `scripts/` needs `sh`, `awk` and `pkill`. CI runs the tests on tmux 3.2a through 3.8 on Linux, on Alpine with BusyBox, and on Homebrew's tmux on macOS.
