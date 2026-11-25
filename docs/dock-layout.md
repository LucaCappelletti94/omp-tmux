# Dock layout

An open dock reserves a full-height left pane in each suitable window of its session. A suitable window has a single link, is unzoomed and is at least 76 columns wide. The reservation is 40 columns plus its border. One pane runs the navigator. Other reservations are empty `tmux` panes with no child process. The session records the renderer’s pane ID. Work panes keep their identities and their positions relative to each other.

The rounded frame sits inside the 40-column reservation. Its top edge carries the view, match count and focus shortcut. The outline brightens when the dock has focus.

| Event or job | Grid selected | Navigator hidden | Navigator open |
| --- | --- | --- | --- |
| Open or focus | Temporarily hide the grid and prepare the session. Select navigator mode on success. Restore the original status setting if preparation fails | Prepare and focus the navigator if suitable. Keep the grid off | Reconcile and focus the renderer if suitable |
| Hide via shortcut or menu | The shortcut opens the navigator in a session with an OMP window | Reopen the navigator | Select the active work pane or the last work pane if the dock had focus. Leave copy mode only in that pane. Release reservations and keep the grid off |
| Select a window | Use native window selection | Same | In a suitable window, swap in the renderer without resizing work. Close in an unsuitable window and keep the grid off |
| Create a window, attach or resize a client | Refresh the grid | Leave the workspace alone | Reconcile background reservations without selecting them. Skip linked, zoomed and narrow windows. Close if the current window is unsuitable |
| Work pane exits or is killed | Use native pane removal | Same | Remove a reservation that has lost its last work pane and allow its window to retire |
| Renderer or hosting window disappears | Ignore | Ignore | Start a renderer for the current suitable window. Keep other reservations |
| Metadata refresh | No renderer | No renderer | Reconcile a lone reservation or a missing reservation in a prepared window |
| Grid refresh, detach or config reload | Publish only the current grid request | Skip grid publication | Skip grid publication. Reuse the renderer and reservations on reconciliation |
| Show the bar in the menu | Show the grid | Select grid mode and request a fresh layout | Unavailable |

The grid, dock and paired view share hook index `100` for each `tmux` event they handle. Reloading the plugin leaves commands at other hook indices alone.

Opening the navigator invalidates outstanding grid requests. Its first successful launch sets the session’s `@omp_bar` to `dock`. Only an explicit choice of the grid changes that preference. A hide leaves the selection, copy-mode position and history of other work panes alone.

Preparation uses the client viewport for automatic window sizing and retains a manual window’s own dimensions. Writing a background window’s size temporarily sets `window-size` to `manual`, so the same command batch restores the explicit policy or removes the temporary override to resume inheritance. A real viewport resize may resize work. Selecting between prepared windows only exchanges the two left panes.

Restoration removes only reservations owned by the session. A saved work layout can be reapplied when the reserved layout is intact. User splits, resizes and pane replacements invalidate that saved layout. In that case `tmux` redistributes the released space in the current layout. A zoomed work pane keeps its zoom when its reservation is removed. Session closure discards its dock state.

Hiding a real split returns its width to the work application. OMP’s [`tui.resizeScrollback`](https://github.com/can1357/oh-my-pi/blob/v19.1.1/packages/coding-agent/src/modes/settings.ts#L373-L395) setting controls that redraw. `preserve` paints only the live viewport and leaves the transcript in scrollback at its existing wrapping. The dock does not clear history or send a key to the foreground application.

## Paired sessions

`Ctrl+p` in the dock opens the current work window and a different highlighted agent in a temporary two-pane window in the same `tmux` session. Each pane runs an interactive `tmux` client on a private session linked only to its original work window. Work processes, original pane IDs, window numbers and scrollback stay in place. The two views use the available terminal dimensions. Opening a pair can therefore resize a work application. There is no background viewer when the pair is closed.

| Event | Ordinary window | Paired view |
| --- | --- | --- |
| Pair shortcut | Resolve two distinct live OMP work windows in this session. Reject missing agents, a heading or the same window. Start the view side by side | One pair per source session |
| `Ctrl+b`, then `o` | Native next pane | Cycle between the two interactive views |
| `Ctrl+b`, then `Space` | Native next layout or the existing custom binding | With the default binding, alternate columns and rows. A custom binding retains its action |
| `Shift+Tab` | Normal dock action | Close the view and return to a source window. Restore access to the dock |
| Select a different window by number | Native selection | Keep the selected window and release the pair |
| Close a view, source window or session | Native lifecycle | Retire the pair and its private sessions. Only the original work windows own the agents |
| Resize or attach | Normal dock reconciliation | Let `tmux` resize the two views. Give neither view a navigator reservation or duplicate grid |
| Setup error or unavailable second agent | Keep the source windows and report the reason | Remove only resources created for this pair |
