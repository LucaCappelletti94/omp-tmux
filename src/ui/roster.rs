use std::collections::BTreeSet;

use super::{matches, Entry};
use crate::groups::UNGROUPED;

pub(super) fn group_label(name: &str) -> &str {
    if name.is_empty() {
        UNGROUPED
    } else {
        name
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Row {
    Agent(usize),
    Group(usize),
}

impl Row {
    pub(super) fn member(self, entries: &[Entry]) -> Option<&Entry> {
        match self {
            Self::Agent(index) => Some(&entries[index]),
            Self::Group(_) => None,
        }
    }

    pub(super) fn group(self, entries: &[Entry]) -> &str {
        let (Self::Agent(index) | Self::Group(index)) = self;
        &entries[index].group
    }

    pub(super) fn retain(self, previous: &[Entry], entries: &[Entry]) -> Option<Self> {
        match self {
            Self::Agent(index) => entries
                .iter()
                .position(|entry| entry.window_id == previous[index].window_id)
                .map(Self::Agent),
            Self::Group(index) => entries
                .iter()
                .position(|entry| entry.group == previous[index].group)
                .map(Self::Group),
        }
    }
}

#[derive(Default)]
pub(super) struct Roster {
    pub(super) rows: Vec<Row>,
    pub(super) count: usize,
    pub(super) triage: bool,
    grouped_order: Vec<usize>,
    collapsed: BTreeSet<String>,
}

impl Roster {
    pub(super) fn index_groups(&mut self, entries: &[Entry]) {
        self.grouped_order.clear();
        if entries.iter().any(|entry| !entry.group.is_empty()) {
            self.grouped_order.extend(0..entries.len());
            self.grouped_order.sort_unstable_by_key(|&index| {
                let name = entries[index].group.as_str();
                (name.is_empty(), name, index)
            });
        }
    }

    pub(super) fn grouped(&self, query: &str) -> bool {
        !self.triage && query.is_empty() && !self.grouped_order.is_empty()
    }

    pub(super) fn is_collapsed(&self, name: &str) -> bool {
        self.collapsed.contains(name)
    }

    pub(super) fn expand(&mut self, name: &str) -> bool {
        self.collapsed.remove(name)
    }

    pub(super) fn collapse(&mut self, name: &str) -> bool {
        if self.is_collapsed(name) {
            return false;
        }
        self.collapsed.insert(name.to_owned())
    }

    pub(super) fn project(&mut self, entries: &[Entry], query: &str) {
        self.rows.clear();
        if self.grouped(query) {
            for group in self
                .grouped_order
                .chunk_by(|&left, &right| entries[left].group == entries[right].group)
            {
                let first = group[0];
                self.rows.push(Row::Group(first));
                if !self.collapsed.contains(&entries[first].group) {
                    self.rows.extend(group.iter().copied().map(Row::Agent));
                }
            }
            self.count = entries.len();
        } else {
            let needle = query.to_lowercase();
            self.rows.extend(
                entries.iter().enumerate().filter_map(|(index, entry)| {
                    matches(entry, &needle).then_some(Row::Agent(index))
                }),
            );
            if self.triage {
                self.rows.sort_unstable_by_key(|&row| {
                    let Row::Agent(index) = row else {
                        unreachable!("triage contains only agents")
                    };
                    let entry = &entries[index];
                    let rank = match entry.activity {
                        super::Activity::Urgent => 0,
                        super::Activity::Crashed => 1,
                        super::Activity::Waiting => 2,
                        _ if entry.priority => 3,
                        _ if entry.bell => 4,
                        _ => 5,
                    };
                    (rank, index)
                });
            }
            self.count = self.rows.len();
        }
    }

    pub(super) fn position(&self, target: Row, entries: &[Entry]) -> Option<usize> {
        let group = target.group(entries);
        let heading = matches!(target, Row::Group(_)) || self.is_collapsed(group);
        self.rows.iter().position(|&row| {
            row == target
                || (heading && matches!(row, Row::Group(_)) && row.group(entries) == group)
        })
    }
}
