# Session navigator shortcuts

From an OMP work pane, press `Shift+Tab`, type part of a title or a window number, then press `Enter`. The selected agent gets the keyboard at its live prompt. The dock lists OMP windows from the current `tmux` session.

Keys in the dock work directly. A footer hint such as `^G` means `Ctrl+g`. For a shortcut written as `Ctrl+b` **then** another key, press and release `Ctrl+b` first. Substitute your own `tmux` prefix if you changed it.

Press `?` in the dock to open the shortcut menu. `F1` also opens it while typing a search or group name. Use `↑` / `↓` to scroll one line, `Page Up` / `Page Down` to scroll a screen, and `Home` / `End` to jump. Press `Esc`, `?` or `F1` to return to the same selection and text. To search for a literal `?`, start the search with `/`.

## Find an agent and return to work

| Key | What it does |
| --- | --- |
| `Shift+Tab` | From work, open or focus the dock. From the focused dock, hide it and return to work. |
| Type, or press `/` and type | Search titles, descriptions, group names, directories, window numbers and OMP session IDs. Notification tags and badge codes also match when available. An exact window number takes priority. |
| `Backspace` | Remove one character from the search. |
| `↑` / `↓` | Move through the list. Up from the first item wraps to the last, and down from the last wraps to the first. |
| `Enter` | Open the highlighted agent. On a group heading, collapse or expand it. |
| `Esc` | Clear a nonempty search. With an empty search, return to work and leave the dock visible. |
| `Tab` | Switch between full, wrapped descriptions and compact headings. |
| `Page Up` / `Page Down` | Scroll an overlong description or live message one wrapped line at a time. |

## Group sessions and find the ones needing attention

| Key | What it does |
| --- | --- |
| `Ctrl+g` | Move the highlighted agent. Pick a saved group with `↑` / `↓`, type a new name and choose **Create**, or choose **Ungrouped** to remove it. `Enter` confirms and `Esc` cancels. |
| `←` / `→` | Collapse or expand a group in the unfiltered group list. Search finds members even when their group is collapsed. |
| `Ctrl+t` | Toggle triage across all groups. Sessions needing attention come first, with the newest request or unread ping at the top. Other sessions follow from newest to oldest. |
| `Ctrl+s` | Show or hide each running agent’s current working message beneath its title. This works in either view. The option starts off and is remembered for this `tmux` session. |

An unread bell, a request for input or a reply, an urgent or crashed state, or manual priority counts as needing attention. A fresh ping can bring an older session to the top without moving the keyboard selection or switching work panes. Opening the window acknowledges its bell. Any remaining request keeps it in the attention group.

When the dock opens on several requests that were already pending and have no recorded time, it orders those by session age. A known OMP creation time follows the session when it resumes. For agents without one, the dock uses the window’s creation order.

For example, put windows `10` and `18` in **Spectra** by assigning each agent with `Ctrl+g`. Both window numbers stay the same. Membership follows the OMP session ID if an agent resumes in a different window. An agent needs a known OMP session ID to join a group.

## Use two live prompts

From the first agent, focus the dock with `Shift+Tab` and highlight a **different** agent. Press `Ctrl+p` to open the pair side by side. Both prompts accept input, and their original windows keep their numbers.

| Key in the paired view | What it does |
| --- | --- |
| `Ctrl+b` then `o` | Move keyboard focus to the other prompt. |
| `Ctrl+b` then `Space` | Switch between side-by-side and stacked layouts with the default `tmux` binding. |
| `Shift+Tab` | Close the pair and return to the source window for the focused prompt. Selecting a different numbered window also closes the pair. |

## Jump by number or open the agent menu

These default `tmux` shortcuts work with the dock visible or hidden.

| Keys | What they do |
| --- | --- |
| `Ctrl+b` then `3` | Jump straight to window `3`. Use any single window digit. |
| `Ctrl+b` then `'`, type `18`, press `Enter` | Jump to a multi-digit window without searching. |
| `Ctrl+b` then `Shift+a` | Open the agent menu. Choose `f` to focus the dock or `l` to open or close it. |

In the agent menu, `u` lists urgent windows, `w` waiting windows, `d` unseen bells, `p` manual priority and `x` completed windows. Use `h` to mark the current window as a priority or `c` to clear it. `/` searches window labels and directories on `tmux` 3.3 or later. To use the bottom grid, hide the dock and select **Show the bar** (`s`). Use `r` to lay out the grid again.
