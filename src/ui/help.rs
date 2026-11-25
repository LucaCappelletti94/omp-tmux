use std::ops::Range;

use crossterm::event::KeyCode;
use ratatui::{layout::Rect, style::Modifier, text::Span, Frame};

use super::{take_rows, tone, wrapped_lines, ACCENT, MUTED};

const SECTIONS: &[(&str, &[&str])] = &[
    (
        "Find and open",
        &[
            "Type or /   Search by keyword or ID",
            "↑ / ↓       Previous / next, wrapping",
            "Enter       Open agent or toggle group",
            "Backspace   Erase a search character",
            "Esc         Clear search or focus work",
            "Tab         Full / compact view",
            "PgUp/PgDn   Scroll long details",
            "Shift+Tab   Focus dock / hide it",
            "? / F1      Help (use F1 in a field)",
        ],
    ),
    (
        "Groups and attention",
        &[
            "← / →       Collapse / expand group",
            "Ctrl+g      Move agent to a group",
            "Type        Find or create a group",
            "↑ / ↓       Choose a destination",
            "Ungrouped   Remove group membership",
            "Enter / Esc Confirm / cancel move",
            "Ctrl+t      Triage by attention & age",
            "Ctrl+s      Show / hide working text",
        ],
    ),
    (
        "Two live prompts",
        &[
            "Ctrl+p      Pair with selected agent",
            "Prefix      Ctrl+b, then release",
            "Prefix o    Focus the other prompt",
            "Prefix Space  Switch split direction",
            "Shift+Tab   Close pair at this prompt",
        ],
    ),
    (
        "Window shortcuts",
        &[
            "Prefix 0–9  Jump to a window",
            "Prefix '    Multi-digit window + Enter",
            "Prefix A    Agent menu (default key)",
        ],
    ),
    (
        "Inside the agent menu",
        &[
            "u / w / d   Urgent / waiting / bells",
            "p / x       Priority / completed",
            "h / c       Set / clear priority",
            "f / l       Focus / toggle the dock",
            "s / r       Show / lay out bottom bar",
            "/           Find labels (tmux 3.3+)",
        ],
    ),
];

#[derive(Default)]
pub(super) struct Help {
    lines: Vec<&'static str>,
    headings: [Range<usize>; SECTIONS.len()],
    width: u16,
    page: usize,
    first: usize,
}

impl Help {
    pub(super) fn scroll(&mut self, key: KeyCode) -> bool {
        let last = self.lines.len().saturating_sub(self.page);
        let next = match key {
            KeyCode::Up => self.first.saturating_sub(1),
            KeyCode::Down => self.first.saturating_add(1),
            KeyCode::PageUp => self.first.saturating_sub(self.page),
            KeyCode::PageDown => self.first.saturating_add(self.page),
            KeyCode::Home => 0,
            KeyCode::End => last,
            _ => return false,
        }
        .min(last);
        let changed = next != self.first;
        self.first = next;
        changed
    }

    pub(super) fn draw(&mut self, frame: &mut Frame<'_>, mut area: Rect) {
        if area.is_empty() {
            return;
        }
        if self.width != area.width {
            self.width = area.width;
            self.lines.clear();
            for ((title, bindings), heading) in SECTIONS.iter().zip(&mut self.headings) {
                *heading = wrapped_lines(title, area.width, usize::MAX, &mut self.lines);
                for binding in *bindings {
                    wrapped_lines(binding, area.width, usize::MAX, &mut self.lines);
                }
            }
        }
        let height = area.height - u16::from(area.height > 1);
        let body = take_rows(&mut area, height);
        self.page = usize::from(height);
        self.first = self.first.min(self.lines.len().saturating_sub(self.page));
        for ((index, text), row) in self
            .lines
            .iter()
            .enumerate()
            .skip(self.first)
            .zip(body.rows())
        {
            let mut line = Span::raw(*text);
            if self.headings.iter().any(|heading| heading.contains(&index)) {
                line = line.style(tone(ACCENT).add_modifier(Modifier::BOLD));
            }
            frame.render_widget(line, row);
        }
        frame.render_widget(
            Span::styled("Esc back  ↑↓ scroll  PgUp/Dn  Home/End", tone(MUTED)),
            area,
        );
    }
}
