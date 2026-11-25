use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::Span;
use ratatui::Frame;

use crate::groups::{validate_name, UNGROUPED};
use crate::tmux::Entry;

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum PickerAction {
    Ignore,
    Redraw,
    Cancel,
    Assign(Option<String>),
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Destination {
    Ungrouped,
    Saved(usize),
    Create,
}

struct SavedName {
    name: String,
    folded: String,
}

pub(crate) struct GroupPicker {
    window_id: String,
    pane_id: String,
    session_id: String,
    source: String,
    names: Vec<SavedName>,
    field: String,
    options: Vec<Destination>,
    selected: usize,
    validation: Option<String>,
}

impl GroupPicker {
    pub(crate) fn new(entry: &Entry, mut names: Vec<String>) -> Self {
        names.sort_unstable();
        names.dedup();
        let selected = names
            .binary_search(&entry.group)
            .map_or(0, |index| index + 1);
        let options = std::iter::once(Destination::Ungrouped)
            .chain((0..names.len()).map(Destination::Saved))
            .collect();
        Self {
            window_id: entry.window_id.clone(),
            pane_id: entry.pane_id.clone(),
            session_id: entry.session_id.clone(),
            source: format!("Move to group · {} {}", entry.index, entry.title),
            names: names
                .into_iter()
                .map(|name| SavedName {
                    folded: name.to_lowercase(),
                    name,
                })
                .collect(),
            field: String::new(),
            options,
            selected,
            validation: None,
        }
    }

    pub(crate) fn target(&self) -> (&str, &str, &str) {
        (&self.window_id, &self.pane_id, &self.session_id)
    }

    fn filter(&mut self) {
        let trimmed = self.field.trim();
        let needle = trimmed.to_lowercase();
        self.options.clear();
        self.validation = None;
        self.selected = 0;
        let ungrouped = trimmed.eq_ignore_ascii_case(UNGROUPED);
        if !self.field.is_empty() && !ungrouped {
            if let Err(error) = validate_name(&self.field) {
                self.validation = Some(error.to_string());
                return;
            }
        }
        let ungrouped_matches = needle.is_empty()
            || UNGROUPED
                .as_bytes()
                .windows(needle.len())
                .any(|part| part.eq_ignore_ascii_case(needle.as_bytes()));
        if ungrouped_matches {
            self.options.push(Destination::Ungrouped);
        }
        let mut exact = ungrouped;
        for (index, saved) in self.names.iter().enumerate() {
            if saved.folded.contains(&needle) {
                if saved.name == trimmed {
                    self.selected = self.options.len();
                    exact = true;
                }
                self.options.push(Destination::Saved(index));
            }
        }
        if !trimmed.is_empty() && !exact {
            self.options.push(Destination::Create);
        }
    }

    pub(crate) fn key(&mut self, key: KeyEvent) -> PickerAction {
        if key.kind == KeyEventKind::Release
            || key
                .modifiers
                .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT)
        {
            return PickerAction::Ignore;
        }
        match key.code {
            KeyCode::Up => {
                self.selected = self
                    .selected
                    .checked_sub(1)
                    .unwrap_or_else(|| self.options.len().saturating_sub(1));
            }
            KeyCode::Down => {
                self.selected = if self.selected + 1 < self.options.len() {
                    self.selected + 1
                } else {
                    0
                };
            }
            KeyCode::Enter => {
                return match self.options.get(self.selected) {
                    Some(Destination::Ungrouped) => PickerAction::Assign(None),
                    Some(Destination::Saved(index)) => {
                        PickerAction::Assign(Some(self.names[*index].name.clone()))
                    }
                    Some(Destination::Create) => {
                        PickerAction::Assign(Some(self.field.trim().to_owned()))
                    }
                    None => PickerAction::Ignore,
                };
            }
            KeyCode::Char(character) if !character.is_control() => {
                self.field.push(character);
                self.filter();
            }
            KeyCode::Backspace if self.field.pop().is_some() => self.filter(),
            KeyCode::Esc => return PickerAction::Cancel,
            _ => return PickerAction::Ignore,
        }
        PickerAction::Redraw
    }

    pub(crate) fn draw(
        &self,
        frame: &mut Frame<'_>,
        area: Rect,
        error: Option<&str>,
        focused: bool,
    ) {
        let area = area.intersection(frame.area());
        if area.is_empty() {
            return;
        }
        let accent = Style::default().fg(Color::LightCyan);
        let muted = Style::default().fg(Color::Gray);
        let error = error.or(self.validation.as_deref());
        let spare = area.height - u16::from(!self.options.is_empty());
        let show_error = error.is_some() && spare > 0;
        let show_field = spare > u16::from(show_error);
        let show_title = spare > u16::from(show_error) + u16::from(show_field);
        let show_help = area.height >= 5 + u16::from(show_error);
        let mut rows = area.rows();
        if show_title {
            if let Some(row) = rows.next() {
                write_row(
                    frame,
                    row,
                    &self.source,
                    accent.add_modifier(Modifier::BOLD),
                );
            }
        }
        if show_field {
            if let Some(row) = rows.next() {
                self.draw_field(frame, row, focused);
            }
        }
        if show_error {
            if let (Some(row), Some(error)) = (rows.next(), error) {
                write_row(frame, row, error, Style::default().fg(Color::LightRed));
            }
        }
        let height = usize::from(
            area.height
                - u16::from(show_title)
                - u16::from(show_field)
                - u16::from(show_error)
                - u16::from(show_help),
        );
        let first = (self.selected + 1).saturating_sub(height);
        for (index, option) in self.options.iter().enumerate().skip(first).take(height) {
            let Some(row) = rows.next() else { break };
            let selected = index == self.selected;
            let style = if selected {
                accent.add_modifier(Modifier::BOLD)
            } else {
                Style::default()
            };
            let rest = write_row(frame, row, if selected { "› " } else { "  " }, style);
            match option {
                Destination::Ungrouped => write_row(frame, rest, UNGROUPED, style),
                Destination::Saved(index) => {
                    write_row(frame, rest, &self.names[*index].name, style)
                }
                Destination::Create => {
                    let rest = write_row(frame, rest, "Create ", style);
                    write_row(frame, rest, self.field.trim(), style)
                }
            };
        }
        if show_help {
            let footer = Rect::new(area.x, area.bottom() - 1, area.width, 1);
            write_row(
                frame,
                footer,
                "F1 help  ↑↓ pick Enter move Esc cancel",
                muted,
            );
        }
    }

    fn draw_field(&self, frame: &mut Frame<'_>, row: Rect, focused: bool) {
        let marker = if row.width >= 16 {
            "Destination › "
        } else if row.width >= 3 {
            "› "
        } else {
            ""
        };
        let input = write_row(frame, row, marker, Style::default().fg(Color::LightCyan));
        let available = usize::from(input.width.saturating_sub(1));
        let field = Span::raw(self.field.as_str());
        let mut width = field.width();
        let mut start = 0;
        for grapheme in field.styled_graphemes(Style::default()) {
            if width <= available {
                break;
            }
            width = width.saturating_sub(Span::raw(grapheme.symbol).width());
            start += grapheme.symbol.len();
        }
        let cursor = if self.field.is_empty() {
            write_row(
                frame,
                input,
                "Type a group",
                Style::default().fg(Color::Gray),
            );
            input.x
        } else {
            write_row(frame, input, &self.field[start..], Style::default()).x
        };
        if focused && input.width != 0 {
            frame.set_cursor_position((cursor.min(input.right() - 1), input.y));
        }
    }
}

fn write_row(frame: &mut Frame<'_>, row: Rect, text: &str, style: Style) -> Rect {
    if row.is_empty() {
        return row;
    }
    let (end, _) =
        frame
            .buffer_mut()
            .set_stringn(row.x, row.y, text, usize::from(row.width), style);
    Rect::new(end, row.y, row.right() - end, 1)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tmux::Activity;

    fn picker(current_group: &str, names: &[&str]) -> GroupPicker {
        let entry = Entry {
            window_id: "@8".into(),
            index: "3".into(),
            pane_id: "%9".into(),
            session_id: "ca861e50-c5cd-4f0d-8c45-e9405e417fa1".into(),
            session_code: String::new(),
            session_tag: String::new(),
            title: "Review".into(),
            description: String::new(),
            status_message: String::new(),
            directory: String::new(),
            group: current_group.into(),
            activity: Activity::Idle,
            priority: false,
            bell: false,
            ping: None,
            created: None,
            current: false,
        };
        GroupPicker::new(&entry, names.iter().map(|name| (*name).into()).collect())
    }

    fn press(picker: &mut GroupPicker, code: KeyCode) -> PickerAction {
        picker.key(KeyEvent::new(code, KeyModifiers::NONE))
    }

    fn type_text(picker: &mut GroupPicker, text: &str) {
        for character in text.chars() {
            assert_eq!(
                press(picker, KeyCode::Char(character)),
                PickerAction::Redraw
            );
        }
    }

    #[test]
    fn current_group_is_selected_and_arrows_choose_sorted_destinations() {
        let mut picker = picker("Winter", &["Winter", "Aurora"]);
        assert_eq!(
            picker.target(),
            ("@8", "%9", "ca861e50-c5cd-4f0d-8c45-e9405e417fa1")
        );
        assert_eq!(
            press(&mut picker, KeyCode::Enter),
            PickerAction::Assign(Some("Winter".into()))
        );
        press(&mut picker, KeyCode::Up);
        assert_eq!(
            press(&mut picker, KeyCode::Enter),
            PickerAction::Assign(Some("Aurora".into()))
        );
        press(&mut picker, KeyCode::Up);
        assert_eq!(
            press(&mut picker, KeyCode::Enter),
            PickerAction::Assign(None)
        );
    }

    #[test]
    fn arrows_wrap_through_ungrouped_and_the_filtered_create_option() {
        let mut picker = picker("", &["Red", "Orange"]);
        press(&mut picker, KeyCode::Up);
        assert_eq!(
            press(&mut picker, KeyCode::Enter),
            PickerAction::Assign(Some("Red".into()))
        );
        press(&mut picker, KeyCode::Down);
        assert_eq!(
            press(&mut picker, KeyCode::Enter),
            PickerAction::Assign(None)
        );
        type_text(&mut picker, "or");
        press(&mut picker, KeyCode::Up);
        assert_eq!(
            press(&mut picker, KeyCode::Enter),
            PickerAction::Assign(Some("or".into()))
        );
        press(&mut picker, KeyCode::Down);
        assert_eq!(
            press(&mut picker, KeyCode::Enter),
            PickerAction::Assign(Some("Orange".into()))
        );
    }

    #[test]
    fn typing_an_exact_name_prefers_it_over_earlier_partial_matches() {
        let mut picker = picker("", &["Ice", "Black Ice"]);
        type_text(&mut picker, "Ice");
        assert_eq!(
            press(&mut picker, KeyCode::Enter),
            PickerAction::Assign(Some("Ice".into()))
        );
    }

    #[test]
    fn partial_match_and_creation_are_separate_destinations() {
        let mut picker = picker("", &["Étoiles"]);
        type_text(&mut picker, "éto");
        assert_eq!(
            press(&mut picker, KeyCode::Enter),
            PickerAction::Assign(Some("Étoiles".into()))
        );
        press(&mut picker, KeyCode::Down);
        assert_eq!(
            press(&mut picker, KeyCode::Enter),
            PickerAction::Assign(Some("éto".into()))
        );
    }

    #[test]
    fn entering_a_new_name_creates_the_trimmed_destination() {
        let mut picker = picker("", &["Other"]);
        type_text(&mut picker, "  Spectra  ");
        assert_eq!(
            press(&mut picker, KeyCode::Enter),
            PickerAction::Assign(Some("Spectra".into()))
        );
        type_text(&mut picker, &"界".repeat(65));
        press(&mut picker, KeyCode::Up);
        press(&mut picker, KeyCode::Down);
        assert!(matches!(
            press(&mut picker, KeyCode::Enter),
            PickerAction::Ignore | PickerAction::Redraw
        ));
        assert_eq!(press(&mut picker, KeyCode::Esc), PickerAction::Cancel);
    }

    #[test]
    fn ignored_navigation_and_modifiers_leave_the_typed_destination_intact() {
        let mut picker = picker("", &[]);
        type_text(&mut picker, "青界");
        press(&mut picker, KeyCode::Backspace);
        for code in [
            KeyCode::Left,
            KeyCode::Right,
            KeyCode::PageDown,
            KeyCode::PageUp,
            KeyCode::Tab,
        ] {
            assert_eq!(press(&mut picker, code), PickerAction::Ignore);
        }
        for modifiers in [KeyModifiers::CONTROL, KeyModifiers::ALT] {
            assert_eq!(
                picker.key(KeyEvent::new(KeyCode::Char('g'), modifiers)),
                PickerAction::Ignore
            );
        }
        press(&mut picker, KeyCode::Down);
        press(&mut picker, KeyCode::Up);
        assert_eq!(
            press(&mut picker, KeyCode::Enter),
            PickerAction::Assign(Some("青".into()))
        );
    }

    #[test]
    fn short_picker_keeps_the_selected_name_inside_the_given_area() {
        use ratatui::{backend::TestBackend, layout::Rect, Terminal};

        let picker = picker("Winter", &["Aurora", "Rain", "Winter"]);
        let mut terminal = Terminal::new(TestBackend::new(16, 4)).unwrap();
        terminal
            .draw(|frame| picker.draw(frame, Rect::new(2, 1, 8, 1), None, false))
            .unwrap();
        let buffer = terminal.backend().buffer();
        let row: String = (0..16).map(|column| buffer[(column, 1)].symbol()).collect();
        assert_eq!(row, "  › Winter      ");
    }

    #[test]
    fn save_error_keeps_the_source_field_and_create_choice_visible() {
        use ratatui::{backend::TestBackend, Terminal};

        let mut picker = picker("", &[]);
        type_text(&mut picker, "Spectra");
        let mut terminal = Terminal::new(TestBackend::new(40, 6)).unwrap();
        terminal
            .draw(|frame| {
                let area = frame.area();
                picker.draw(frame, area, Some("Permission denied"), true);
            })
            .unwrap();
        let buffer = terminal.backend().buffer();
        let rows: Vec<String> = (0..6)
            .map(|row| {
                (0..40)
                    .map(|column| buffer[(column, row)].symbol())
                    .collect()
            })
            .collect();
        for label in [
            "Move to group",
            "3 Review",
            "Permission denied",
            "Create Spectra",
        ] {
            assert!(rows.iter().any(|row| row.contains(label)), "{label}");
        }
        assert!(rows
            .iter()
            .any(|row| row.contains("Spectra") && !row.contains("Create")));
    }
}
