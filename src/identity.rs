use serde::Deserialize;
use std::{
    borrow::Cow,
    env, fs,
    io::{self, BufRead, BufReader, Read},
    os::unix::fs::{FileTypeExt, MetadataExt},
    path::{Path, PathBuf},
};

pub(crate) struct Paths {
    breadcrumbs: PathBuf,
    notifications: PathBuf,
}

impl Paths {
    pub(crate) fn discover() -> Option<Self> {
        let home = PathBuf::from(env::var_os("HOME")?);
        let profile = env::var("OMP_PROFILE")
            .or_else(|_| env::var("PI_PROFILE"))
            .unwrap_or_default();
        let profile = profile.trim();
        let config = env::var_os("PI_CONFIG_DIR")
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| ".omp".into());
        let mut base = home.join(config);
        let mut state = env::var_os("XDG_STATE_HOME")
            .filter(|value| !value.is_empty())
            .map(|value| PathBuf::from(value).join("omp"));
        let override_dir = env::var_os("PI_CODING_AGENT_DIR")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from);
        let notifications = override_dir.as_ref().map_or_else(
            || home.join(".omp/agent/notify-telegram/sessions"),
            |directory| directory.join("notify-telegram/sessions"),
        );
        let agent = if profile.is_empty() || profile == "default" {
            base.push("agent");
            if let Some(directory) = override_dir.filter(|directory| *directory != base) {
                state = None;
                directory
            } else {
                base
            }
        } else {
            if profile.len() > 64
                || !profile.as_bytes()[0].is_ascii_alphanumeric()
                || !profile.bytes().all(|byte| {
                    byte.is_ascii_lowercase() || byte.is_ascii_digit() || b"._-".contains(&byte)
                })
                || profile.ends_with('.')
            {
                return None;
            }
            let suffix = Path::new("profiles").join(profile);
            state = state.map(|path| path.join(&suffix));
            base.join(suffix).join("agent")
        };
        Some(Self {
            breadcrumbs: state
                .filter(|path| path.is_dir())
                .unwrap_or(agent)
                .join("terminal-sessions"),
            notifications,
        })
    }

    pub(crate) fn lookup(
        &self,
        terminal: &str,
        directory: &Path,
        session: &str,
        index: &str,
        pane: &str,
    ) -> Option<(String, String, String)> {
        let key = terminal.strip_prefix("/dev/")?;
        if key.split('/').any(|part| matches!(part, "" | "." | "..")) {
            return None;
        }
        let mut crumb = fs::File::open(self.breadcrumbs.join(key.replace('/', "-"))).ok()?;
        let stored = crumb.metadata().ok()?;
        let device = fs::metadata(terminal).ok()?;
        // A reused PTY can have the same number and working directory as its predecessor.
        if !stored.is_file()
            || !device.file_type().is_char_device()
            || (stored.mtime(), stored.mtime_nsec()) < (device.ctime(), device.ctime_nsec())
        {
            return None;
        }
        let mut text = String::new();
        crumb.read_to_string(&mut text).ok()?;
        let identity = breadcrumb_identity(&text, directory)?;
        let (code, tag) = self
            .badge(&identity, session, index, pane)
            .unwrap_or_default();
        Some((identity, code, tag))
    }

    fn badge(
        &self,
        identity: &str,
        session: &str,
        index: &str,
        pane: &str,
    ) -> Option<(String, String)> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Badge<'a> {
            #[serde(borrow)]
            tmux: Cow<'a, str>,
            tmux_window: u32,
            tmux_pane: &'a str,
            #[serde(default)]
            code: &'a str,
            #[serde(default)]
            tag: &'a str,
        }
        let bytes = fs::read(self.notifications.join(format!("{identity}.json"))).ok()?;
        let badge: Badge<'_> = serde_json::from_slice(&bytes).ok()?;
        if badge.tmux != session
            || Some(badge.tmux_window) != index.parse().ok()
            || badge.tmux_pane != pane
        {
            return None;
        }
        let code = if (1..=6).contains(&badge.code.len())
            && badge
                .code
                .bytes()
                .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit())
        {
            badge.code
        } else {
            ""
        };
        let tag = if badge.tag.len() == 5
            && badge
                .tag
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
        {
            badge.tag
        } else {
            ""
        };
        Some((code.into(), tag.into()))
    }
}

pub(crate) fn valid_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(position, byte)| {
            if matches!(position, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

fn managed_identity(path: &Path) -> Option<&str> {
    let (stamp, identity) = path
        .file_name()?
        .to_str()?
        .strip_suffix(".jsonl")?
        .rsplit_once('_')?;
    let pattern = b"0000-00-00T00-00-00-000Z";
    (stamp.len() == pattern.len()
        && stamp.bytes().zip(pattern).all(|(byte, &expected)| {
            if expected == b'0' {
                byte.is_ascii_digit()
            } else {
                byte == expected
            }
        })
        && valid_uuid(identity))
    .then_some(identity)
}

fn breadcrumb_identity(text: &str, current: &Path) -> Option<String> {
    let mut lines = text.lines();
    let recorded = Path::new(lines.next()?);
    let target = lines.next()?;
    if !recorded.is_absolute() || target.is_empty() {
        return None;
    }
    let current_stat = fs::metadata(current).ok()?;
    if !current_stat.is_dir() {
        return None;
    }
    let mut fresh = false;
    let mut same_directory = recorded == current;
    for line in lines {
        if line == "fresh" {
            fresh = true;
        }
        if let Some(identity) = line.strip_prefix("cwdstat ") {
            let (device, inode) = identity.split_once(' ')?;
            if device.parse::<u64>().ok()? != current_stat.dev()
                || inode.parse::<u64>().ok()? != current_stat.ino()
            {
                return None;
            }
            same_directory = true;
        }
    }
    if !same_directory {
        return None;
    }
    let path = recorded.join(target);
    match fs::metadata(&path) {
        Ok(stat) if stat.is_file() => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound && fresh => {
            return managed_identity(&path).map(str::to_owned)
        }
        _ => return None,
    }
    if let Some(identity) = managed_identity(&path) {
        return Some(identity.to_owned());
    }
    #[derive(Deserialize)]
    struct Header<'a> {
        #[serde(rename = "type")]
        kind: &'a str,
        #[serde(default)]
        id: &'a str,
        #[serde(borrow, default)]
        cwd: Cow<'a, str>,
    }
    let mut input = BufReader::new(fs::File::open(path).ok()?).take(64 * 1024);
    let mut line = Vec::new();
    for position in 0..2 {
        line.clear();
        input.read_until(b'\n', &mut line).ok()?;
        if input.limit() == 0 && !line.ends_with(b"\n") {
            return None;
        }
        let header: Header<'_> = serde_json::from_slice(&line).ok()?;
        if position == 0 && header.kind == "title" {
            continue;
        }
        return (header.kind == "session"
            && Path::new(header.cwd.as_ref()) == recorded
            && valid_uuid(header.id))
        .then(|| header.id.to_owned());
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    const SESSION: &str = "11111111-1111-4111-8111-111111abcdef";

    #[test]
    fn exact_terminal_and_directory_select_only_the_current_session() {
        let directory = env::temp_dir().join(format!("omp-dock-native-{}", std::process::id()));
        fs::create_dir(&directory).unwrap();
        let paths = Paths {
            breadcrumbs: directory.join("terminal-sessions"),
            notifications: directory.join("notifications"),
        };
        fs::create_dir(&paths.breadcrumbs).unwrap();
        let lookup = || paths.lookup("/dev/null", &directory, "work", "7", "%13");
        assert_eq!(lookup(), None);
        let crumb = paths.breadcrumbs.join("null");
        let target = format!("2026-03-04T15-16-17-123Z_{SESSION}.jsonl");
        let write = |cwd: &Path, target: &str, extras: &str| {
            fs::write(&crumb, format!("{}\n{target}\n{extras}", cwd.display())).unwrap();
        };
        write(Path::new("/"), &target, "fresh\n");
        assert_eq!(lookup(), None);
        write(&directory, &target, "fresh\ncwdstat 0 0\n");
        assert_eq!(lookup(), None);
        write(&directory, &target, "");
        assert_eq!(lookup(), None);
        write(&directory, "bad-name.jsonl", "fresh\n");
        assert_eq!(lookup(), None);
        write(&directory, &target, "fresh\n");
        assert_eq!(
            lookup(),
            Some((SESSION.into(), String::new(), String::new()))
        );
        fs::File::open(&crumb)
            .unwrap()
            .set_modified(std::time::SystemTime::UNIX_EPOCH)
            .unwrap();
        assert_eq!(lookup(), None);
        write(&directory, &target, "fresh\n");
        assert_eq!(
            paths.lookup("/dev/zero", &directory, "work", "7", "%13"),
            None
        );
        fs::create_dir(&paths.notifications).unwrap();
        let record = paths.notifications.join(format!("{SESSION}.json"));
        for (body, code, tag) in [
            ("{broken}", "", ""),
            (
                r#"{"tmux":"foreign","tmuxPane":"%13","tmuxWindow":7,"code":"BUILD","tag":"j3l6e"}"#,
                "",
                "",
            ),
            (
                r#"{"tmux":"work","tmuxPane":"%13","tmuxWindow":7,"tag":"j3l6e"}"#,
                "",
                "j3l6e",
            ),
            (
                r#"{"tmux":"work","tmuxPane":"%13","tmuxWindow":7,"code":"BUILD","tag":"j3l6e"}"#,
                "BUILD",
                "j3l6e",
            ),
        ] {
            fs::write(&record, body).unwrap();
            assert_eq!(lookup(), Some((SESSION.into(), code.into(), tag.into())));
        }
        write(&directory, "custom.jsonl", "");
        let header = format!(
            "{{\"type\":\"session\",\"id\":\"{SESSION}\",\"cwd\":{}}}\n",
            serde_json::to_string(&directory).unwrap()
        );
        for title in ["", "{\"type\":\"title\",\"v\":1,\"title\":\"Study\"}\n"] {
            fs::write(directory.join("custom.jsonl"), format!("{title}{header}")).unwrap();
            assert_eq!(
                lookup(),
                Some((SESSION.into(), "BUILD".into(), "j3l6e".into()))
            );
        }
        fs::remove_dir_all(directory).unwrap();
    }
}
