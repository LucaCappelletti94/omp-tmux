# omp-tmux

[![CI](https://github.com/LucaCappelletti94/omp-tmux/actions/workflows/ci.yml/badge.svg)](https://github.com/LucaCappelletti94/omp-tmux/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE) [![Codacy](https://app.codacy.com/project/badge/Grade/8fe3849717f94c82ad2f8236f7bd3e91)](https://app.codacy.com/gh/LucaCappelletti94/omp-tmux/dashboard)

Live tmux tabs for [Oh My Pi](https://github.com/can1357/oh-my-pi) agents.

Oh My Pi keeps each pane title updated as `π <sep> <label>`: `>` idle, `!` waiting for input, a braille spinner while working. This config turns those titles into the whole tab bar: live names, the spinner animating in the tab, a yellow `?` when an agent needs you, a green `+` when one finished while you were away (cleared the moment you visit), and a numbered fleet strip at the right showing every agent at a glance. Titles travel through the pty, so no agent can ever relabel another's window.

Source it from `~/.tmux.conf`:

```
source-file ~/github/omp-tmux/omp-tmux.conf
```

Keep the Oh My Pi settings `completion.notify`, `ask.notify`, and `tui.titleState` at their defaults. `prefix A` marks window priority (`h` set, `c` clear) and opens pickers (`p` priority, `w` waiting, `d` flagged). Mouse is off because tmux mouse capture breaks native selection, drop that line if you prefer clickable tabs. Verified on tmux 3.4.
