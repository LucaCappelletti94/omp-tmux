use std::cmp::Reverse;
use std::collections::{BTreeSet, HashMap};
use std::time::{Duration, SystemTime};

use super::{matches, Activity, Entry};
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

/// Wall-clock second, native bell serial, then local observation within that serial.
type SignalTime = (u64, u64, u64);

#[derive(Default)]
struct Signal<T> {
    value: T,
    since: Option<SignalTime>,
}

impl<T: Default + PartialEq> Signal<T> {
    fn update(&mut self, value: T, observed: Option<SignalTime>) -> Option<SignalTime> {
        if self.value != value {
            self.since = observed.filter(|_| value != T::default());
            self.value = value;
        }
        self.since
    }
}

#[derive(Default)]
struct WindowSignals {
    request: Signal<Option<Activity>>,
    priority: Signal<bool>,
    bell: Signal<bool>,
    generation: u64,
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct TriageKey {
    attention: bool,
    recency: Option<SignalTime>,
    created: Option<Duration>,
    window: u32,
}

#[derive(Default)]
pub(super) struct Roster {
    pub(super) rows: Vec<Row>,
    pub(super) count: usize,
    pub(super) triage: bool,
    grouped_order: Vec<usize>,
    collapsed: BTreeSet<String>,
    windows: HashMap<u32, WindowSignals>,
    keys: Vec<TriageKey>,
    latest_ping: Option<(u64, u64)>,
    generation: u64,
}

impl Roster {
    pub(super) fn observe(&mut self, entries: &[Entry]) {
        self.generation += 1;
        let observed = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .ok()
            .map(|time| {
                let seconds = time.as_secs();
                let serial = self
                    .latest_ping
                    .filter(|ping| ping.0 == seconds)
                    .map_or(0, |ping| ping.1);
                (seconds, serial, self.generation)
            });
        self.keys.clear();
        for entry in entries {
            let window = entry
                .window_id
                .strip_prefix('@')
                .and_then(|id| id.parse().ok())
                .unwrap_or(0);
            let signals = self.windows.entry(window).or_default();
            let noticed = observed.filter(|_| signals.generation != 0);
            let request = match entry.activity {
                Activity::Waiting | Activity::Crashed | Activity::Urgent => Some(entry.activity),
                _ => None,
            };
            let request_time = signals.request.update(request, noticed);
            let priority_time = signals.priority.update(entry.priority, noticed);
            let observed_bell = signals.bell.update(entry.bell, noticed);
            let bell_time = match (entry.bell, entry.ping) {
                (true, Some((seconds, serial))) => Some((seconds, serial, 0)),
                _ => observed_bell,
            };
            signals.generation = self.generation;
            self.latest_ping = self.latest_ping.max(entry.ping);
            self.keys.push(TriageKey {
                attention: request.is_some() || entry.priority || entry.bell,
                recency: request_time
                    .max(priority_time)
                    .max(bell_time)
                    .or_else(|| entry.created.map(|created| (created.as_secs(), 0, 0))),
                created: entry.created,
                window,
            });
        }
        self.windows
            .retain(|_, signals| signals.generation == self.generation);
    }

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
                    Reverse(self.keys[index])
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
