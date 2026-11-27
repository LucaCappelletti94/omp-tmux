use crate::identity::valid_uuid;
use std::{
    collections::BTreeSet,
    env, fs,
    io::{self, Read, Write},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt},
    path::{Path, PathBuf},
    sync::atomic::{AtomicUsize, Ordering},
};

pub(crate) const UNGROUPED: &str = "Ungrouped";

pub(crate) fn validate_name(name: &str) -> io::Result<&str> {
    if name.chars().any(char::is_control) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Group names cannot contain control characters",
        ));
    }
    let name = name.trim();
    let problem = if name.is_empty() {
        "Enter a group name"
    } else if name.eq_ignore_ascii_case(UNGROUPED) {
        "Ungrouped is reserved for agents without a group"
    } else if name.chars().nth(64).is_some() {
        "Group names can contain at most 64 characters"
    } else {
        return Ok(name);
    };
    Err(io::Error::new(io::ErrorKind::InvalidInput, problem))
}

pub(crate) struct GroupStore {
    directory: Option<PathBuf>,
}

impl GroupStore {
    pub(crate) fn discover() -> Self {
        let absolute = |key| {
            env::var_os(key)
                .map(PathBuf::from)
                .filter(|path| path.is_absolute())
        };
        let directory = absolute("XDG_STATE_HOME")
            .or_else(|| absolute("HOME").map(|path| path.join(".local/state")))
            .map(|path| path.join("omp-tmux/groups"));
        Self { directory }
    }

    fn record(&self, identity: &str) -> io::Result<Option<PathBuf>> {
        if !valid_uuid(identity) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Invalid OMP session ID for group membership",
            ));
        }
        Ok(self.directory.as_ref().map(|directory| {
            if identity.bytes().any(|byte| byte.is_ascii_uppercase()) {
                directory.join(identity.to_ascii_lowercase())
            } else {
                directory.join(identity)
            }
        }))
    }

    pub(crate) fn lookup(&self, identity: &str) -> io::Result<Option<String>> {
        match self.record(identity)? {
            Some(path) => read_record(&path),
            None => Ok(None),
        }
    }

    pub(crate) fn names(&self) -> io::Result<Vec<String>> {
        let Some(directory) = &self.directory else {
            return Ok(Vec::new());
        };
        let records = match fs::read_dir(directory) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
            records => records?,
        };
        let mut names = BTreeSet::new();
        for record in records {
            let record = record?;
            let filename = record.file_name();
            if filename.to_str().is_some_and(|name| {
                valid_uuid(name) && !name.bytes().any(|byte| byte.is_ascii_uppercase())
            }) {
                if let Some(name) = read_record(&record.path())? {
                    names.insert(name);
                }
            }
        }
        Ok(names.into_iter().collect())
    }

    pub(crate) fn assign(&self, identity: &str, name: Option<&str>) -> io::Result<()> {
        let path = self.record(identity)?.ok_or_else(|| {
            io::Error::other("Cannot save groups without an absolute XDG_STATE_HOME or HOME")
        })?;
        let name = name.map(validate_name).transpose()?;
        let existing = read_record(&path)?;
        let Some(name) = name else {
            return match fs::remove_file(&path) {
                Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
                result => result,
            };
        };
        if existing.as_deref() == Some(name) {
            return Ok(());
        }
        let directory = path
            .parent()
            .ok_or_else(|| io::Error::other("Missing group directory"))?;
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(directory)?;
        write_record(directory, &path, name)
    }
}

fn read_record(path: &Path) -> io::Result<Option<String>> {
    let metadata = match fs::symlink_metadata(path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        result => result?,
    };
    let invalid = || {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("Invalid group membership in {}", path.display()),
        )
    };
    if !metadata.is_file() || metadata.len() > 256 {
        return Err(invalid());
    }
    let file = match fs::File::open(path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        result => result?,
    };
    let mut text = String::new();
    file.take(257).read_to_string(&mut text)?;
    if validate_name(&text).ok() != Some(text.as_str()) {
        return Err(invalid());
    }
    Ok(Some(text))
}

fn write_record(directory: &Path, path: &Path, name: &str) -> io::Result<()> {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let (temporary, mut file) = loop {
        let temporary = directory.join(format!(
            ".membership-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        match fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)
        {
            Ok(file) => break (temporary, file),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        }
    };
    let result = file
        .write_all(name.as_bytes())
        .and_then(|()| fs::rename(&temporary, path));
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_are_trimmed_unicode_without_controls_or_reserved_spellings() {
        assert_eq!(validate_name("　研究 🚀　").unwrap(), "研究 🚀");
        assert!(validate_name(&"界".repeat(64)).is_ok());
        assert!(validate_name(&"界".repeat(65)).is_err());
        for invalid in ["", "  ", " UNGROUPED ", "a\u{85}b", "\tname", "name\n"] {
            assert!(validate_name(invalid).is_err(), "{invalid:?}");
        }
    }

    const FIRST: &str = "ca000000-0000-0000-0000-000000000001";
    const SECOND: &str = "ca000000-0000-0000-0000-000000000002";
    const THIRD: &str = "ca000000-0000-0000-0000-000000000003";

    struct Sandbox(PathBuf);

    impl Sandbox {
        fn new() -> Self {
            static NEXT: AtomicUsize = AtomicUsize::new(0);
            loop {
                let directory = env::temp_dir().join(format!(
                    "omp-group-test-{}-{}",
                    std::process::id(),
                    NEXT.fetch_add(1, Ordering::Relaxed)
                ));
                match fs::create_dir(&directory) {
                    Ok(()) => return Self(directory),
                    Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
                    Err(error) => panic!("creating test directory failed: {error}"),
                }
            }
        }

        fn store(&self) -> GroupStore {
            GroupStore {
                directory: Some(self.0.join("groups")),
            }
        }
    }

    impl Drop for Sandbox {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn assignments_are_private_canonical_and_independent() {
        use std::os::unix::fs::PermissionsExt;

        let sandbox = Sandbox::new();
        let store = sandbox.store();
        let directory = sandbox.0.join("groups");
        assert_eq!(store.lookup(FIRST).unwrap(), None);
        assert!(store.names().unwrap().is_empty());
        store.assign(FIRST, None).unwrap();
        assert!(!directory.exists());
        std::thread::scope(|scope| {
            scope.spawn(|| store.assign(&FIRST.to_uppercase(), Some(" 研究 ")).unwrap());
            scope.spawn(|| store.assign(SECOND, Some("Apps")).unwrap());
            scope.spawn(|| store.assign(THIRD, Some("Apps")).unwrap());
        });
        assert_eq!(store.lookup(FIRST).unwrap().as_deref(), Some("研究"));
        assert_eq!(store.names().unwrap(), ["Apps", "研究"]);
        for path in [&directory, &directory.join(FIRST)] {
            assert_eq!(fs::metadata(path).unwrap().permissions().mode() & 0o077, 0);
        }
        store.assign(FIRST, Some("Apps")).unwrap();
        store.assign(SECOND, None).unwrap();
        assert_eq!(store.names().unwrap(), ["Apps"]);
        assert_eq!(store.lookup(SECOND).unwrap(), None);
        assert_eq!(store.lookup(THIRD).unwrap().as_deref(), Some("Apps"));
    }

    #[test]
    fn absent_state_path_allows_browsing_and_refuses_edits() {
        let store = GroupStore { directory: None };
        assert!(store.names().unwrap().is_empty());
        assert_eq!(store.lookup(FIRST).unwrap(), None);
        assert!(store.assign(FIRST, Some("Work")).is_err());
        assert!(store.assign(FIRST, None).is_err());
    }

    #[test]
    fn invalid_keys_and_names_never_create_storage() {
        let sandbox = Sandbox::new();
        let store = sandbox.store();
        assert!(store.lookup("../outside").is_err());
        assert!(store.assign("../outside", Some("Work")).is_err());
        assert!(store.assign(FIRST, Some("ungrouped")).is_err());
        assert_eq!(fs::read_dir(&sandbox.0).unwrap().count(), 0);
    }

    #[test]
    fn corrupt_records_are_reported_and_never_replaced() {
        let sandbox = Sandbox::new();
        let store = sandbox.store();
        store.assign(FIRST, Some("Valid")).unwrap();
        let path = sandbox.0.join("groups").join(SECOND);
        for invalid in [&b"\xff"[..], b"invalid\n", b" padded ", b"Ungrouped"] {
            fs::write(&path, invalid).unwrap();
            assert_eq!(store.lookup(FIRST).unwrap().as_deref(), Some("Valid"));
            assert!(store.lookup(SECOND).is_err());
            assert!(store.names().is_err());
            assert!(store.assign(SECOND, Some("Work")).is_err());
            assert!(store.assign(SECOND, None).is_err());
            assert_eq!(fs::read(&path).unwrap(), invalid);
        }
        fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink(sandbox.0.join("absent"), &path).unwrap();
        assert!(store.lookup(SECOND).is_err());
        assert!(store.assign(SECOND, Some("Work")).is_err());
    }
}
