mod help;
mod roster;

use std::io::{self, Write};
use std::time::{Duration, Instant};

use crossterm::event::{
    self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseButton, MouseEventKind,
};
use ratatui::backend::Backend;
use ratatui::buffer::Cell;
use ratatui::layout::{Position, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::Span;
use ratatui::widgets::{Block, BorderType, Paragraph};
use ratatui::{DefaultTerminal, Frame};

use self::help::Help;
use self::roster::{group_label, Roster, Row};
use crate::group_picker::{GroupPicker, PickerAction};
use crate::tmux::{Activity, Entry, Server, Snapshot, ViewSetting};

const REFRESH: Duration = Duration::from_secs(2);

struct MouseButtons {
    enabled: bool,
}

impl MouseButtons {
    const DISABLE: &[u8] = b"\x1b[?1000l\x1b[?1006l";

    fn enable() -> io::Result<Self> {
        let guard = Self { enabled: true };
        // VT button tracking with SGR coordinates avoids reporting pointer motion.
        Self::send(b"\x1b[?1006h\x1b[?1000h")?;
        Ok(guard)
    }

    fn disable(mut self) -> io::Result<()> {
        Self::send(Self::DISABLE)?;
        self.enabled = false;
        Ok(())
    }

    fn send(sequence: &[u8]) -> io::Result<()> {
        let mut output = io::stdout().lock();
        output.write_all(sequence)?;
        output.flush()
    }
}

impl Drop for MouseButtons {
    fn drop(&mut self) {
        if self.enabled {
            let _ = Self::send(Self::DISABLE);
        }
    }
}

const SPINNER: [&str; 10] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

fn spinner_frame(elapsed: Duration) -> (&'static str, Duration) {
    const FRAME_NANOS: u32 = 100_000_000;
    let phase = elapsed.subsec_nanos();
    let index = usize::try_from(phase / FRAME_NANOS).expect("ten frames fit in usize");
    (
        SPINNER[index],
        Duration::from_nanos(u64::from(FRAME_NANOS - phase % FRAME_NANOS)),
    )
}

#[derive(Default)]
struct Spinners {
    cells: Vec<(Position, Cell)>,
    cursor: Option<Position>,
}

impl Spinners {
    fn paint(&mut self, backend: &mut impl Backend, glyph: &str) -> io::Result<()> {
        backend.draw(self.cells.iter_mut().map(|(position, cell)| {
            cell.set_symbol(glyph);
            (position.x, position.y, &*cell)
        }))?;
        if let Some(cursor) = self.cursor {
            backend.set_cursor_position(cursor)?;
        }
        backend.flush()
    }
}

fn control_key(key: KeyEvent, character: char) -> bool {
    key.code == KeyCode::Char(character) && key.modifiers == KeyModifiers::CONTROL
}

fn matches(entry: &Entry, needle: &str) -> bool {
    needle.is_empty()
        || [
            group_label(&entry.group),
            &entry.title,
            &entry.description,
            &entry.directory,
            &entry.index,
            &entry.session_id,
            &entry.session_code,
            &entry.session_tag,
        ]
        .into_iter()
        .any(|field| {
            if field.is_ascii() {
                field
                    .as_bytes()
                    .windows(needle.len())
                    .any(|part| part.eq_ignore_ascii_case(needle.as_bytes()))
            } else {
                field.to_lowercase().contains(needle)
            }
        })
}

struct Navigator {
    snapshot: Snapshot,
    roster: Roster,
    picker: Option<GroupPicker>,
    help: Option<Help>,
    cursor: usize,
    clickable: Vec<(Rect, usize)>,
    detail_offset: usize,
    query: String,
    filtering: bool,
    compact: bool,
    error: Option<String>,
}

enum Input {
    Ignore,
    Redraw,
    Refresh,
    SaveView(ViewSetting),
    Assign(Option<String>),
}

impl Navigator {
    fn new(snapshot: Snapshot) -> Self {
        let current = if snapshot.view.triage {
            None
        } else {
            snapshot
                .entries
                .iter()
                .position(|entry| entry.current)
                .map(Row::Agent)
        };
        let mut roster = Roster::default();
        roster.observe(&snapshot.entries);
        roster.index_groups(&snapshot.entries);
        let mut navigator = Self {
            snapshot,
            roster,
            picker: None,
            help: None,
            cursor: 0,
            clickable: Vec::new(),
            detail_offset: 0,
            query: String::new(),
            filtering: false,
            compact: false,
            error: None,
        };
        navigator.rebuild(current);
        navigator
    }

    fn selected_row(&self) -> Option<Row> {
        self.roster.rows.get(self.cursor).copied()
    }

    fn selection(&self) -> Option<&Entry> {
        self.selected_row()?.member(&self.snapshot.entries)
    }

    fn rebuild(&mut self, preferred: Option<Row>) {
        self.roster
            .project(&self.snapshot.entries, &self.query, &self.snapshot.view);
        self.cursor = preferred
            .and_then(|row| self.roster.position(row, &self.snapshot.entries))
            .unwrap_or_else(|| self.cursor.min(self.roster.rows.len().saturating_sub(1)));
    }

    fn reset_projection(&mut self, preferred: Option<Row>) {
        self.cursor = 0;
        self.detail_offset = 0;
        self.rebuild(preferred);
    }

    fn filter(&mut self) {
        self.reset_projection(self.selected_row());
        if self
            .query
            .starts_with(|character: char| character.is_ascii_digit())
        {
            if let Some(position) = self.roster.rows.iter().position(|&row| {
                row.member(&self.snapshot.entries)
                    .is_some_and(|entry| entry.index == self.query)
            }) {
                self.cursor = position;
            }
        }
    }

    fn refresh(&mut self, snapshot: Snapshot) -> bool {
        let switched = self.snapshot.active_window != snapshot.active_window;
        let entries_changed = self.snapshot.entries != snapshot.entries;
        let view_changed = self.snapshot.view != snapshot.view;
        if !entries_changed
            && !view_changed
            && !switched
            && self.snapshot.focused == snapshot.focused
            && self.snapshot.status_text == snapshot.status_text
            && self.snapshot.group_error == snapshot.group_error
        {
            return false;
        }
        if let Some(picker) = &self.picker {
            let (window, pane, session) = picker.target();
            if switched
                || (entries_changed
                    && !snapshot.entries.iter().any(|entry| {
                        entry.window_id == window
                            && entry.pane_id == pane
                            && entry.session_id == session
                    }))
            {
                self.picker = None;
                self.error = Some(
                    if switched {
                        "Move canceled. Active window changed."
                    } else {
                        "Move canceled. Target agent changed."
                    }
                    .into(),
                );
            }
        }
        let previous = std::mem::replace(&mut self.snapshot, snapshot);
        let retained = if entries_changed {
            self.selected_row()
                .and_then(|row| row.retain(&previous.entries, &self.snapshot.entries))
        } else {
            self.selected_row()
        };
        if entries_changed {
            self.roster.observe(&self.snapshot.entries);
            if !previous.entries.iter().map(|entry| &entry.group).eq(self
                .snapshot
                .entries
                .iter()
                .map(|entry| &entry.group))
            {
                self.roster.index_groups(&self.snapshot.entries);
            }
        }
        if entries_changed || view_changed {
            if view_changed {
                let entering_triage = self.snapshot.view.triage && !previous.view.triage;
                self.reset_projection(if entering_triage { None } else { retained });
            } else {
                self.rebuild(retained);
            }
            if switched {
                if let Some(position) = self
                    .snapshot
                    .entries
                    .iter()
                    .position(|entry| entry.current)
                    .and_then(|index| {
                        self.roster
                            .position(Row::Agent(index), &self.snapshot.entries)
                    })
                {
                    self.cursor = position;
                }
            }
            if self.selected_row() != retained {
                self.detail_offset = 0;
            }
        }
        true
    }

    fn move_by(&mut self, distance: isize) {
        let count = self.roster.rows.len();
        if count < 2 {
            return;
        }
        let steps = distance.unsigned_abs() % count;
        let next = if distance < 0 {
            (self.cursor + count - steps) % count
        } else {
            (self.cursor + steps) % count
        };
        if self.cursor != next {
            self.cursor = next;
            self.detail_offset = 0;
        }
    }

    fn fold_group(&mut self, row: Row, expand: bool) -> Input {
        let group = row.group(&self.snapshot.entries);
        let changed = if expand {
            self.roster.expand(group)
        } else {
            self.roster.collapse(group)
        };
        if !changed {
            return Input::Ignore;
        }
        self.detail_offset = 0;
        self.rebuild(Some(row));
        self.error = None;
        Input::Redraw
    }

    fn assign(&mut self, server: &Server, name: Option<&str>) -> io::Result<bool> {
        let Some(snapshot) = server.snapshot()? else {
            return Ok(false);
        };
        self.refresh(snapshot);
        let Some(picker) = self.picker.take() else {
            return Ok(true);
        };
        let (window, pane, session) = picker.target();
        if let Err(error) = server.move_to_group(window, pane, session, name) {
            self.error = Some(error.to_string());
            self.picker = Some(picker);
            return Ok(true);
        }
        self.error = None;
        let Some(snapshot) = server.snapshot()? else {
            return Ok(false);
        };
        let switched = self.snapshot.active_window != snapshot.active_window;
        self.refresh(snapshot);
        if self.roster.expand(name.unwrap_or_default())
            && self.roster.grouped(&self.query, &self.snapshot.view)
        {
            self.rebuild(self.selected_row());
        }
        if !switched {
            if let Some(position) = self.roster.rows.iter().position(|&row| {
                row.member(&self.snapshot.entries).is_some_and(|entry| {
                    entry.window_id == window
                        && entry.pane_id == pane
                        && entry.session_id == session
                })
            }) {
                if self.cursor != position {
                    self.cursor = position;
                    self.detail_offset = 0;
                }
            }
        }
        Ok(true)
    }

    fn change_view(&mut self, setting: ViewSetting) -> Input {
        let mut preferred = self.selected_row();
        let view = &mut self.snapshot.view;
        match setting {
            ViewSetting::Triage => {
                view.triage = !view.triage;
                if view.triage {
                    preferred = None;
                }
            }
            ViewSetting::Group => {
                view.group = if view.group.is_some() {
                    None
                } else {
                    let Some(row) = preferred else {
                        return Input::Ignore;
                    };
                    Some(row.group(&self.snapshot.entries).to_owned())
                };
            }
            ViewSetting::AttentionOnly => view.attention_only = !view.attention_only,
        }
        self.reset_projection(preferred);
        self.error = None;
        Input::SaveView(setting)
    }

    fn open_row(&mut self, position: usize, server: &Server) -> Input {
        let Some(&row) = self.roster.rows.get(position) else {
            return Input::Ignore;
        };
        if self.cursor != position {
            self.cursor = position;
            self.detail_offset = 0;
        }
        match row {
            Row::Group(_) => self.fold_group(
                row,
                self.roster.is_collapsed(row.group(&self.snapshot.entries)),
            ),
            Row::Agent(index) => {
                self.error = server
                    .activate(&self.snapshot.entries[index])
                    .err()
                    .map(|error| error.to_string());
                Input::Refresh
            }
        }
    }

    fn click(&mut self, point: Position, server: &Server) -> Input {
        let Some(&(_, position)) = self.clickable.iter().find(|(area, _)| area.contains(point))
        else {
            return Input::Ignore;
        };
        self.open_row(position, server)
    }

    fn key(&mut self, key: KeyEvent, server: &Server) -> Input {
        let function_help = key.code == KeyCode::F(1) && key.modifiers.is_empty();
        let question =
            key.code == KeyCode::Char('?') && KeyModifiers::SHIFT.contains(key.modifiers);
        if let Some(help) = &mut self.help {
            if function_help || question || (key.code == KeyCode::Esc && key.modifiers.is_empty()) {
                self.help = None;
                return Input::Redraw;
            }
            return if key.modifiers.is_empty() && help.scroll(key.code) {
                Input::Redraw
            } else {
                Input::Ignore
            };
        }
        if function_help || (question && !self.filtering && self.picker.is_none()) {
            self.help = Some(Help::default());
            return Input::Redraw;
        }
        if let Some(picker) = &mut self.picker {
            return match picker.key(key) {
                PickerAction::Ignore => Input::Ignore,
                PickerAction::Cancel => {
                    self.picker = None;
                    self.error = None;
                    Input::Redraw
                }
                PickerAction::Redraw => {
                    self.error = None;
                    Input::Redraw
                }
                PickerAction::Assign(name) => Input::Assign(name),
            };
        }
        if control_key(key, 's') {
            self.error = server
                .set_status_text(!self.snapshot.status_text)
                .err()
                .map(|error| error.to_string());
            return Input::Refresh;
        }
        if control_key(key, 'p') {
            let Some(entry) = self.selection() else {
                return Input::Ignore;
            };
            self.error = server.pair_with(entry).err().map(|error| error.to_string());
            return Input::Refresh;
        }
        if control_key(key, 'g') {
            let Some(entry) = self.selection() else {
                return Input::Ignore;
            };
            if !crate::identity::valid_uuid(&entry.session_id) {
                self.error = Some("No session ID. Open a live OMP agent.".into());
            } else {
                match server.group_names() {
                    Ok(names) => {
                        self.picker = Some(GroupPicker::new(entry, names));
                        self.error = None;
                    }
                    Err(error) => self.error = Some(error.to_string()),
                }
            }
            return Input::Redraw;
        }
        if key.modifiers == KeyModifiers::CONTROL {
            match key.code {
                KeyCode::Char('t') => return self.change_view(ViewSetting::Triage),
                KeyCode::Char('f') => return self.change_view(ViewSetting::Group),
                KeyCode::Char('a') => return self.change_view(ViewSetting::AttentionOnly),
                _ => {}
            }
        }
        match key.code {
            KeyCode::Up => self.move_by(-1),
            KeyCode::Down => self.move_by(1),
            KeyCode::Left | KeyCode::Right
                if self.roster.grouped(&self.query, &self.snapshot.view) =>
            {
                let Some(row) = self.selected_row() else {
                    return Input::Ignore;
                };
                return self.fold_group(row, key.code == KeyCode::Right);
            }
            KeyCode::PageUp => self.detail_offset = self.detail_offset.saturating_sub(1),
            KeyCode::PageDown => self.detail_offset = self.detail_offset.saturating_add(1),
            KeyCode::Tab => self.compact = !self.compact,
            KeyCode::Enter => return self.open_row(self.cursor, server),
            KeyCode::Esc if self.query.is_empty() => {
                self.filtering = false;
                self.error = server.leave().err().map(|error| error.to_string());
                return Input::Refresh;
            }
            KeyCode::Esc => {
                self.filtering = false;
                self.query.clear();
                self.filter();
            }
            KeyCode::Backspace if self.filtering => {
                self.query.pop();
                self.filter();
            }
            KeyCode::Char('/') if !self.filtering && key.modifiers.is_empty() => {
                self.filtering = true;
            }
            KeyCode::Char(character)
                if !character.is_control()
                    && !key
                        .modifiers
                        .intersects(KeyModifiers::ALT | KeyModifiers::CONTROL) =>
            {
                self.filtering = true;
                self.query.push(character);
                self.filter();
            }
            _ => return Input::Ignore,
        }
        self.error = None;
        Input::Redraw
    }
}

pub(crate) fn run(server: &Server) -> io::Result<()> {
    let Some(snapshot) = server.snapshot()? else {
        return Ok(());
    };
    let result = ratatui::try_init().and_then(|mut terminal| {
        let buttons = MouseButtons::enable()?;
        navigate(&mut terminal, server, Navigator::new(snapshot)).and(buttons.disable())
    });
    result.and(ratatui::try_restore())
}

fn navigate(
    terminal: &mut DefaultTerminal,
    server: &Server,
    mut navigator: Navigator,
) -> io::Result<()> {
    let mut redraw = true;
    let started = Instant::now();
    let mut refresh_at = started + REFRESH;
    let mut animate_at = None;
    let mut spinners = Spinners::default();
    loop {
        if Instant::now() >= refresh_at {
            let Some(snapshot) = server.snapshot()? else {
                return Ok(());
            };
            redraw |= navigator.refresh(snapshot);
            refresh_at = Instant::now() + REFRESH;
        }
        if redraw {
            terminal.draw(|frame| navigator.draw(frame, &mut spinners))?;
        }
        let now = Instant::now();
        if spinners.cells.is_empty() {
            animate_at = None;
        } else if redraw || animate_at.is_some_and(|deadline| now >= deadline) {
            let (glyph, remaining) = spinner_frame(now - started);
            spinners.paint(terminal.backend_mut(), glyph)?;
            animate_at = Some(now + remaining);
        }
        let deadline = animate_at.map_or(refresh_at, |animation| refresh_at.min(animation));
        redraw = false;
        if !event::poll(deadline.saturating_duration_since(Instant::now()))? {
            continue;
        }
        let input = match event::read()? {
            Event::Resize(_, _) => {
                redraw = true;
                continue;
            }
            Event::Key(key)
                if key.kind != KeyEventKind::Release
                    && key.code == KeyCode::F(12)
                    && key.modifiers.is_empty() =>
            {
                refresh_at = Instant::now();
                continue;
            }
            Event::Key(key) if key.kind != KeyEventKind::Release => navigator.key(key, server),
            Event::Mouse(mouse)
                if mouse.kind == MouseEventKind::Down(MouseButton::Left)
                    && mouse.modifiers.is_empty() =>
            {
                navigator.click(Position::new(mouse.column, mouse.row), server)
            }
            _ => continue,
        };
        match input {
            Input::Ignore => {}
            Input::Redraw => redraw = true,
            Input::Refresh => {
                refresh_at = Instant::now();
                redraw = true;
            }
            Input::SaveView(setting) => {
                if let Err(error) = server.save_view_setting(&navigator.snapshot.view, setting) {
                    navigator.error = Some(format!("Could not save dock view ({error})"));
                    refresh_at = Instant::now();
                } else if navigator.snapshot.status_text && !matches!(setting, ViewSetting::Triage)
                {
                    refresh_at = Instant::now();
                }
                redraw = true;
            }
            Input::Assign(name) => {
                if !navigator.assign(server, name.as_deref())? {
                    return Ok(());
                }
                refresh_at = Instant::now() + REFRESH;
                redraw = true;
            }
        }
    }
}

const ACCENT: Color = Color::LightCyan;
const MUTED: Color = Color::Gray;

fn take_rows(area: &mut Rect, count: u16) -> Rect {
    let height = count.min(area.height);
    let rows = Rect::new(area.x, area.y, area.width, height);
    area.y += height;
    area.height -= height;
    rows
}

fn inset(area: Rect, columns: u16) -> Rect {
    let columns = columns.min(area.width);
    Rect::new(area.x + columns, area.y, area.width - columns, area.height)
}

fn tone(color: Color) -> Style {
    Style::default().fg(color)
}

fn signal(activity: Activity) -> (&'static str, Color) {
    match activity {
        Activity::Urgent => ("!", Color::LightRed),
        Activity::Crashed => ("✗", Color::LightRed),
        Activity::Waiting => ("?", Color::LightYellow),
        Activity::Working => (SPINNER[0], ACCENT),
        Activity::Sleeping => ("z", ACCENT),
        Activity::Done => ("✓", Color::LightGreen),
        Activity::Idle => ("·", MUTED),
    }
}

fn detail(entry: &Entry) -> &str {
    if entry.description.is_empty() {
        &entry.directory
    } else {
        &entry.description
    }
}

/// Splits on grapheme boundaries and prefers whole words when wrapping.
fn wrapped_lines<'text>(
    text: &'text str,
    width: u16,
    limit: usize,
    lines: &mut Vec<&'text str>,
) -> std::ops::Range<usize> {
    let first = lines.len();
    if width == 0 || limit == 0 {
        return first..first;
    }
    let available = usize::from(width);
    let styled = Span::raw(text);
    let mut start = 0;
    let mut end = 0;
    let mut columns = 0;
    let mut word_start = None;
    let mut whitespace = true;
    for grapheme in styled.styled_graphemes(Style::default()) {
        let size = Span::raw(grapheme.symbol).width();
        let blank = grapheme.symbol.trim().is_empty();
        if blank && start == end {
            end += grapheme.symbol.len();
            start = end;
            continue;
        }
        if !blank && whitespace {
            word_start = Some((end, columns));
        }
        if columns + size > available && end > start {
            let (split, used) = word_start
                .filter(|&(split, _)| !blank && split > start)
                .unwrap_or((end, columns));
            lines.push(text[start..split].trim_end());
            if lines.len() - first == limit {
                return first..lines.len();
            }
            start = split;
            columns -= used;
            word_start = None;
            if blank {
                end += grapheme.symbol.len();
                start = end;
                whitespace = true;
                continue;
            }
        }
        end += grapheme.symbol.len();
        columns += size;
        whitespace = blank;
    }
    if start < end {
        lines.push(text[start..end].trim_end());
    }
    first..lines.len()
}

fn draw_heading(
    frame: &mut Frame<'_>,
    area: Rect,
    entry: &Entry,
    selected: bool,
    style: Style,
    spinners: &mut Spinners,
) {
    let mut column = area.x;
    let buffer = frame.buffer_mut();
    let mut write = |text: &str, width: usize, style| {
        let remaining = usize::from(area.right().saturating_sub(column));
        column = buffer
            .set_stringn(column, area.y, text, width.min(remaining), style)
            .0;
        column
    };
    write(if selected { "›" } else { " " }, 1, tone(ACCENT));
    let signal_column = write(
        if entry.current { "● " } else { "  " },
        2,
        tone(Color::LightGreen),
    );
    let (glyph, color) = signal(entry.activity);
    let signal_style = tone(color);
    write(glyph, 1, signal_style);
    if entry.priority {
        write("^", 1, signal_style);
    }
    if entry.bell {
        write("+", 1, signal_style);
    }
    write(" ", 1, style);
    write(&entry.index, usize::MAX, tone(MUTED));
    write(" ", 1, style);
    write(&entry.title, usize::MAX, style.add_modifier(Modifier::BOLD));
    if entry.activity == Activity::Working && signal_column < area.right() {
        let position = Position::new(signal_column, area.y);
        let cell = &mut buffer[position];
        spinners.cells.push((position, cell.clone()));
        // Animation paints this cell directly until the layout changes.
        cell.set_skip(true);
    }
}

impl Navigator {
    fn draw(&mut self, frame: &mut Frame<'_>, spinners: &mut Spinners) {
        self.clickable.clear();
        spinners.cells.clear();
        spinners.cursor = None;
        let bright = tone(ACCENT).add_modifier(Modifier::BOLD);
        let view = &self.snapshot.view;
        let mode = if view.triage {
            "TRIAGE"
        } else if self.compact {
            "COMPACT"
        } else {
            "FULL"
        };
        let (focus, border, title) = if self.snapshot.focused {
            ("Shift+Tab work", ACCENT, ACCENT)
        } else {
            ("Shift+Tab focus", Color::DarkGray, MUTED)
        };
        let mut dock = Block::bordered()
            .border_type(BorderType::Rounded)
            .border_style(tone(border))
            .title(Span::styled(
                if self.help.is_some() {
                    format!(" Keyboard shortcuts  {focus} ")
                } else {
                    format!(" NAVIGATOR {mode} {} {focus} ", self.roster.count)
                },
                tone(title).add_modifier(Modifier::BOLD),
            ));
        if self.help.is_none() && self.picker.is_none() {
            let hint = tone(MUTED);
            dock = dock
                .title_bottom(if view.attention_only {
                    Span::styled(" ^A Attention only ", bright)
                } else {
                    Span::styled(" ^A filter alerts ", hint)
                })
                .title_bottom(if let Some(group) = &view.group {
                    Span::styled(format!(" ^F {} ", group_label(group)), bright)
                } else {
                    Span::styled(" ^F focus group ", hint)
                });
        }
        let mut area = dock.inner(frame.area());
        frame.render_widget(dock, frame.area());
        if let Some(help) = &mut self.help {
            help.draw(frame, area);
            return;
        }
        let error = self
            .error
            .as_deref()
            .or(self.snapshot.group_error.as_deref());
        if let Some(picker) = &self.picker {
            picker.draw(frame, area, error, self.snapshot.focused);
            return;
        }
        let search = take_rows(&mut area, 1);
        let (marker, columns) = if search.width < 4 {
            ("/", 1)
        } else {
            (" / ", 3)
        };
        frame.render_widget(Paragraph::new(marker).style(bright), search);
        let input = inset(search, columns);
        if input.height != 0 && input.width != 0 {
            let width = Span::raw(self.query.as_str()).width();
            let offset = width.saturating_sub(usize::from(input.width - 1));
            let field = if self.query.is_empty() {
                Paragraph::new("Keyword or session ID").style(tone(MUTED))
            } else {
                Paragraph::new(self.query.as_str())
                    .scroll((0, u16::try_from(offset).unwrap_or(u16::MAX)))
            };
            frame.render_widget(field, input);
            if self.snapshot.focused && self.filtering {
                let cursor = u16::try_from(width - offset).unwrap_or(input.width - 1);
                let position = Position::new(input.x + cursor, input.y);
                frame.set_cursor_position(position);
                spinners.cursor = Some(position);
            }
        }
        let footer_height = area.height.saturating_sub(2).min(2);
        let body_height = area.height - footer_height;
        let mut body = take_rows(&mut area, body_height);
        if let Some(error) = error {
            let status = take_rows(&mut body, 1);
            frame.render_widget(Paragraph::new(error).style(tone(Color::LightRed)), status);
        }
        let heading = matches!(self.selected_row(), Some(Row::Group(_)));
        let controls = match (heading, self.query.is_empty()) {
            (true, _) => "Enter fold  Tab view Esc work",
            (false, true) => "Enter open  Tab view Esc work",
            (false, false) => "Enter open  Tab view Esc clear",
        };
        let shortcuts = if self.snapshot.status_text {
            "^G group ^T triage ^P pair ^S live on"
        } else {
            "^G group ^T triage ^P pair ^S live off"
        };
        frame.render_widget(
            Paragraph::new(shortcuts).style(tone(MUTED)),
            take_rows(&mut area, 1),
        );
        let footer = take_rows(&mut area, 1);
        let (hint, columns) = if self.filtering {
            ("F1 help", 8)
        } else {
            ("? help", 7)
        };
        frame.render_widget(Span::styled(hint, bright), footer);
        frame.render_widget(Span::styled(controls, tone(MUTED)), inset(footer, columns));
        if body.height == 0 || body.width == 0 {
            return;
        }
        let Some(selected) = self.selected_row() else {
            let message = if !self.query.is_empty() {
                " No matches"
            } else if view.attention_only {
                " No sessions need attention"
            } else if view.group.is_some() {
                " No sessions in this group"
            } else {
                " No OMP windows"
            };
            frame.render_widget(Paragraph::new(message).style(bright), body);
            return;
        };
        let indent = if self.roster.grouped(&self.query, view) {
            2
        } else {
            0
        };
        let entries = &self.snapshot.entries;
        let width = if self.compact && !self.snapshot.status_text {
            0
        } else {
            body.width.saturating_sub(4 + indent)
        };
        let wrap_row = |row: Row, limit, lines: &mut Vec<_>| {
            let start = lines.len();
            let mut status_end = start;
            if let Some(entry) = row.member(entries) {
                if self.snapshot.status_text && !entry.status_message.is_empty() {
                    status_end = wrapped_lines(&entry.status_message, width, limit, lines).end;
                }
                if !self.compact {
                    wrapped_lines(detail(entry), width, limit - (status_end - start), lines);
                }
            }
            (start..lines.len(), status_end)
        };
        let capacity = usize::from(body.height - 1);
        let mut lines = Vec::new();
        let mut preceding = Vec::new();
        let mut first = self.cursor.saturating_sub(capacity);
        if width == 0 || capacity == 0 {
            self.detail_offset = 0;
        } else {
            let (mut selected_lines, status_end) = wrap_row(
                selected,
                self.detail_offset.saturating_add(capacity),
                &mut lines,
            );
            self.detail_offset = self
                .detail_offset
                .min(selected_lines.len().saturating_sub(capacity));
            selected_lines.start += self.detail_offset;
            let mut remaining = capacity - selected_lines.len();
            preceding.push((selected_lines, status_end));
            first = self.cursor;
            while first > 0 && remaining > 0 {
                let (range, status_end) =
                    wrap_row(self.roster.rows[first - 1], remaining, &mut lines);
                if range.len() == remaining {
                    break;
                }
                remaining -= 1 + range.len();
                preceding.push((range, status_end));
                first -= 1;
            }
        }
        for position in first..self.roster.rows.len() {
            if body.height == 0 {
                break;
            }
            let item = self.roster.rows[position];
            let is_selected = position == self.cursor;
            let (range, status_end) = preceding.pop().unwrap_or_else(|| {
                lines.clear();
                wrap_row(item, usize::from(body.height - 1), &mut lines)
            });
            let height = u16::try_from(range.len() + 1).expect("row fits the remaining viewport");
            let mut row = take_rows(&mut body, height);
            if matches!(item, Row::Agent(_)) {
                self.clickable.push((row, position));
            }
            let style = if is_selected {
                Style::default().fg(Color::White).bg(Color::Indexed(24))
            } else {
                Style::default()
            };
            frame.buffer_mut().set_style(row, style);
            let heading = take_rows(&mut row, 1);
            let Some(entry) = item.member(entries) else {
                let group = item.group(entries);
                let marker = match (is_selected, self.roster.is_collapsed(group)) {
                    (true, true) => "›▸ ",
                    (true, false) => "›▾ ",
                    (false, true) => " ▸ ",
                    (false, false) => " ▾ ",
                };
                let heading_style = style.fg(ACCENT).add_modifier(Modifier::BOLD);
                let buffer = frame.buffer_mut();
                let (column, _) = buffer.set_stringn(
                    heading.x,
                    heading.y,
                    marker,
                    usize::from(heading.width),
                    heading_style,
                );
                buffer.set_stringn(
                    column,
                    heading.y,
                    group_label(group),
                    usize::from(heading.right() - column),
                    heading_style,
                );
                continue;
            };
            draw_heading(
                frame,
                inset(heading, indent),
                entry,
                is_selected,
                style,
                spinners,
            );
            let mut text_area = inset(row, 4 + indent);
            let detail_style = if is_selected { style } else { tone(MUTED) };
            for index in range {
                let line_style = if index < status_end {
                    style.fg(ACCENT)
                } else {
                    detail_style
                };
                frame.render_widget(
                    Paragraph::new(lines[index]).style(line_style),
                    take_rows(&mut text_area, 1),
                );
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(window: &str, current: bool) -> Entry {
        Entry {
            window_id: window.into(),
            index: "0".into(),
            pane_id: "%1".into(),
            title: "Samples".into(),
            description: "Inspect [RNA]".into(),
            status_message: String::new(),
            directory: "/work/observatory".into(),
            session_id: "1dff-48df".into(),
            session_code: "LENS".into(),
            session_tag: "j3l6e".into(),
            activity: Activity::Idle,
            group: String::new(),
            priority: false,
            bell: false,
            ping: None,
            created: None,
            current,
        }
    }

    fn snapshot(entries: Vec<Entry>, focused: bool) -> Snapshot {
        Snapshot {
            active_window: entries
                .iter()
                .find(|entry| entry.current)
                .map_or_else(String::new, |entry| entry.window_id.clone()),
            entries,
            focused,
            status_text: false,
            view: Default::default(),
            group_error: None,
        }
    }

    fn triage_snapshot(entries: Vec<Entry>) -> Snapshot {
        let mut sample = snapshot(entries, true);
        sample.view.triage = true;
        sample
    }

    fn grouped_entry(window: &str, group: &str, current: bool) -> Entry {
        let mut member = entry(window, current);
        member.group = group.into();
        member.index = window.trim_start_matches('@').into();
        member.title = format!("Agent {window}");
        member
    }

    fn screen(navigator: &mut Navigator) -> String {
        screen_at(navigator, 38, 20)
    }

    fn screen_at(navigator: &mut Navigator, width: u16, height: u16) -> String {
        use ratatui::{backend::TestBackend, Terminal};

        let mut terminal = Terminal::new(TestBackend::new(width, height)).unwrap();
        let mut spinners = Spinners::default();
        terminal
            .draw(|frame| navigator.draw(frame, &mut spinners))
            .unwrap();
        spinners.paint(terminal.backend_mut(), "⠇").unwrap();
        let buffer = terminal.backend().buffer();
        (0..height)
            .map(|row| {
                (0..width)
                    .map(|column| buffer[(column, row)].symbol())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn live_messages_occupy_their_own_rows_in_both_views() {
        let server = Server::new("unused".into(), "unused".into(), "unused".into());
        let roster = |enabled, message: &str| {
            let mut first = grouped_entry("@1", "", true);
            first.activity = Activity::Working;
            first.status_message = message.into();
            let mut second = grouped_entry("@2", "", false);
            second.activity = Activity::Working;
            let mut sample = snapshot(vec![first, second], true);
            sample.status_text = enabled;
            sample
        };
        let mut navigator = Navigator::new(roster(false, ""));
        assert!(navigator.refresh(roster(true, "")));
        let empty = screen_at(&mut navigator, 40, 15);
        assert!(empty.contains("^S live on"));
        assert!(empty.lines().nth(3).unwrap().contains("Inspect [RNA]"));

        navigator.refresh(roster(true, "Measuring spectra"));
        let full = screen_at(&mut navigator, 40, 15);
        let rows: Vec<_> = full.lines().collect();
        assert!(rows[2].contains("Agent @1"));
        assert!(rows[3].contains("Measuring spectra"));
        assert!(rows[4].contains("Inspect [RNA]"));
        assert!(rows[5].contains("⠇ 2 Agent @2"));

        navigator.key(KeyCode::Tab.into(), &server);
        let compact = screen_at(&mut navigator, 40, 15);
        let rows: Vec<_> = compact.lines().collect();
        assert!(rows[3].contains("Measuring spectra"));
        assert!(rows[4].contains("⠇ 2 Agent @2"));
        assert!(!compact.contains("Inspect [RNA]"));
        navigator.key(KeyCode::Down.into(), &server);
        navigator.refresh(roster(true, "Checking results"));
        assert_eq!(navigator.selection().unwrap().window_id, "@2");
        navigator.refresh(roster(false, "Checking results"));
        let hidden = screen_at(&mut navigator, 40, 15);
        assert!(hidden.contains("^S live off"));
        assert!(!hidden.contains("Checking results"));
        assert!(hidden.lines().nth(3).unwrap().contains("⠇ 2 Agent @2"));
    }

    #[test]
    fn long_working_messages_wrap_and_page_without_losing_the_selected_heading() {
        let server = Server::new("unused".into(), "unused".into(), "unused".into());
        let mut worker = grouped_entry("@2", "", false);
        worker.activity = Activity::Working;
        worker.status_message = "scanning 測定値 third-line fourth-row final-step".into();
        worker.description = "last note".into();
        let mut sample = snapshot(vec![entry("@1", true), worker], true);
        sample.status_text = true;
        let mut navigator = Navigator::new(sample);
        navigator.key(KeyCode::Down.into(), &server);
        for last_line in ["last note", "final-step"] {
            let first_page = screen_at(&mut navigator, 16, 9);
            let rows: Vec<_> = first_page.lines().collect();
            assert!(rows[2].contains("⠇ 2 Agent"));
            assert!(rows[3].contains("scanning"));
            assert!(rows[4].contains('測') && rows[4].contains('値'));
            assert!(rows[5].contains("third-line"));
            for _ in 0..10 {
                navigator.key(KeyCode::PageDown.into(), &server);
            }
            let last_page = screen_at(&mut navigator, 16, 9);
            assert!(last_page.lines().nth(2).unwrap().contains("⠇ 2 Agent"));
            assert!(last_page.lines().nth(5).unwrap().contains(last_line));
            navigator.key(KeyCode::Up.into(), &server);
            navigator.key(KeyCode::Down.into(), &server);
            navigator.key(KeyCode::Tab.into(), &server);
        }
    }

    #[test]
    fn grouped_browse_sorts_headings_keeps_member_order_and_counts_hidden_agents() {
        let server = Server::new("unused".into(), "unused".into(), "unused".into());
        let mut navigator = Navigator::new(snapshot(
            vec![
                grouped_entry("@2", "Beta", false),
                grouped_entry("@3", "", false),
                grouped_entry("@7", "Alpha", true),
                grouped_entry("@8", "Alpha", false),
            ],
            true,
        ));
        navigator.key(KeyCode::Tab.into(), &server);
        let expanded = screen(&mut navigator);
        let labels = [
            "Alpha",
            "Agent @7",
            "Agent @8",
            "Beta",
            "Agent @2",
            "Ungrouped",
            "Agent @3",
        ];
        let positions = labels.map(|label| expanded.find(label).unwrap());
        assert!(positions.windows(2).all(|pair| pair[0] < pair[1]));
        assert!(expanded.contains("^G group"));
        assert!(expanded.contains("^P pair"));
        assert_eq!(navigator.selection().unwrap().window_id, "@7");
        navigator.key(KeyCode::Left.into(), &server);
        let collapsed = screen(&mut navigator);
        assert!(collapsed.contains("COMPACT 4"));
        assert!(!collapsed.contains("Agent @7"));
        assert!(!collapsed.contains("Agent @8"));
        assert!(navigator.selection().is_none());
        let pair = KeyEvent::new(KeyCode::Char('p'), KeyModifiers::CONTROL);
        assert!(matches!(navigator.key(pair, &server), Input::Ignore));
        navigator.key(KeyCode::Enter.into(), &server);
        navigator.key(KeyCode::Down.into(), &server);
        assert_eq!(navigator.selection().unwrap().window_id, "@7");
    }

    #[test]
    fn search_reaches_collapsed_groups_prefers_exact_numbers_and_restores_collapse() {
        let server = Server::new("unused".into(), "unused".into(), "unused".into());
        let mut navigator = Navigator::new(snapshot(
            vec![
                grouped_entry("@2", "計測12", true),
                grouped_entry("@12", "計測12", false),
                grouped_entry("@20", "Other", false),
            ],
            true,
        ));
        navigator.key(KeyCode::Left.into(), &server);
        for character in "計測".chars() {
            navigator.key(KeyCode::Char(character).into(), &server);
        }
        let search = screen(&mut navigator);
        assert!(search.contains("FULL 2"));
        assert!(search.contains("Agent @2"));
        assert!(search.contains("Agent @12"));
        assert!(!search.contains("Agent @20"));
        navigator.key(KeyCode::Esc.into(), &server);
        for character in "12".chars() {
            navigator.key(KeyCode::Char(character).into(), &server);
        }
        assert_eq!(navigator.selection().unwrap().window_id, "@12");
        navigator.key(KeyCode::Esc.into(), &server);
        assert!(!screen(&mut navigator).contains("Agent @12"));
        navigator.key(KeyCode::Right.into(), &server);
        assert!(screen(&mut navigator).contains("Agent @12"));
    }

    #[test]
    fn refresh_keeps_the_heading_and_follows_a_switched_to_collapsed_group() {
        let server = Server::new("unused".into(), "unused".into(), "unused".into());
        let mut navigator = Navigator::new(snapshot(
            vec![
                grouped_entry("@1", "Alpha", true),
                grouped_entry("@2", "Beta", false),
                grouped_entry("@3", "Beta", false),
            ],
            true,
        ));
        navigator.key(KeyCode::Down.into(), &server);
        navigator.key(KeyCode::Left.into(), &server);
        navigator.refresh(snapshot(
            vec![
                grouped_entry("@1", "Alpha", true),
                grouped_entry("@3", "Beta", false),
            ],
            false,
        ));
        assert!(navigator.selection().is_none());
        navigator.key(KeyCode::Up.into(), &server);
        assert_eq!(navigator.selection().unwrap().window_id, "@1");
        navigator.refresh(snapshot(
            vec![
                grouped_entry("@1", "Alpha", false),
                grouped_entry("@3", "Beta", true),
            ],
            false,
        ));
        assert!(navigator.selection().is_none());
        navigator.key(KeyCode::Right.into(), &server);
        navigator.key(KeyCode::Down.into(), &server);
        assert_eq!(navigator.selection().unwrap().window_id, "@3");
    }

    #[test]
    fn arrows_wrap_at_each_end_of_the_current_projection() {
        let server = Server::new("unused".into(), "unused".into(), "unused".into());
        let mut navigator = Navigator::new(snapshot(
            vec![
                grouped_entry("@1", "Lab", true),
                grouped_entry("@2", "", false),
            ],
            true,
        ));
        navigator.key(KeyCode::Up.into(), &server);
        assert!(navigator.selection().is_none());
        navigator.key(KeyCode::Up.into(), &server);
        assert_eq!(navigator.selection().unwrap().window_id, "@2");
        navigator.key(KeyCode::Down.into(), &server);
        assert!(navigator.selection().is_none());
        navigator.key(KeyCode::Char('A').into(), &server);
        assert_eq!(navigator.selection().unwrap().window_id, "@1");
        navigator.key(KeyCode::Up.into(), &server);
        assert_eq!(navigator.selection().unwrap().window_id, "@2");
        navigator.key(KeyCode::Down.into(), &server);
        assert_eq!(navigator.selection().unwrap().window_id, "@1");
    }

    #[test]
    fn picker_preserves_search_and_cancels_if_the_target_pane_is_replaced() {
        let server = Server::new("unused".into(), "unused".into(), "unused".into());
        let mut navigator = Navigator::new(snapshot(vec![entry("@1", true)], true));
        navigator.key(KeyCode::Char('S').into(), &server);
        navigator.picker = Some(GroupPicker::new(navigator.selection().unwrap(), Vec::new()));
        navigator.key(KeyCode::Char('Z').into(), &server);
        navigator.key(KeyCode::Tab.into(), &server);
        assert_eq!(navigator.query, "S");
        assert!(!navigator.compact);
        let picker = screen(&mut navigator);
        assert!(!picker.contains("Enter open"));
        navigator.refresh(snapshot(vec![entry("@1", true)], false));
        assert!(navigator.picker.is_some());
        let mut replacement = entry("@1", true);
        replacement.pane_id = "%20".into();
        navigator.refresh(snapshot(vec![replacement], true));
        assert!(navigator.picker.is_none());
        assert_eq!(navigator.query, "S");
    }

    #[test]
    fn a_switch_between_non_agent_windows_cancels_the_move_without_losing_search() {
        let server = Server::new("unused".into(), "unused".into(), "unused".into());
        let mut first = snapshot(vec![entry("@1", false)], true);
        first.active_window = "@8".into();
        let mut navigator = Navigator::new(first);
        navigator.key(KeyCode::Char('S').into(), &server);
        navigator.picker = Some(GroupPicker::new(navigator.selection().unwrap(), Vec::new()));
        let mut second = snapshot(vec![entry("@1", false)], true);
        second.active_window = "@9".into();
        navigator.refresh(second);
        assert!(navigator.picker.is_none());
        assert_eq!(navigator.query, "S");
        assert!(screen(&mut navigator).contains("window changed"));
    }

    #[test]
    fn a_group_heading_shifts_the_spinner_and_the_picker_suspends_it() {
        use ratatui::{backend::TestBackend, Terminal};

        let mut worker = grouped_entry("@1", "Alpha", true);
        worker.activity = Activity::Working;
        let mut navigator = Navigator::new(snapshot(vec![worker], true));
        let mut terminal = Terminal::new(TestBackend::new(38, 12)).unwrap();
        let mut spinners = Spinners::default();
        terminal
            .draw(|frame| navigator.draw(frame, &mut spinners))
            .unwrap();
        spinners.paint(terminal.backend_mut(), "⠇").unwrap();
        assert_eq!(terminal.backend().buffer()[(6, 3)].symbol(), "⠇");
        navigator.picker = Some(GroupPicker::new(navigator.selection().unwrap(), Vec::new()));
        terminal
            .draw(|frame| navigator.draw(frame, &mut spinners))
            .unwrap();
        assert!(spinners.cells.is_empty());
        assert!(spinners.cursor.is_none());
    }

    #[test]
    fn triage_orders_attention_by_signal_then_age_and_keeps_selection_on_a_repeat_ping() {
        let server = Server::new("unused".into(), "unused".into(), "unused".into());
        let toggle = KeyEvent::new(KeyCode::Char('t'), KeyModifiers::CONTROL);
        let entries = || {
            let mut entries: Vec<_> = (1..=9)
                .map(|number| grouped_entry(&format!("@{number}"), "Lab", number == 9))
                .collect();
            entries[0].index = "101".into();
            entries[1].bell = true;
            entries[1].ping = Some((100, 1));
            entries[2].activity = Activity::Urgent;
            entries[3].activity = Activity::Crashed;
            entries[4].activity = Activity::Waiting;
            entries[5].priority = true;
            entries[6].created = Some(Duration::from_secs(90));
            entries[7].index = "99".into();
            entries[7].created = Some(Duration::from_secs(80));
            entries[8].index = "10".into();
            entries
        };
        let mut navigator = Navigator::new(snapshot(entries(), true));
        navigator.key(KeyCode::Left.into(), &server);
        navigator.key(toggle, &server);
        assert!(screen(&mut navigator).contains("TRIAGE 9 Shift+Tab work"));
        for expected in ["@2", "@6", "@5", "@4", "@3", "@7", "@8", "@9", "@1"] {
            assert_eq!(navigator.selection().unwrap().window_id, expected);
            navigator.key(KeyCode::Down.into(), &server);
        }
        navigator.key(KeyCode::Down.into(), &server);
        let mut changed = entries();
        changed[0].bell = true;
        changed[0].ping = Some((100, 2));
        navigator.refresh(triage_snapshot(changed));
        assert_eq!(navigator.selection().unwrap().window_id, "@6");
        let mut repeated = entries();
        repeated[0].bell = true;
        repeated[0].ping = Some((100, 2));
        repeated[1].ping = Some((100, 3));
        navigator.refresh(triage_snapshot(repeated));
        assert_eq!(navigator.selection().unwrap().window_id, "@6");
        navigator.key(KeyCode::Up.into(), &server);
        assert_eq!(navigator.selection().unwrap().window_id, "@1");
        navigator.key(KeyCode::Up.into(), &server);
        assert_eq!(navigator.selection().unwrap().window_id, "@2");
        navigator.key(KeyCode::Char('5').into(), &server);
        assert_eq!(navigator.selection().unwrap().window_id, "@5");
        navigator.key(KeyCode::Esc.into(), &server);
        navigator.key(toggle, &server);
        assert!(navigator.selection().is_none());
        assert!(!screen(&mut navigator).contains("Agent @5"));
    }

    #[test]
    fn a_newer_pending_session_precedes_an_older_recorded_ping() {
        let server = Server::new("unused".into(), "unused".into(), "unused".into());
        let mut pinged = grouped_entry("@1", "", true);
        pinged.bell = true;
        pinged.ping = Some((100, 1));
        let mut waiting = grouped_entry("@2", "", false);
        waiting.activity = Activity::Waiting;
        waiting.created = Some(Duration::from_secs(200));
        let mut idle = grouped_entry("@3", "", false);
        idle.created = Some(Duration::from_secs(300));
        let mut navigator = Navigator::new(snapshot(vec![pinged, waiting, idle], true));
        navigator.key(
            KeyEvent::new(KeyCode::Char('t'), KeyModifiers::CONTROL),
            &server,
        );
        for expected in ["@2", "@1", "@3"] {
            assert_eq!(navigator.selection().unwrap().window_id, expected);
            navigator.key(KeyCode::Down.into(), &server);
        }
    }

    #[test]
    fn triage_tracks_live_requests_and_only_ranks_signals_that_remain_active() {
        let server = Server::new("unused".into(), "unused".into(), "unused".into());
        let entries = |activity, acknowledged: bool, output: &str| {
            let mut old = grouped_entry("@1", "Lab", false);
            old.bell = !acknowledged;
            old.ping = Some((100, 1));
            old.priority = true;
            old.status_message = output.into();
            let mut requester = grouped_entry("@2", "Lab", false);
            requester.activity = activity;
            let mut pending = grouped_entry("@3", "Lab", false);
            pending.bell = true;
            pending.ping = Some((99, 1));
            let mut elsewhere = grouped_entry("@4", "Field", false);
            elsewhere.priority = true;
            vec![old, requester, pending, elsewhere]
        };
        let mut navigator = Navigator::new(triage_snapshot(entries(Activity::Idle, false, "")));
        for character in "lab".chars() {
            navigator.key(KeyCode::Char(character).into(), &server);
        }
        assert_eq!(navigator.selection().unwrap().window_id, "@1");
        fn ordering(navigator: &Navigator) -> Vec<&str> {
            navigator
                .roster
                .rows
                .iter()
                .map(|row| {
                    row.member(&navigator.snapshot.entries)
                        .unwrap()
                        .window_id
                        .as_str()
                })
                .collect()
        }
        navigator.refresh(triage_snapshot(entries(Activity::Waiting, false, "")));
        assert_eq!(ordering(&navigator), ["@2", "@1", "@3"]);
        assert_eq!(navigator.selection().unwrap().window_id, "@1");
        let mut pinged = entries(Activity::Waiting, false, "");
        let seconds = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        pinged[0].ping = Some((seconds, 2));
        navigator.refresh(triage_snapshot(pinged));
        assert_eq!(ordering(&navigator), ["@1", "@2", "@3"]);
        navigator.refresh(triage_snapshot(entries(Activity::Waiting, true, "output")));
        assert_eq!(ordering(&navigator), ["@2", "@3", "@1"]);
        navigator.refresh(triage_snapshot(entries(
            Activity::Working,
            true,
            "more output",
        )));
        assert_eq!(ordering(&navigator), ["@3", "@1", "@2"]);
    }

    #[test]
    fn wrapped_detail_keeps_words_and_wide_graphemes_readable() {
        let mut lines = Vec::new();
        wrapped_lines("Inspect 測定値 before release", 7, usize::MAX, &mut lines);
        assert_eq!(lines, ["Inspect", "測定値", "before", "release"]);
    }

    #[test]
    fn full_view_wraps_every_detail_and_pages_the_selection_to_its_last_line() {
        use ratatui::{backend::TestBackend, Terminal};

        let mut first = entry("@1", true);
        first.description =
            "alpha-line bravo-line charlie delta-line echo-line foxtrot golf-line".into();
        let mut second = entry("@2", false);
        second.description = "検査結果 second-row final-row".into();
        let mut navigator = Navigator::new(snapshot(vec![first, second], true));
        let render = |navigator: &mut Navigator, height| {
            let mut terminal = Terminal::new(TestBackend::new(16, height)).unwrap();
            terminal
                .draw(|frame| navigator.draw(frame, &mut Spinners::default()))
                .unwrap();
            let buffer = terminal.backend().buffer();
            (0..height)
                .map(|row| {
                    (5..15)
                        .map(|column| buffer[(column, row)].symbol())
                        .collect::<String>()
                })
                .collect::<Vec<_>>()
        };
        let rows = render(&mut navigator, 17);
        assert_eq!(rows[9].trim(), "golf-line");
        assert_eq!(rows[12].trim(), "second-row");
        assert_eq!(rows[13].trim(), "final-row");
        navigator.move_by(1);
        assert_eq!(render(&mut navigator, 17)[9].trim(), "golf-line");
        navigator.move_by(-1);
        let rows = render(&mut navigator, 9);
        assert_eq!(rows[3].trim(), "alpha-line");
        assert_eq!(rows[5].trim(), "charlie");
        let server = Server::new("unused".into(), "unused".into(), "unused".into());
        for _ in 0..8 {
            navigator.key(KeyCode::PageDown.into(), &server);
        }
        let rows = render(&mut navigator, 9);
        assert_eq!(rows[5].trim(), "golf-line");
        navigator.key(KeyCode::PageUp.into(), &server);
        assert_eq!(render(&mut navigator, 9)[5].trim(), "foxtrot");
        assert!(render(&mut navigator, 4)[2].contains("Samples"));
        assert_eq!(render(&mut navigator, 17)[3].trim(), "alpha-line");
    }

    #[test]
    fn literal_search_matches_window_fields_and_handles_one_or_zero_agents() {
        let mut navigator = Navigator::new(snapshot(vec![entry("@1", true)], true));
        for query in [
            "/WORK/OBS",
            "samples",
            "[RnA]",
            "0",
            "1DFF-48",
            "lens",
            "J3L6E",
        ] {
            navigator.query = query.into();
            navigator.filter();
            navigator.move_by(-1);
            navigator.move_by(1);
            assert_eq!(navigator.selection().unwrap().window_id, "@1");
        }
        navigator.query = ".*".into();
        navigator.filter();
        navigator.move_by(1);
        assert!(navigator.selection().is_none());
    }

    #[test]
    fn a_single_interior_cell_displays_the_search_marker() {
        use ratatui::{backend::TestBackend, Terminal};

        let mut navigator = Navigator::new(snapshot(vec![entry("@1", true)], false));
        let mut terminal = Terminal::new(TestBackend::new(3, 3)).unwrap();
        terminal
            .draw(|frame| navigator.draw(frame, &mut Spinners::default()))
            .unwrap();
        assert_eq!(terminal.backend().buffer()[(1, 1)].symbol(), "/");
    }

    #[test]
    fn rounded_frame_survives_long_titles_and_spinner_updates() {
        use ratatui::{backend::TestBackend, Terminal};

        let mut worker = entry("@1", true);
        worker.title = "Shared spectra 測定値 ".repeat(4);
        worker.activity = Activity::Working;
        let mut navigator = Navigator::new(snapshot(vec![worker], true));
        let mut terminal = Terminal::new(TestBackend::new(40, 9)).unwrap();
        let mut spinners = Spinners::default();
        terminal
            .draw(|frame| navigator.draw(frame, &mut spinners))
            .unwrap();
        spinners.paint(terminal.backend_mut(), "⠙").unwrap();
        let buffer = terminal.backend().buffer();
        let corners = [(0, 0, "╭"), (39, 0, "╮"), (0, 8, "╰"), (39, 8, "╯")];
        for (column, row, expected) in corners {
            assert_eq!(buffer[(column, row)].symbol(), expected);
        }
        for row in 1..8 {
            assert_eq!(buffer[(0, row)].symbol(), "│");
            assert_eq!(buffer[(39, row)].symbol(), "│");
        }
        assert!((1..39).any(|column| buffer[(column, 2)].symbol() == "測"));
    }

    #[test]
    fn only_working_glyphs_inside_the_viewport_request_animation() {
        use ratatui::{backend::TestBackend, Terminal};

        let mut worker = entry("@2", false);
        worker.activity = Activity::Working;
        worker.priority = true;
        worker.bell = true;
        worker.title = "Working".into();
        let mut navigator = Navigator::new(snapshot(vec![entry("@1", true), worker], false));
        let render = |navigator: &mut Navigator, width, glyph: &str| {
            let mut terminal = Terminal::new(TestBackend::new(width, 4)).unwrap();
            let mut spinners = Spinners::default();
            terminal
                .draw(|frame| navigator.draw(frame, &mut spinners))
                .unwrap();
            let animated = !spinners.cells.is_empty();
            if animated {
                spinners.paint(terminal.backend_mut(), glyph).unwrap();
            }
            let buffer = terminal.backend().buffer();
            let row: String = (0..width)
                .map(|column| buffer[(column, 2)].symbol())
                .collect();
            (animated, row)
        };
        assert!(!render(&mut navigator, 24, "⠋").0);
        navigator.move_by(1);
        assert!(!render(&mut navigator, 3, "⠋").0);
        let (animated, row) = render(&mut navigator, 24, "⠹");
        assert!(animated);
        assert!(row.contains("⠹^+ 0 Working"));
        navigator.query = "Samples".into();
        navigator.filter();
        assert!(!render(&mut navigator, 24, "⠋").0);
    }

    #[test]
    fn animation_preserves_the_search_cursor_and_stops_when_work_finishes() {
        use ratatui::{backend::TestBackend, Terminal};

        let mut worker = entry("@1", true);
        worker.activity = Activity::Working;
        let mut navigator = Navigator::new(snapshot(vec![worker], true));
        navigator.filtering = true;
        navigator.query.push('S');
        navigator.filter();
        let mut terminal = Terminal::new(TestBackend::new(40, 8)).unwrap();
        let mut spinners = Spinners::default();
        terminal
            .draw(|frame| navigator.draw(frame, &mut spinners))
            .unwrap();
        spinners.paint(terminal.backend_mut(), "⠇").unwrap();
        assert_eq!(terminal.backend().buffer()[(4, 2)].symbol(), "⠇");
        assert_eq!(
            terminal.backend_mut().get_cursor_position().unwrap(),
            Position::new(5, 1)
        );
        navigator.snapshot.entries[0].activity = Activity::Done;
        terminal
            .draw(|frame| navigator.draw(frame, &mut spinners))
            .unwrap();
        assert!(spinners.cells.is_empty());
        assert_eq!(terminal.backend().buffer()[(4, 2)].symbol(), "✓");
    }

    #[test]
    fn spinner_uses_elapsed_time_and_skips_missed_frames() {
        for (milliseconds, glyph, remaining) in [(0, "⠋", 100), (399, "⠸", 1), (1000, "⠋", 100)]
        {
            assert_eq!(
                spinner_frame(Duration::from_millis(milliseconds)),
                (glyph, Duration::from_millis(remaining))
            );
        }
    }

    #[test]
    fn selection_survives_a_filtered_refresh_and_follows_an_external_switch() {
        let mut navigator =
            Navigator::new(snapshot(vec![entry("@1", true), entry("@2", false)], true));
        navigator.query.push_str("[rna]");
        navigator.filter();
        navigator.move_by(1);
        navigator.refresh(snapshot(
            vec![entry("@3", false), entry("@1", true), entry("@2", false)],
            true,
        ));
        assert_eq!(navigator.selection().unwrap().window_id, "@2");
        navigator.refresh(snapshot(
            vec![entry("@3", true), entry("@1", false), entry("@2", false)],
            false,
        ));
        assert_eq!(navigator.selection().unwrap().window_id, "@3");
        assert_eq!(navigator.query, "[rna]");
    }
}
