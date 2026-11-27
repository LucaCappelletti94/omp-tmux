use crate::{
    groups::{GroupStore, UNGROUPED},
    identity::Session,
};
use std::{
    borrow::Cow, collections::BTreeSet, ffi::OsString, io, process::Command, time::Duration,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum Activity {
    Idle,
    Done,
    Sleeping,
    Working,
    Waiting,
    Crashed,
    Urgent,
}

impl Activity {
    pub(crate) fn requests_attention(self) -> bool {
        matches!(self, Self::Waiting | Self::Crashed | Self::Urgent)
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Entry {
    pub window_id: String,
    pub index: String,
    pub pane_id: String,
    pub session_id: String,
    pub session_code: String,
    pub session_tag: String,
    pub group: String,
    pub title: String,
    pub description: String,
    pub status_message: String,
    pub directory: String,
    pub activity: Activity,
    pub priority: bool,
    pub bell: bool,
    pub ping: Option<(u64, u64)>,
    pub created: Option<Duration>,
    pub current: bool,
}

impl Entry {
    pub(crate) fn requires_attention(&self) -> bool {
        self.activity.requests_attention() || self.bell || self.priority
    }
}

#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct DockView {
    pub triage: bool,
    pub group: Option<String>,
    pub attention_only: bool,
}

impl DockView {
    pub(crate) fn includes(&self, entry: &Entry) -> bool {
        self.group
            .as_ref()
            .is_none_or(|group| *group == entry.group)
            && (!self.attention_only || entry.requires_attention())
    }
}

#[derive(Clone, Copy)]
pub(crate) enum ViewSetting {
    Triage,
    Group,
    AttentionOnly,
}

const TRIAGE_OPTION: &str = "@omp_dock_triage";
const FOCUS_GROUP_OPTION: &str = "@omp_dock_focus_group";
const ATTENTION_OPTION: &str = "@omp_dock_attention_only";
const FOLDED_GROUPS_OPTION: &str = "@omp_dock_folded_groups";

fn snapshot_preferences<'a>(
    records: &mut std::iter::Peekable<impl Iterator<Item = &'a str>>,
) -> (DockView, bool) {
    let mut enabled = |option: &str| {
        records
            .next_if(|line| line.starts_with(option))
            .is_some_and(|line| line.strip_prefix(option) == Some(" on"))
    };
    let triage = enabled(TRIAGE_OPTION);
    let attention_only = enabled(ATTENTION_OPTION);
    let status_text = records.next() == Some("on");
    // A valid group has no control characters. Every pane record contains tabs.
    let group = match records.next_if(|line| !line.contains('\t')) {
        None | Some("") => None,
        Some(UNGROUPED) => Some(String::new()),
        Some(name) => Some(name.to_owned()),
    };
    (
        DockView {
            triage,
            group,
            attention_only,
        },
        status_text,
    )
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Snapshot {
    pub entries: Vec<Entry>,
    pub focused: bool,
    pub active_window: String,
    pub group_error: Option<String>,
    pub status_text: bool,
    pub view: DockView,
}

pub(crate) struct Server {
    socket: OsString,
    session: String,
    pane: String,
    identities: Option<crate::identity::Paths>,
    groups: GroupStore,
}

const PANE_FORMAT: &str = concat!(
    "#{window_id}\t#{window_index}\t",
    "#{window_active}\t#{pane_id}\t#{pane_active}\t#{pane_last}\t",
    "#{||:#{@omp_navigator},#{@omp_dock_slot}}\t",
    "#{s/[\x01-\x1f\x7f]/ /:pane_title}\t#{s/[\x01-\x1f\x7f]/ /:window_name}\t",
    "#{s/[\x01-\x1f\x7f]/ /:pane_current_path}\t#{@omp_state}\t#{@omp_priority}\t#{window_bell_flag}\t",
    "#{@omp_dock_slot}\t#{&&:#{@omp_dock_reserved},",
    "#{&&:#{==:#{window_linked},0},#{&&:#{==:#{window_zoomed_flag},0},#{e|>=:#{window_width},76}}}}\t",
    "#{pane_tty}\t#{pane_dead}\t#{?#{e|>:#{pane_height},32},#{e|-:#{pane_height},32},0}\t#{session_name}\t",
    "#{@omp_dock_ping}\t#{@omp_dock_created}"
);

impl Server {
    pub(crate) fn new(socket: OsString, session: String, pane: String) -> Self {
        Self {
            socket,
            session,
            pane,
            identities: crate::identity::Paths::discover(),
            groups: GroupStore::discover(),
        }
    }

    fn command(&self, arguments: &[&str]) -> io::Result<String> {
        self.command_with_prefix(&[], arguments)
    }

    fn command_with_prefix(&self, prefix: &[&str], arguments: &[&str]) -> io::Result<String> {
        let output = Command::new("tmux")
            .arg("-S")
            .arg(&self.socket)
            .args(prefix)
            .args(arguments)
            .output()?;
        if !output.status.success() {
            return Err(io::Error::other(
                String::from_utf8_lossy(&output.stderr).trim().to_owned(),
            ));
        }
        String::from_utf8(output.stdout)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
    }

    fn session_identity(&self, work: &Pane<'_>) -> Session {
        self.identities
            .as_ref()
            .filter(|_| !work.dead && work.state != "crashed")
            .and_then(|paths| {
                paths.lookup(
                    work.terminal,
                    work.directory.as_ref(),
                    work.session_name,
                    work.index,
                    work.pane_id,
                )
            })
            .unwrap_or_default()
    }

    pub(crate) fn group_names(&self) -> io::Result<Vec<String>> {
        self.groups.names()
    }

    pub(crate) fn move_to_group(
        &self,
        window_id: &str,
        pane_id: &str,
        session_id: &str,
        name: Option<&str>,
    ) -> io::Result<()> {
        let target = format!("{}:{window_id}.{pane_id}", self.session);
        let record = self.command(&["display-message", "-p", "-t", &target, PANE_FORMAT])?;
        let same_agent = parse_pane(record.trim_end_matches('\n')).is_some_and(|pane| {
            pane.window_id == window_id
                && pane.pane_id == pane_id
                && !pane.dock
                && !session_id.is_empty()
                && pane.agent().is_some()
                && self.session_identity(&pane).id == session_id
        });
        if !same_agent {
            return Err(io::Error::other(
                "The original OMP session is no longer in this pane",
            ));
        }
        self.groups.assign(session_id, name)
    }

    pub(crate) fn set_status_text(&self, enabled: bool) -> io::Result<()> {
        self.command(&[
            "set-option",
            "-t",
            &self.session,
            "@omp_dock_status_text",
            if enabled { "on" } else { "off" },
        ])?;
        Ok(())
    }

    pub(crate) fn folded_groups(&self) -> io::Result<BTreeSet<String>> {
        let value = self.command(&["show-options", "-qvt", &self.session, FOLDED_GROUPS_OPTION])?;
        if value.trim_end_matches('\n').is_empty() {
            return Ok(BTreeSet::new());
        }
        Ok(serde_json::from_str(&value)?)
    }

    pub(crate) fn save_folded_groups(&self, groups: &BTreeSet<String>) -> io::Result<()> {
        let value = serde_json::to_string(groups)?;
        self.command(&[
            "set-option",
            "-t",
            &self.session,
            FOLDED_GROUPS_OPTION,
            &value,
        ])?;
        Ok(())
    }

    pub(crate) fn save_view_setting(
        &self,
        view: &DockView,
        setting: ViewSetting,
    ) -> io::Result<()> {
        let (option, value) = match setting {
            ViewSetting::Triage => (TRIAGE_OPTION, if view.triage { "on" } else { "off" }),
            ViewSetting::AttentionOnly => (
                ATTENTION_OPTION,
                if view.attention_only { "on" } else { "off" },
            ),
            ViewSetting::Group => (
                FOCUS_GROUP_OPTION,
                match view.group.as_deref() {
                    Some("") => UNGROUPED,
                    Some(name) => name,
                    None => "",
                },
            ),
        };
        // tmux consumes one backslash before a trailing semicolon in an argv element.
        let value = match value.strip_suffix(';') {
            Some(prefix) => {
                let mut argument = String::with_capacity(value.len() + 1);
                argument.push_str(prefix);
                argument.push_str(r"\;");
                Cow::Owned(argument)
            }
            None => Cow::Borrowed(value),
        };
        self.command(&["set-option", "-t", &self.session, "--", option, &value])?;
        Ok(())
    }

    pub(crate) fn snapshot(&self) -> io::Result<Option<Snapshot>> {
        self.read_snapshot(true)
    }

    fn read_snapshot(&self, include_dock_view: bool) -> io::Result<Option<Snapshot>> {
        // Format expansion in display-message would let pane options shadow session preferences.
        let metadata: &[&str] = if include_dock_view {
            &[
                "show-options",
                "-qt",
                &self.session,
                TRIAGE_OPTION,
                ";",
                "show-options",
                "-qt",
                &self.session,
                ATTENTION_OPTION,
                ";",
                "display-message",
                "-p",
                "-t",
                &self.session,
                "#{?#{==:#{@omp_dock_status_text},on},on,off}",
                ";",
                "show-options",
                "-qvt",
                &self.session,
                FOCUS_GROUP_OPTION,
                ";",
            ]
        } else {
            &[]
        };
        let records = self.command_with_prefix(
            metadata,
            &["list-panes", "-s", "-t", &self.session, "-F", PANE_FORMAT],
        )?;
        let mut records = records.lines().peekable();
        let (view, status_text) = if include_dock_view {
            snapshot_preferences(&mut records)
        } else {
            (DockView::default(), false)
        };
        let mut targets = Vec::new();
        let mut entries = Vec::new();
        let mut group_error = None;
        let mut active_window = String::new();
        let mut panes = records.filter_map(parse_pane).peekable();
        let mut focused = false;
        let mut has_work_pane = false;
        let mut repair_slots = false;
        while let Some(first) = panes.next() {
            if first.current {
                active_window.push_str(first.window_id);
            }
            let mut preferred = None;
            let mut best_rank = (false, false);
            let mut activity = Activity::Idle;
            let mut hosts_dock = false;
            let mut has_neighbor = false;
            let mut owns_slot = false;
            let mut candidate = first;
            loop {
                owns_slot |= candidate.slot_owner == self.session;
                if candidate.pane_id == self.pane {
                    focused = candidate.active;
                    hosts_dock = true;
                } else if !candidate.dock {
                    has_neighbor = true;
                    if let Some((state, label)) = candidate.agent() {
                        activity = activity.max(state);
                        let rank = (candidate.active, candidate.last);
                        if preferred.is_none() || rank > best_rank {
                            preferred = Some((candidate, state, label));
                            best_rank = rank;
                        }
                    }
                }
                match panes.next_if(|next| next.window_id == first.window_id) {
                    Some(next) => candidate = next,
                    None => break,
                }
            }
            has_work_pane |= hosts_dock && has_neighbor;
            repair_slots |= (owns_slot && !has_neighbor) || (first.expects_slot && !owns_slot);
            let Some((work, work_activity, label)) = preferred else {
                continue;
            };
            let (title, description) = label.split_once(": ").unwrap_or((label, ""));
            let session = self.session_identity(&work);
            let group = if session.id.is_empty() {
                String::new()
            } else {
                match self.groups.lookup(&session.id) {
                    Ok(name) => name.unwrap_or_default(),
                    Err(error) => {
                        group_error.get_or_insert_with(|| {
                            format!("Cannot read group for window {} ({error})", work.index)
                        });
                        String::new()
                    }
                }
            };
            let entry = Entry {
                window_id: work.window_id.to_owned(),
                index: work.index.to_owned(),
                pane_id: work.pane_id.to_owned(),
                session_id: session.id,
                session_code: session.code,
                session_tag: session.tag,
                group,
                title: title.to_owned(),
                description: description.to_owned(),
                status_message: String::new(),
                directory: work.directory.to_owned(),
                activity,
                priority: work.priority,
                bell: work.bell,
                ping: parse_ping(work.ping),
                created: session
                    .created
                    .or_else(|| work.created.parse().ok().map(Duration::from_secs)),
                current: work.current,
            };
            if status_text
                && work_activity == Activity::Working
                && !work.dead
                && view.includes(&entry)
            {
                targets.push((entries.len(), work.pane_id, work.capture_start));
            }
            entries.push(entry);
        }
        if repair_slots {
            self.command(&[
                "run-shell",
                "-b",
                "-t",
                &self.session,
                "#{E:@omp_dock_command} follow #{q:socket_path} #{q:session_id}",
            ])?;
        }
        if has_work_pane && !targets.is_empty() {
            let mut arguments = Vec::with_capacity(targets.len() * 13);
            for (_, pane, start) in &targets {
                if !arguments.is_empty() {
                    arguments.push(";");
                }
                arguments.extend([
                    "display-message",
                    "-p",
                    "-t",
                    *pane,
                    crate::working_status::PANE_HEADER,
                    ";",
                    "capture-pane",
                    "-p",
                    "-t",
                    *pane,
                    "-S",
                    *start,
                ]);
            }
            if let Ok(batch) = self.command(&arguments) {
                let mut messages = crate::working_status::messages(&batch).peekable();
                for (index, pane, _) in targets {
                    if let Some((_, message)) = messages.next_if(|(source, _)| *source == pane) {
                        entries[index].status_message.push_str(message);
                    }
                }
            }
        }
        Ok(has_work_pane.then_some(Snapshot {
            entries,
            focused,
            active_window,
            group_error,
            status_text,
            view,
        }))
    }

    pub(crate) fn pair_with(&self, selected: &Entry) -> io::Result<()> {
        let snapshot = self
            .read_snapshot(false)?
            .ok_or_else(|| io::Error::other("The dock has closed"))?;
        let current = snapshot
            .entries
            .iter()
            .find(|entry| entry.current)
            .ok_or_else(|| io::Error::other("Start from a window with a running OMP session"))?;
        if current.window_id == selected.window_id {
            return Err(io::Error::other(
                "Highlight a different session to pair with this one",
            ));
        }
        if !snapshot
            .entries
            .iter()
            .any(|entry| entry.window_id == selected.window_id && entry.pane_id == selected.pane_id)
        {
            return Err(io::Error::other("The other session is no longer available"));
        }
        let plugin = self.command(&["show-options", "-gqv", "@omp_tmux_dir"])?;
        let plugin = std::path::Path::new(plugin.trim_end_matches('\n'));
        if !plugin.is_absolute() {
            return Err(io::Error::other(
                "Cannot locate the omp-tmux pairing helper",
            ));
        }
        let output = Command::new("sh")
            .arg(plugin.join("scripts/omp-pair.sh"))
            .arg("open")
            .arg(&self.socket)
            .args([
                &self.session,
                &current.window_id,
                &current.pane_id,
                &selected.window_id,
                &selected.pane_id,
            ])
            .output()?;
        if output.status.success() {
            Ok(())
        } else {
            Err(io::Error::other(
                String::from_utf8_lossy(&output.stderr).trim().to_owned(),
            ))
        }
    }

    pub(crate) fn activate(&self, entry: &Entry) -> io::Result<()> {
        let window = format!("{}:{}", self.session, entry.window_id);
        let target = format!("{window}.{}", entry.pane_id);
        let record = self.command(&["display-message", "-p", "-t", &target, PANE_FORMAT])?;
        if !parse_pane(record.trim_end_matches('\n')).is_some_and(|pane| {
            pane.window_id == entry.window_id
                && pane.pane_id == entry.pane_id
                && pane.pane_id != self.pane
                && !pane.dock
                && pane.agent().is_some()
        }) {
            return Err(io::Error::other("Selected agent is no longer available"));
        }
        let cancel_copy_mode = format!("send-keys -t {} -X cancel", entry.pane_id);
        self.command(&[
            "if-shell",
            "-F",
            "-t",
            &target,
            "#{==:#{pane_mode},copy-mode}",
            &cancel_copy_mode,
            ";",
            "select-pane",
            "-t",
            &target,
            ";",
            "select-window",
            "-t",
            &window,
        ])?;
        Ok(())
    }

    pub(crate) fn leave(&self) -> io::Result<()> {
        self.command(&["select-pane", "-l", "-t", &self.pane])?;
        Ok(())
    }
}

#[derive(Clone, Copy)]
struct Pane<'a> {
    window_id: &'a str,
    index: &'a str,
    current: bool,
    pane_id: &'a str,
    active: bool,
    last: bool,
    dock: bool,
    title: &'a str,
    window_name: &'a str,
    directory: &'a str,
    state: &'a str,
    priority: bool,
    bell: bool,
    slot_owner: &'a str,
    expects_slot: bool,
    terminal: &'a str,
    dead: bool,
    session_name: &'a str,
    capture_start: &'a str,
    ping: &'a str,
    created: &'a str,
}

fn parse_pane(record: &str) -> Option<Pane<'_>> {
    let mut fields = record.split('\t');
    Some(Pane {
        window_id: fields.next()?,
        index: fields.next()?,
        current: fields.next()? == "1",
        pane_id: fields.next()?,
        active: fields.next()? == "1",
        last: fields.next()? == "1",
        dock: fields.next()? == "1",
        title: fields.next()?,
        window_name: fields.next()?,
        directory: fields.next()?,
        state: fields.next()?,
        priority: fields.next()? == "high",
        bell: fields.next()? == "1",
        slot_owner: fields.next()?,
        expects_slot: fields.next()? == "1",
        terminal: fields.next()?,
        dead: fields.next()? == "1",
        capture_start: fields.next()?,
        session_name: fields.next()?,
        ping: fields.next().unwrap_or_default(),
        created: fields.next().unwrap_or_default(),
    })
}

fn parse_ping(stamp: &str) -> Option<(u64, u64)> {
    let (seconds, serial) = stamp.split_once('.')?;
    let serial = serial.parse().ok()?;
    (serial != 0).then_some((seconds.parse().ok()?, serial))
}

impl<'a> Pane<'a> {
    fn agent(&self) -> Option<(Activity, &'a str)> {
        if let Some((marker, label)) = self
            .title
            .strip_prefix("π ")
            .and_then(|title| title.split_once(' '))
            .filter(|(_, label)| !label.is_empty())
        {
            let activity = match marker {
                ">" => match self.state {
                    "urgent" => Activity::Urgent,
                    "reply" => Activity::Waiting,
                    "sleeping" => Activity::Sleeping,
                    "done" => Activity::Done,
                    _ => Activity::Idle,
                },
                "!" => Activity::Waiting,
                marker if crate::working_status::spinner(marker) => Activity::Working,
                _ => return self.crashed(),
            };
            return Some((activity, label));
        }
        self.crashed()
    }

    fn crashed(&self) -> Option<(Activity, &'a str)> {
        (self.state == "crashed").then_some((Activity::Crashed, self.window_name))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_group_labels_and_reserved_scopes_survive_snapshot_framing() {
        for (label, expected) in [
            (None, None),
            (Some(""), None),
            (Some("Ungrouped"), Some("")),
            (Some("on"), Some("on")),
            (Some("@omp_dock_triage on"), Some("@omp_dock_triage on")),
            (
                Some(r##"-水 "#{session_id}"\;"##),
                Some(r##"-水 "#{session_id}"\;"##),
            ),
        ] {
            let mut records = ["@omp_dock_attention_only on", "off"]
                .into_iter()
                .chain(label)
                .chain(["@9\t0\t1"])
                .peekable();
            let (view, status_text) = snapshot_preferences(&mut records);
            assert!(!view.triage);
            assert!(view.attention_only);
            assert!(!status_text);
            assert_eq!(view.group.as_deref(), expected);
            assert_eq!(records.next(), Some("@9\t0\t1"));
        }
    }

    #[test]
    fn only_unresolved_requests_crashes_and_urgent_activity_need_attention() {
        for activity in [Activity::Waiting, Activity::Crashed, Activity::Urgent] {
            assert!(activity.requests_attention(), "{activity:?}");
        }
        for activity in [
            Activity::Idle,
            Activity::Working,
            Activity::Done,
            Activity::Sleeping,
        ] {
            assert!(!activity.requests_attention(), "{activity:?}");
        }
    }

    #[test]
    fn a_pane_without_native_timestamps_remains_an_agent() {
        let record =
            "@4\t1\t0\t%8\t1\t0\t0\tπ > Build\tbuild\t/tmp\t\t\t0\t\t0\t/dev/pts/8\t0\t0\twork";
        let pane = parse_pane(record).unwrap();
        assert_eq!(pane.agent(), Some((Activity::Idle, "Build")));
        assert_eq!(parse_ping(pane.ping), None);
        assert!(pane.created.is_empty());
        let native = format!("{record}\t101.3\t80");
        let pane = parse_pane(&native).unwrap();
        assert_eq!(parse_ping(pane.ping), Some((101, 3)));
        assert_eq!(pane.created, "80");
    }
}
