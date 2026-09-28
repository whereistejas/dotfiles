use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::model::{Entry, Header};

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("io error on {path}: {source}")]
    Io {
        path: String,
        #[source]
        source: std::io::Error,
    },
    #[error("no session matches id '{0}'")]
    NotFound(String),
    #[error("id '{id}' is ambiguous, matches {n} sessions: {ids}; use a longer prefix")]
    Ambiguous { id: String, n: usize, ids: String },
    #[error("sessions directory not found: {0}")]
    NoSessionsDir(String),
}

fn io<P: AsRef<Path>>(path: P) -> impl FnOnce(std::io::Error) -> Error {
    let path = path.as_ref().display().to_string();
    move |source| Error::Io { path, source }
}

/// Minimal shape used while streaming a file for its summary. Everything else
/// on the line is skipped without being materialised.
#[derive(Deserialize)]
struct MetaLine {
    #[serde(rename = "type", default)]
    kind: String,
    #[serde(default)]
    timestamp: Option<String>,
}

#[derive(Debug, Clone)]
pub struct SessionSummary {
    pub path: PathBuf,
    pub id: String,
    pub cwd: String,
    pub started: String,
    pub ended: String,
    pub messages: usize,
    pub entries: usize,
    pub bytes: u64,
}

pub fn default_sessions_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("PI_SESSIONS_DIR") {
        return PathBuf::from(dir);
    }
    let home = std::env::var("HOME").unwrap_or_default();
    PathBuf::from(home).join(".pi/agent/sessions")
}

/// All `<sessions-dir>/*/*.jsonl` paths.
pub fn session_files(root: &Path) -> Result<Vec<PathBuf>, Error> {
    if !root.is_dir() {
        return Err(Error::NoSessionsDir(root.display().to_string()));
    }
    let mut files = Vec::new();
    for dir in std::fs::read_dir(root).map_err(io(root))? {
        let dir = match dir {
            Ok(d) => d,
            Err(_) => continue,
        };
        let p = dir.path();
        if !p.is_dir() {
            if p.extension().is_some_and(|e| e == "jsonl") {
                files.push(p);
            }
            continue;
        }
        let inner = match std::fs::read_dir(&p) {
            Ok(i) => i,
            Err(_) => continue,
        };
        for f in inner.flatten() {
            let fp = f.path();
            if fp.extension().is_some_and(|e| e == "jsonl") {
                files.push(fp);
            }
        }
    }
    Ok(files)
}

/// Stream a session file, reading only its header plus per-line metadata.
/// Never holds more than one line in memory.
pub fn summarize(path: &Path) -> Result<SessionSummary, Error> {
    let file = File::open(path).map_err(io(path))?;
    let bytes = file.metadata().map(|m| m.len()).unwrap_or(0);
    let reader = BufReader::new(file);

    let mut header: Option<Header> = None;
    let mut messages = 0usize;
    let mut entries = 0usize;
    let mut last_ts: Option<String> = None;

    for line in reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => break,
        };
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let meta: MetaLine = match serde_json::from_str(line) {
            Ok(m) => m,
            Err(_) => continue,
        };
        if meta.kind == "session" {
            if header.is_none() {
                header = serde_json::from_str(line).ok();
            }
            continue;
        }
        entries += 1;
        if meta.kind == "message" {
            messages += 1;
        }
        if let Some(ts) = meta.timestamp {
            last_ts = Some(ts);
        }
    }

    let (id, cwd, started) = match header {
        Some(h) => (h.id, h.cwd, h.timestamp),
        None => (id_from_filename(path), String::new(), String::new()),
    };
    let started = if started.is_empty() {
        last_ts.clone().unwrap_or_default()
    } else {
        started
    };

    Ok(SessionSummary {
        path: path.to_path_buf(),
        id,
        cwd,
        started,
        ended: last_ts.unwrap_or_default(),
        messages,
        entries,
        bytes,
    })
}

fn id_from_filename(path: &Path) -> String {
    let stem = path
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();
    match stem.split_once('_') {
        Some((_, id)) => id.to_string(),
        None => stem,
    }
}

/// Every summary under `root`, most recent first.
pub fn all_summaries(root: &Path) -> Result<Vec<SessionSummary>, Error> {
    let mut out: Vec<SessionSummary> = session_files(root)?
        .iter()
        .filter_map(|p| summarize(p).ok())
        .collect();
    out.sort_by(|a, b| b.started.cmp(&a.started));
    Ok(out)
}

/// Resolve a session id or unique id prefix to exactly one session.
pub fn resolve(root: &Path, id: &str) -> Result<SessionSummary, Error> {
    let needle = id.to_ascii_lowercase();
    let mut matches: Vec<SessionSummary> = all_summaries(root)?
        .into_iter()
        .filter(|s| {
            let sid = s.id.to_ascii_lowercase();
            sid == needle || sid.starts_with(&needle)
        })
        .collect();
    match matches.len() {
        0 => Err(Error::NotFound(id.to_string())),
        1 => Ok(matches.remove(0)),
        n => {
            let exact: Vec<&SessionSummary> = matches
                .iter()
                .filter(|s| s.id.eq_ignore_ascii_case(id))
                .collect();
            if exact.len() == 1 {
                return Ok(exact[0].clone());
            }
            let mut ids = matches
                .iter()
                .take(8)
                .map(|s| s.id.as_str())
                .collect::<Vec<_>>()
                .join(", ");
            if n > 8 {
                ids.push_str(", …");
            }
            Err(Error::Ambiguous {
                id: id.to_string(),
                n,
                ids,
            })
        }
    }
}

pub struct LoadedSession {
    pub header: Option<Header>,
    pub entries: Vec<Entry>,
    pub bad_lines: usize,
}

pub fn load(path: &Path) -> Result<LoadedSession, Error> {
    let file = File::open(path).map_err(io(path))?;
    let reader = BufReader::new(file);
    let mut header = None;
    let mut entries = Vec::new();
    let mut bad_lines = 0usize;

    for line in reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => {
                bad_lines += 1;
                continue;
            }
        };
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if header.is_none()
            && line.contains("\"type\":\"session\"")
            && let Ok(h) = serde_json::from_str::<Header>(line)
        {
            header = Some(h);
            continue;
        }
        match serde_json::from_str::<Entry>(line) {
            Ok(e) if e.kind == "session" => {}
            Ok(e) => entries.push(e),
            Err(_) => bad_lines += 1,
        }
    }

    Ok(LoadedSession {
        header,
        entries,
        bad_lines,
    })
}

/// The active path: last entry in file order is the leaf, walk `parentId`
/// back to a root, then reverse. Defensive against missing parents,
/// duplicate ids and cycles.
pub fn active_path(entries: &[Entry]) -> Vec<usize> {
    if entries.is_empty() {
        return Vec::new();
    }
    // First occurrence wins for duplicate ids.
    let mut by_id: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();
    for (i, e) in entries.iter().enumerate() {
        if let Some(id) = e.id.as_deref() {
            by_id.entry(id).or_insert(i);
        }
    }

    let mut path = Vec::new();
    let mut seen: std::collections::HashSet<usize> = std::collections::HashSet::new();
    let mut cur = entries.len() - 1;
    loop {
        if !seen.insert(cur) {
            break;
        }
        path.push(cur);
        let parent = match entries[cur].parent_id.as_deref() {
            Some(p) if !p.is_empty() => p,
            _ => break,
        };
        match by_id.get(parent) {
            Some(&idx) => cur = idx,
            None => break, // orphan: parent not in this file
        }
    }
    path.reverse();
    path
}
