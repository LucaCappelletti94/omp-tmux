# Navigator event loop

The first local snapshot starts a full draw. A visible spinner is a `Working` signal with a cell inside the rendered viewport, including while the work pane has focus. A filtered row, a clipped signal and an empty body have no spinner. Both deadlines use monotonic time.

| Event or job | No visible spinner | Visible spinner |
| --- | --- | --- |
| Metadata due, every two seconds | Read one snapshot | Read one snapshot even if animation is due |
| The `alert-bell` hook wakes this renderer with `F12` | Read a snapshot immediately, even under a modal | Same |
| Animation due | No deadline | Draw the current 100 ms frame of the ten-frame cycle. Skip missed frames |
| Wait for input | Until metadata is due | Until the earlier deadline |
| Search starts, changes or clears | Redraw the filtered view | Same |
| Arrow, page key or view toggle | Apply navigation and redraw | Same |
| `Enter` with a selection, or `Esc` with an empty query | Attempt the pane action, keep any error for display and sample metadata immediately | Same |
| `Enter` without a selection, key release or unrelated event | Ignore | Ignore |
| Resize | Redraw at the terminal size | Same |
| Dock loses its work pane | Exit | Exit |
| `Shift+Tab` | `tmux` focuses the dock from work or hides the focused dock. The header shows the available action | Same |
| Snapshot or terminal I/O fails | Return the error and restore the terminal if initialized | Same |

The first interior row of the roster shows the search field. An empty field hints at keyword or session ID search. The remaining rows hold results and controls as space permits. The dock receives typing only when focused. A focus change retains the query and editing state. The hardware cursor appears only while editing in the focused dock.

| Input | Idle field | Editing an empty field | Editing a nonempty field |
| --- | --- | --- | --- |
| `/` | Start editing | Append `/` | Append `/` |
| `?` | Open shortcut help | Append `?` | Append `?` |
| Other printable character without `Alt` or `Ctrl` | Start editing and append | Append | Append |
| `Backspace` | Ignore | Keep editing | Remove the last character |
| `Esc` | Return to work | Return to work | Clear the query and leave editing |
| Arrows, page keys, `Enter`, `Tab`, `Shift+Tab`, resize and timer jobs | Use the event table above | Same | Same |
| `Ctrl+b` then a window digit, or `Ctrl+b` then `'` | `tmux` handles window selection | Same | Same |

Matches are literal case-insensitive substrings of the group name, window number, title, description, directory, OMP session ID, notification tag or badge code. Typing an exact window number selects its entry among the matches. The session ID comes from [OMP’s terminal breadcrumb](https://github.com/can1357/oh-my-pi/blob/v19.1.1/docs/session.md#on-disk-layout) for the work pane. Looking up that ID’s optional notification record requires no scan of other sessions.

## Shortcut help

Help occupies the existing dock. It opens at the first shortcut and keeps the underlying selection, search text, group destination and description scroll position.

| Event or job | Roster | Editing search or a group destination | Help |
| --- | --- | --- | --- |
| `F1` | Open help | Open help | Return to the underlying view |
| `?` | Open help | Enter a literal question mark | Return to the underlying view |
| `Esc` | Use the current view’s binding | Use the field’s binding | Return without forwarding the key |
| `↑` / `↓`, `Page Up` / `Page Down`, `Home` / `End` | Use the roster bindings | Use the field’s bindings | Scroll one line, one screen or to either end. Stop at the first and last page |
| Other typing, `Enter` and dock commands | Use the roster bindings | Use the field’s bindings | Ignore. No command reaches the underlying view or a work pane |
| Resize or focus change | Recompute the viewport | Recompute the viewport and cursor | Wrap to the available width and clamp the scroll position. Hide the editing cursor |
| Metadata or bell update | Refresh the roster | Refresh and revalidate a pending move | Update the underlying view by the same rules. Keep help open at its scroll position |
| Animation | Paint visible working glyphs | Paint only visible working glyphs | Suspend spinner painting |
| `Shift+Tab`, prefix keys or dock removal | Use the native bindings and dock lifecycle | Same | Same. Closing the dock discards the open guide |

## Group navigation

Each identified OMP session belongs to at most one named group. Unassigned agents appear under **Ungrouped**. With no grouped local agents, the dock shows the ordinary flat list. Otherwise it shows nonempty named headings alphabetically, then **Ungrouped** if needed. Members keep their `tmux` window numbers and order. A heading takes one row in either view. Its collapse state belongs to the open dock. The header count counts matching agents, regardless of collapse.

| Event or job | Browse with an empty query | Search results | Move to group |
| --- | --- | --- | --- |
| `↑` or `↓` | Cycle through visible headings and agents | Cycle through matching agents | Cycle through available destinations |
| `←` or `→` | Collapse or expand the selected group. Collapsing a member selects its heading | Ignore | Ignore |
| `Enter` | Toggle a heading or open the selected agent | Open the selected agent | Recheck the original window, pane and OMP ID. Write only the membership, expand its destination and keep the moved agent selected if visible |
| `Ctrl+g` | On an identified agent, open its destination list. A missing ID explains why the agent cannot be moved. Ignore a heading | Same | Ignore |
| Printable text, `/`, `Backspace` | Use the search field | Search all members, including collapsed groups, in a flat list. A matching group name includes every local member | Edit the destination field. Offer matching saved names and creation of a valid new name |
| `Esc` | Return to the work pane | Clear the query, retain collapse choices | Cancel the move without changing membership, query or focus |
| `Tab`, page keys | Toggle view or scroll the selected agent’s description | Same | Ignore |
| Metadata refresh or external window switch | Keep the selection by window ID or heading name. Follow a newly active agent or its collapsed heading | Follow the existing search selection rules | Keep the original target. Cancel if it disappears, changes identity or the active window switches |
| `Ctrl+t` | Enter a flat triage view across all groups and select its first agent | Toggle triage ordering of matches | Ignore |
| `Ctrl+s` | Toggle live working messages for this `tmux` session. Refresh immediately | Same | Ignore |
| Focus change, resize or animation deadline | Redraw the visible view as needed. Animate only visible working agents | Same | Redraw the picker at the new size. Show no agent spinners |
| `Shift+Tab`, native `tmux` prefix keys, removal of the dock | Follow the dock lifecycle | Same | Same. Closing the dock discards any unconfirmed edit |
| Storage or validation failure | Keep navigation available and display the error | Same | Keep the picker open on a write failure. Never report an unconfirmed move |

`↑` on the first item selects the last and `↓` on the last selects the first. An empty list has no selection. A one-item list keeps its selection.

Membership lives under `$XDG_STATE_HOME/omp-tmux/groups`, with `~/.local/state/omp-tmux/groups` as the default. One file per OMP UUID lets different docks update unrelated sessions independently. Assignment replaces that UUID’s file atomically. Choosing **Ungrouped** removes it. No window or pane is moved, renamed or resized. A group is available while at least one saved membership uses its name, including sessions currently closed. The destination list reads those names when opened. Agent refreshes look up only the local roster. Group names are trimmed, case-sensitive text of up to 64 characters, excluding control characters and the reserved name **Ungrouped**.

Triage has two groups. Sessions requiring attention come first. An unread bell, a request for input or a reply, an urgent or crashed state, or manual priority all qualify. Within that group the most recent request or unread ping comes first, regardless of its kind. Other sessions follow from newest to oldest. Search applies the same order to its matches, including members of collapsed groups. Leaving triage restores the group headings and collapse choices.

The bell hook records each unread ping with a timestamp and a serial so repeated bells in one second stay ordered. When a request is already pending and its time is unknown, use session creation as its earliest possible time. For creation, prefer the OMP session timestamp, then the recorded `tmux` window creation time. Within each group, undated entries follow dated entries in descending numeric `tmux` window ID order. Renumbering a window does not change its age.

| Event or job | Grouped or ordinary roster | Triage, including filtered results | Group picker or help | Dock closed |
| --- | --- | --- | --- | --- |
| An inactive window rings, including another bell from an already flagged window | Record the bell and refresh the local roster | Move the matching session to the top immediately. Keep keyboard selection and work focus | Update the underlying roster without dismissing the view | Retain bell order in `tmux` for the next open |
| A session enters an attention state without a bell | Refresh the visible state on the metadata update | Rank the request with the other attention signals by recency | Update the underlying roster | Open using the available session and signal metadata |
| A bell is acknowledged or the attention state clears | Update the flags | Remove the cleared signal. Keep the session in the first group only if another signal still needs attention | Same for the underlying roster | Use the live flags on the next open |
| Typing, ordinary pane output, animation or a window renumber | Use normal roster order | Keep the attention order and session ages | Keep the current interaction | Do not invent a new signal |
| A session opens, disappears or the active window changes | Use the group navigation rules | Rebuild the two groups. Preserve an existing selection unless the user has switched windows | Revalidate a pending move | No renderer to wake |
| A bell belongs to a different session or a non-agent window | Exclude it from this roster | No unrelated entry is promoted | No change to the interaction | Do not open or focus a dock |

## Live working messages

Live messages are off by default. The per-session `@omp_dock_status_text` option keeps the choice when the navigator closes. `set -g @omp_dock_status_text on` enables it by default. In full and compact views, an available message appears immediately under its agent and wraps within the detail column. A group heading never has a status message.

| Event or job | Messages off | Messages on |
| --- | --- | --- |
| Metadata deadline | Do not capture any work panes | Sample the displayed viewport of local working OMP panes in one `tmux` batch. Recognize OMP’s working row next to its running footer |
| Input, focus or spinner frame | No status lookup | Reuse the last sample |
| Work begins, finishes or the working text changes | Render no status | Rebuild affected rows on the metadata refresh. Omit the line if the pane stops working or the working row is unavailable |
| Search, collapse, triage, resize or compact toggle | Lay out the current projection | Wrap the working text only on displayed agents and keep the selection, paging and spinner coordinates aligned |
| `Ctrl+s` from the roster | Enable and sample | Disable and drop the displayed messages |

The [OMP working row](https://github.com/can1357/oh-my-pi/blob/v19.1.1/packages/coding-agent/src/modes/interactive-mode.ts#L9246-L9264) carries the current tool or working message. The dock uses the rendered working row and never falls back to a line from the conversation or a prior Telegram summary.

| Viewport event | Compact | Full, selected detail fits | Full, selected detail overflows |
| --- | --- | --- | --- |
| Draw or resize | Show one heading per agent and its available working message when enabled | Measure the selected entry and as many preceding entries as fit. Fill the remainder below with headings and wrapped detail lines | Keep the selected heading at the top and fill the rest with detail starting at the clamped offset |
| `PageUp` or `PageDown` | Page through an overlong working message when shown | Keep the offset at zero | Move one wrapped line in the requested direction, stopping when the first or last line is visible |
| Selection changes | Follow the heading | Show the new selection from its first line | Same |
| Switch view, filter, metadata change or action error | Apply the invalidations below and lay out again | Same | Same |
| Search, focus, activation, resize and timer jobs | Use the event tables above | Same | Same |

Descriptions and directory fallbacks wrap at the text column on grapheme boundaries, preferring word breaks. Each entry costs a heading plus its wrapped lines. A viewport with room for only a heading keeps the selected heading visible. Spinner updates reuse the coordinates from the full draw.

| Change | Invalidation |
| --- | --- |
| Entry metadata changes | Rebuild matches for the retained query and retain the selected window ID if present. Follow an external current-window change when visible. Reset detail scroll if selection changes |
| Focus changes | Redraw the focus hint and query cursor. Keep selection and scroll |
| Query changes | Rebuild matches, prefer the selected window and reset detail scroll |
| Cursor moves | Reset detail scroll for the new selection |
| Size, detail scroll, view, search mode or action error changes | Recompute the visible headings and clamp detail scroll during the draw |
| Any full draw | Replace the list of visible spinner cells and the search cursor position. Arm animation only if a working glyph fits. Pane actions, group assignments and the live-status toggle bring the metadata deadline forward |
| Animation advances | Paint only the cached working cells and restore the search cursor. Keep the query, selection and snapshot |
| Snapshot unchanged | Keep the existing display and animation schedule |
