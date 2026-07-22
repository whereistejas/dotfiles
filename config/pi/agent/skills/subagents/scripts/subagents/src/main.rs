//! subagents — orchestrate up to 5 parallel pi subagents.
//!
//! Surfaces:
//!   artifact   produces jj commits; gets its own jj workspace.
//!   properties edits non-`@` revisions (jj describe -r, jj split -r,
//!              jj bookmark); shares the parent's cwd. `merge` is a no-op.
//!
//! State lives under $PI_SUBAGENTS_STATE_DIR (default /tmp/pi-subagents),
//! one dir per subagent: meta.json, task, log, child.pid, done.json.
//! The dir is owned by this tool; neither parent nor subagent should
//! touch it directly.
//!
//! `list` and `tail` also read each subagent's live pi session transcript
//! (<agent-dir>/sessions/<encoded-cwd>/*.jsonl) to surface progress the
//! `-p` log can't: STALLED (no new event for $PI_SUBAGENTS_STALL_SECS,
//! default 120s) and ERRORED (last model turn failed) statuses, plus a
//! DETAIL column and a transcript-backed `tail`/`tail -f` fallback.
//!
//! Runtime deps: jj and pi on PATH, plus bun (used only to launch pi,
//! mirroring `pi`'s own `bun run $(which pi)` shebang workaround).

use std::env;
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio, exit};
use std::thread::sleep;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use clap::{Args, Parser, Subcommand, ValueEnum};
use serde::{Deserialize, Serialize};

const MAX_SUBAGENTS: usize = 5;

#[derive(Debug, thiserror::Error)]
#[error("{0}")]
struct Error(String);

type Result<T> = std::result::Result<T, Error>;

fn bail<T>(msg: impl Into<String>) -> Result<T> {
    Err(Error(msg.into()))
}

// --- CLI -------------------------------------------------------------

#[derive(Parser)]
#[command(name = "subagents", about = "Run up to 5 pi subagents in parallel.")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Spawn a subagent.
    Create(CreateArgs),
    /// Show all subagents with status.
    List,
    /// Print the tail of a subagent's log (-f to follow until it ends).
    Tail(TailArgs),
    /// Print a subagent's full log.
    Log(NameArg),
    /// Merge a finished subagent's commits (artifact only).
    Merge(MergeArgs),
    /// Stop a subagent and clean up its state.
    Delete(NameArg),
    /// Internal: the detached runner that launches pi. Not for direct use.
    #[command(hide = true)]
    Run(NameArg),
}

#[derive(Args)]
struct CreateArgs {
    /// artifact (own workspace, produces commits) or properties (shares cwd).
    #[arg(long, value_enum, default_value_t = Surface::Artifact)]
    surface: Surface,
    /// Model in provider/id form; omit to inherit the parent's default.
    #[arg(long, default_value = "")]
    model: String,
    /// Fork the workspace from this revset instead of @ (artifact only).
    #[arg(long, default_value = "")]
    base: String,
    name: String,
    task_file: String,
}

#[derive(Args)]
struct TailArgs {
    #[arg(short = 'n', default_value_t = 20)]
    n: usize,
    #[arg(short = 'f')]
    follow: bool,
    name: String,
}

#[derive(Args)]
struct MergeArgs {
    /// Rebase the subagent's chain onto this revset (default: @). When set
    /// to anything other than @, the parent's working copy is left in place.
    #[arg(long)]
    onto: Option<String>,
    /// Point a bookmark at the landed tip commit.
    #[arg(long)]
    bookmark: Option<String>,
    name: String,
}

#[derive(Args)]
struct NameArg {
    name: String,
}

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize, ValueEnum)]
#[serde(rename_all = "lowercase")]
enum Surface {
    Artifact,
    Properties,
}

impl Surface {
    fn as_str(self) -> &'static str {
        match self {
            Surface::Artifact => "artifact",
            Surface::Properties => "properties",
        }
    }
}

// --- State on disk ---------------------------------------------------

#[derive(Serialize, Deserialize)]
struct Meta {
    name: String,
    surface: Surface,
    workspace_dir: String,
    fork_change_id: String,
    model: String,
    started_at: u64,
    pid: u32,
}

#[derive(Serialize, Deserialize)]
struct Done {
    exit_code: i32,
    ended_at: u64,
}

fn state_root() -> PathBuf {
    env::var_os("PI_SUBAGENTS_STATE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp/pi-subagents"))
}
fn state_dir(name: &str) -> PathBuf {
    state_root().join(name)
}
fn meta_path(name: &str) -> PathBuf {
    state_dir(name).join("meta.json")
}
fn task_path(name: &str) -> PathBuf {
    state_dir(name).join("task")
}
fn log_path(name: &str) -> PathBuf {
    state_dir(name).join("log")
}
fn child_pid_path(name: &str) -> PathBuf {
    state_dir(name).join("child.pid")
}
fn done_path(name: &str) -> PathBuf {
    state_dir(name).join("done.json")
}
fn scratch_path(name: &str) -> PathBuf {
    PathBuf::from(format!("/tmp/{name}-scratch"))
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn read_meta(name: &str) -> Result<Meta> {
    let raw = fs::read_to_string(meta_path(name))
        .map_err(|e| Error(format!("cannot read meta for '{name}': {e}")))?;
    serde_json::from_str(&raw).map_err(|e| Error(format!("corrupt meta for '{name}': {e}")))
}
fn write_meta(name: &str, m: &Meta) -> Result<()> {
    let s = serde_json::to_string_pretty(m).map_err(|e| Error(format!("serialize meta: {e}")))?;
    fs::write(meta_path(name), s + "\n").map_err(|e| Error(format!("write meta: {e}")))
}
fn read_done(name: &str) -> Option<Done> {
    serde_json::from_str(&fs::read_to_string(done_path(name)).ok()?).ok()
}
fn write_done(name: &str, d: &Done) {
    if let Ok(s) = serde_json::to_string_pretty(d) {
        let _ = fs::write(done_path(name), s + "\n");
    }
}

fn list_names() -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(state_root())
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.path().is_dir())
        .filter_map(|e| e.file_name().into_string().ok())
        .collect();
    names.sort();
    names
}

fn valid_name(name: &str) -> bool {
    let mut chars = name.chars();
    match chars.next() {
        Some(c) if c.is_ascii_lowercase() || c.is_ascii_digit() => {}
        _ => return false,
    }
    chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

fn require_exists(cmd: &str, name: &str) -> Result<()> {
    if state_dir(name).is_dir() {
        return Ok(());
    }
    let known = list_names().join(", ");
    bail(format!("{cmd}: no such subagent: '{name}'. Known: {known}"))
}

// --- Process helpers (std only) --------------------------------------

fn is_alive(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    Command::new("kill")
        .args(["-0", &pid.to_string()])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn signal(pid: u32, sig: &str) {
    if pid == 0 {
        return;
    }
    let _ = Command::new("kill")
        .args([&format!("-{sig}"), &pid.to_string()])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

fn which(cmd: &str) -> Option<PathBuf> {
    let path = env::var_os("PATH")?;
    env::split_paths(&path)
        .map(|d| d.join(cmd))
        .find(|p| p.is_file())
}

// --- jj helpers ------------------------------------------------------

fn sh(prog: &str, args: &[&str]) -> Result<String> {
    let out = Command::new(prog)
        .args(args)
        .output()
        .map_err(|e| Error(format!("failed to run {prog}: {e}")))?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        let msg = err.trim();
        return bail(format!("{prog} {} failed: {msg}", args.join(" ")));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}
fn jj(args: &[&str]) -> Result<String> {
    sh("jj", args)
}
fn jj_maybe(args: &[&str]) -> String {
    sh("jj", args).unwrap_or_default()
}

/// change_ids of the revisions in a revset, one per line.
fn change_ids(revset: &str) -> Vec<String> {
    jj_maybe(&["log", "-r", revset, "--no-graph", "-T", r#"change_id ++ "\n""#])
        .lines()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from)
        .collect()
}

// --- transcript monitoring -------------------------------------------
//
// pi writes each session's events incrementally to a JSONL transcript at
//   <agent-dir>/sessions/<encoded-cwd>/<ts>_<session-id>.jsonl
// The `-p` log we capture only flushes on process exit, so while a
// subagent runs that log stays empty and the transcript is the only live
// progress signal. We use it to detect stalls (no new event for a while)
// and errored model turns, and to give `tail` something to show mid-run.

const DEFAULT_STALL_SECS: u64 = 120;

fn stall_secs() -> u64 {
    env::var("PI_SUBAGENTS_STALL_SECS")
        .ok()
        .and_then(|s| s.parse().ok())
        .filter(|&n| n > 0)
        .unwrap_or(DEFAULT_STALL_SECS)
}

fn expand_tilde(p: &str) -> PathBuf {
    if let Some(rest) = p.strip_prefix("~/")
        && let Some(home) = env::var_os("HOME")
    {
        return PathBuf::from(home).join(rest);
    }
    PathBuf::from(p)
}

fn agent_dir() -> PathBuf {
    if let Some(d) = env::var_os("PI_CODING_AGENT_DIR") {
        return expand_tilde(&d.to_string_lossy());
    }
    env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default()
        .join(".pi")
        .join("agent")
}

/// Mirror pi's session-dir encoding: strip a leading slash, map `/ \ :`
/// to `-`, and wrap in `--...--` (see session-manager.ts).
fn encode_cwd(path: &str) -> String {
    let stripped = path
        .strip_prefix('/')
        .or_else(|| path.strip_prefix('\\'))
        .unwrap_or(path);
    let mid: String = stripped
        .chars()
        .map(|c| match c {
            '/' | '\\' | ':' => '-',
            other => other,
        })
        .collect();
    format!("--{mid}--")
}

fn session_dir_for(workspace: &str) -> PathBuf {
    agent_dir().join("sessions").join(encode_cwd(workspace))
}

/// Newest `.jsonl` transcript in the workspace's session dir created at or
/// after the subagent started. The `since` filter matters for `properties`
/// subagents, which share the parent's cwd (hence session dir): it skips
/// the orchestrator's own, older session.
fn newest_transcript(workspace: &str, since_ms: u64) -> Option<PathBuf> {
    let since = UNIX_EPOCH + Duration::from_millis(since_ms.saturating_sub(5_000));
    let mut best: Option<(SystemTime, PathBuf)> = None;
    for entry in fs::read_dir(session_dir_for(workspace)).ok()?.flatten() {
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("jsonl") {
            continue;
        }
        let Ok(md) = entry.metadata() else { continue };
        if let Ok(created) = md.created().or_else(|_| md.modified())
            && created < since
        {
            continue;
        }
        let Ok(modified) = md.modified() else { continue };
        if best.as_ref().is_none_or(|(bm, _)| modified > *bm) {
            best = Some((modified, path));
        }
    }
    best.map(|(_, p)| p)
}

fn mtime_age_secs(path: &Path) -> u64 {
    fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|m| SystemTime::now().duration_since(m).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn last_json_line(path: &Path) -> Option<serde_json::Value> {
    let content = fs::read_to_string(path).ok()?;
    let line = content.lines().rev().find(|l| !l.trim().is_empty())?;
    serde_json::from_str(line).ok()
}

fn trunc(s: &str, max: usize) -> String {
    let s: String = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if s.chars().count() > max {
        let cut: String = s.chars().take(max.saturating_sub(1)).collect();
        format!("{cut}\u{2026}")
    } else {
        s
    }
}

fn first_line(s: &str) -> String {
    trunc(s.lines().find(|l| !l.trim().is_empty()).unwrap_or(""), 120)
}

/// If the last event is an assistant turn that ends on a tool call (no
/// tool-result written yet), that tool is still in flight; return its name.
fn inflight_tool(v: &serde_json::Value) -> Option<String> {
    let msg = &v["message"];
    if msg["role"].as_str()? != "assistant" {
        return None;
    }
    let names: Vec<&str> = msg["content"]
        .as_array()?
        .iter()
        .filter(|c| c["type"].as_str() == Some("toolCall"))
        .filter_map(|c| c["name"].as_str())
        .collect();
    match names.as_slice() {
        [] => None,
        [one] => Some((*one).to_string()),
        many => Some(format!("{} +{}", many[0], many.len() - 1)),
    }
}

enum Health {
    Errored(String),
    Stalled(String),
    Active(String),
}

fn transcript_health(workspace: &str, since_ms: u64) -> Option<Health> {
    let path = newest_transcript(workspace, since_ms)?;
    let last = last_json_line(&path);
    if let Some(v) = &last
        && v["message"]["stopReason"].as_str() == Some("error")
    {
        let em = v["message"]["errorMessage"].as_str().unwrap_or("error");
        return Some(Health::Errored(trunc(em, 48)));
    }
    let age = mtime_age_secs(&path);
    let detail = match last.as_ref().and_then(inflight_tool) {
        Some(name) => format!("{name} {age}s"),
        None => format!("idle {age}s"),
    };
    if age >= stall_secs() {
        Some(Health::Stalled(detail))
    } else {
        Some(Health::Active(detail))
    }
}

/// One-line human summary of a transcript event, for `tail`.
fn render_event(v: &serde_json::Value) -> Option<String> {
    if v["type"].as_str()? != "message" {
        return None;
    }
    let msg = &v["message"];
    let ts = v["timestamp"].as_str().unwrap_or("");
    let hms = ts.get(11..19).unwrap_or(ts);
    if msg["stopReason"].as_str() == Some("error") {
        let em = msg["errorMessage"].as_str().unwrap_or("error");
        return Some(format!("[{hms}] ERROR: {}", trunc(em, 120)));
    }
    let content = msg["content"].as_array();
    match msg["role"].as_str().unwrap_or("") {
        "assistant" => {
            let mut parts = Vec::new();
            for item in content? {
                match item["type"].as_str().unwrap_or("") {
                    "thinking" => parts.push(format!(
                        "thinking: {}",
                        first_line(item["thinking"].as_str().unwrap_or(""))
                    )),
                    "text" => parts.push(first_line(item["text"].as_str().unwrap_or(""))),
                    "toolCall" => {
                        let name = item["name"].as_str().unwrap_or("tool");
                        parts.push(format!("\u{2192} {name} {}", tool_summary(name, &item["arguments"])));
                    }
                    _ => {}
                }
            }
            if parts.is_empty() {
                return None;
            }
            Some(format!("[{hms}] assistant: {}", parts.join("  |  ")))
        }
        "toolResult" => {
            let text = content
                .and_then(|a| a.iter().find_map(|c| c["text"].as_str()))
                .unwrap_or("");
            Some(format!("[{hms}]   result: {}", trunc(text, 120)))
        }
        "user" => {
            let text = content
                .and_then(|a| a.iter().find_map(|c| c["text"].as_str()))
                .unwrap_or("");
            Some(format!("[{hms}] user: {}", first_line(text)))
        }
        _ => None,
    }
}

fn tool_summary(name: &str, args: &serde_json::Value) -> String {
    let pick = |k: &str| args[k].as_str().map(|s| trunc(s, 100));
    match name {
        "bash" => pick("command"),
        "read" | "write" | "edit" => pick("path"),
        _ => None,
    }
    .unwrap_or_default()
}

// --- effective status ------------------------------------------------

enum State {
    Running,
    Done(i32),
    Crashed,
}

fn effective_status(name: &str) -> State {
    if let Some(d) = read_done(name) {
        return State::Done(d.exit_code);
    }
    match read_meta(name) {
        Ok(m) if is_alive(m.pid) => State::Running,
        _ => {
            write_done(
                name,
                &Done {
                    exit_code: -1,
                    ended_at: now_ms(),
                },
            );
            State::Crashed
        }
    }
}

// --- create ----------------------------------------------------------

fn cmd_create(a: CreateArgs) -> Result<()> {
    if !valid_name(&a.name) {
        return bail(format!(
            "create: NAME '{}' is invalid — must match [a-z0-9][a-z0-9-]*",
            a.name
        ));
    }
    if !Path::new(&a.task_file).exists() {
        return bail(format!("create: TASK_FILE '{}' does not exist", a.task_file));
    }
    if state_dir(&a.name).exists() {
        return bail(format!(
            "create: subagent '{}' already exists — delete it first",
            a.name
        ));
    }
    fs::create_dir_all(state_root()).map_err(|e| Error(format!("create state root: {e}")))?;
    if list_names().len() >= MAX_SUBAGENTS {
        return bail(format!(
            "create: max ({MAX_SUBAGENTS}) subagents reached — merge or delete one first"
        ));
    }

    let repo_root = jj(&["workspace", "root"])?.trim().to_string();
    if repo_root.is_empty() {
        return bail("create: not inside a jj workspace — cd to a repo first");
    }
    if !a.base.is_empty() && a.surface == Surface::Properties {
        return bail("create: --base is only valid for --surface artifact");
    }

    let fork_revset = if a.base.is_empty() { "@" } else { &a.base };
    let fork = jj(&[
        "log",
        "-r",
        fork_revset,
        "--no-graph",
        "-T",
        "change_id",
        "--ignore-working-copy",
    ])?
    .trim()
    .to_string();
    if fork.is_empty() {
        return bail(format!("create: could not resolve '{fork_revset}' to a change_id"));
    }
    if fork.contains('\n') {
        return bail(format!("create: '{fork_revset}' resolved to multiple revisions"));
    }

    let workspace_dir = if a.surface == Surface::Artifact {
        let root = Path::new(&repo_root);
        let base_name = root.file_name().and_then(|s| s.to_str()).unwrap_or("repo");
        let dir = root
            .parent()
            .unwrap_or(root)
            .join(format!("{base_name}-{}", a.name));
        if dir.exists() {
            return bail(format!(
                "create: workspace dir '{}' already exists — remove it first",
                dir.display()
            ));
        }
        let dir_str = dir.to_string_lossy().into_owned();
        let mut add: Vec<&str> = vec!["workspace", "add", "--name", &a.name];
        if !a.base.is_empty() {
            add.push("--revision");
            add.push(&fork);
        }
        add.push(&dir_str);
        jj(&add)?;
        dir_str
    } else {
        repo_root
    };

    fs::create_dir_all(state_dir(&a.name)).map_err(|e| Error(format!("create state dir: {e}")))?;
    let task = fs::read(&a.task_file).map_err(|e| Error(format!("read task file: {e}")))?;
    fs::write(task_path(&a.name), &task).map_err(|e| Error(format!("write task: {e}")))?;

    let mut meta = Meta {
        name: a.name.clone(),
        surface: a.surface,
        workspace_dir: workspace_dir.clone(),
        fork_change_id: fork.clone(),
        model: a.model.clone(),
        started_at: now_ms(),
        pid: 0,
    };
    write_meta(&a.name, &meta)?;

    let exe = env::current_exe().map_err(|e| Error(format!("current_exe: {e}")))?;
    let child = Command::new(exe)
        .args(["run", &a.name])
        .current_dir(&workspace_dir)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| Error(format!("failed to spawn runner: {e}")))?;

    meta.pid = child.id();
    write_meta(&a.name, &meta)?;

    println!("spawned {}", a.name);
    println!("  surface:   {}", a.surface.as_str());
    println!("  workspace: {workspace_dir}");
    println!("  fork:      {fork}");
    if !a.model.is_empty() {
        println!("  model:     {}", a.model);
    }
    println!("  pid:       {}", child.id());
    println!("  log:       {}", log_path(&a.name).display());
    Ok(())
}

// --- run (internal detached runner) ----------------------------------

fn cmd_run(name: &str) -> Result<()> {
    let meta = read_meta(name)?;
    let task = fs::read_to_string(task_path(name)).map_err(|e| Error(format!("read task: {e}")))?;

    // pi's shebang is node; some node versions crash its bundled undici, so
    // launch it under bun (mirrors the user's `pi='bun run $(which pi)'`).
    let pi = which("pi").ok_or_else(|| Error("pi not found on PATH".into()))?;

    let mut args: Vec<String> = vec![
        "run".into(),
        pi.to_string_lossy().into_owned(),
        "-p".into(),
        "--no-skills".into(),
    ];
    if !meta.model.is_empty() {
        args.push("--model".into());
        args.push(meta.model.clone());
    }
    args.push(task);

    let log = File::options()
        .create(true)
        .append(true)
        .open(log_path(name))
        .map_err(|e| Error(format!("open log: {e}")))?;
    let log_err = log.try_clone().map_err(|e| Error(format!("clone log fd: {e}")))?;

    let mut child = Command::new("bun")
        .args(&args)
        .current_dir(&meta.workspace_dir)
        .stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(log_err))
        .spawn()
        .map_err(|e| Error(format!("failed to launch pi via bun: {e}")))?;

    let _ = fs::write(child_pid_path(name), child.id().to_string());

    let status = child.wait().map_err(|e| Error(format!("wait pi: {e}")))?;
    let code = status.code().unwrap_or(-1);
    write_done(
        name,
        &Done {
            exit_code: code,
            ended_at: now_ms(),
        },
    );
    exit(code);
}

// --- list ------------------------------------------------------------

fn cmd_list() -> Result<()> {
    let names = list_names();
    if names.is_empty() {
        println!("no subagents");
        return Ok(());
    }
    let mut rows = vec![[
        "NAME".into(),
        "SURFACE".into(),
        "STATUS".into(),
        "EXIT".into(),
        "DETAIL".into(),
        "WORKSPACE".into(),
    ]];
    for name in &names {
        let Ok(m) = read_meta(name) else {
            rows.push([
                name.clone(),
                "?".into(),
                "corrupt".into(),
                "-".into(),
                "-".into(),
                "-".into(),
            ]);
            continue;
        };
        let (status, exit, detail) = match effective_status(name) {
            State::Running => match transcript_health(&m.workspace_dir, m.started_at) {
                Some(Health::Errored(msg)) => ("errored".into(), "-".into(), msg),
                Some(Health::Stalled(d)) => ("stalled".into(), "-".into(), d),
                Some(Health::Active(d)) => ("running".into(), "-".into(), d),
                None => ("running".into(), "-".into(), "starting\u{2026}".into()),
            },
            State::Done(c) => ("done".into(), c.to_string(), String::new()),
            State::Crashed => ("crashed".into(), "-1".into(), String::new()),
        };
        rows.push([
            name.clone(),
            m.surface.as_str().to_string(),
            status,
            exit,
            detail,
            m.workspace_dir,
        ]);
    }
    let widths: Vec<usize> = (0..6)
        .map(|c| rows.iter().map(|r| r[c].len()).max().unwrap_or(0))
        .collect();
    for r in &rows {
        let line: Vec<String> = r
            .iter()
            .enumerate()
            .map(|(c, v)| format!("{v:<width$}", width = widths[c]))
            .collect();
        println!("{}", line.join("  ").trim_end());
    }
    Ok(())
}

// --- tail / log ------------------------------------------------------

fn cmd_tail(a: TailArgs) -> Result<()> {
    require_exists("tail", &a.name)?;
    let log = log_path(&a.name);
    // The `-p` log only flushes on process exit, so while a subagent runs
    // it's empty. Prefer it once it has content (final output); otherwise
    // fall back to the live session transcript so tail shows real progress.
    if fs::metadata(&log).map(|m| m.len() > 0).unwrap_or(false) {
        return tail_log(&a, &log);
    }
    tail_transcript(&a)
}

fn tail_log(a: &TailArgs, log: &Path) -> Result<()> {
    let content = fs::read_to_string(log).map_err(|e| Error(format!("read log: {e}")))?;
    let lines: Vec<&str> = content.lines().collect();
    let start = lines.len().saturating_sub(a.n);
    for l in &lines[start..] {
        println!("{l}");
    }
    if !a.follow {
        return Ok(());
    }

    let mut pos = fs::metadata(log).map(|m| m.len()).unwrap_or(0);
    loop {
        sleep(Duration::from_millis(200));
        drain(log, &mut pos);
        if read_done(&a.name).is_some() {
            drain(log, &mut pos);
            return Ok(());
        }
    }
}

fn tail_transcript(a: &TailArgs) -> Result<()> {
    let meta = read_meta(&a.name)?;
    let mut transcript = newest_transcript(&meta.workspace_dir, meta.started_at);
    if transcript.is_none() {
        if !a.follow {
            println!("(no output yet \u{2014} transcript not created)");
            return Ok(());
        }
        loop {
            if read_done(&a.name).is_some() {
                return dump_log_tail(a);
            }
            sleep(Duration::from_millis(300));
            transcript = newest_transcript(&meta.workspace_dir, meta.started_at);
            if transcript.is_some() {
                break;
            }
        }
    }
    let path = transcript.unwrap();
    println!("\u{2500}\u{2500} transcript: {} \u{2500}\u{2500}", path.display());

    let content = fs::read_to_string(&path).unwrap_or_default();
    let rendered: Vec<String> = content
        .lines()
        .filter(|l| !l.trim().is_empty())
        .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
        .filter_map(|v| render_event(&v))
        .collect();
    let start = rendered.len().saturating_sub(a.n);
    for line in &rendered[start..] {
        println!("{line}");
    }
    if !a.follow {
        return Ok(());
    }

    let mut pos = fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
    loop {
        sleep(Duration::from_millis(300));
        stream_new_events(&path, &mut pos);
        if let Some(v) = last_json_line(&path)
            && v["message"]["stopReason"].as_str() == Some("error")
        {
            println!("(subagent turn errored \u{2014} stopping follow)");
            return Ok(());
        }
        if read_done(&a.name).is_some() {
            stream_new_events(&path, &mut pos);
            return Ok(());
        }
    }
}

/// After a subagent exits, show whatever the `-p` log captured.
fn dump_log_tail(a: &TailArgs) -> Result<()> {
    let log = log_path(&a.name);
    if fs::metadata(&log).map(|m| m.len() > 0).unwrap_or(false) {
        return tail_log(a, &log);
    }
    println!("(subagent finished with no captured output)");
    Ok(())
}

/// Render transcript events appended since byte offset `pos`, advancing it
/// past the last complete (newline-terminated) line.
fn stream_new_events(path: &Path, pos: &mut u64) {
    let size = fs::metadata(path).map(|m| m.len()).unwrap_or(*pos);
    if size < *pos {
        *pos = 0;
    }
    if size <= *pos {
        return;
    }
    let Ok(mut f) = File::open(path) else { return };
    if f.seek(SeekFrom::Start(*pos)).is_err() {
        return;
    }
    let mut buf = Vec::new();
    if f.read_to_end(&mut buf).is_err() {
        return;
    }
    let Some(last_nl) = buf.iter().rposition(|&b| b == b'\n') else {
        return;
    };
    for line in buf[..=last_nl].split(|&b| b == b'\n') {
        if line.is_empty() {
            continue;
        }
        if let Ok(v) = serde_json::from_slice::<serde_json::Value>(line)
            && let Some(s) = render_event(&v)
        {
            println!("{s}");
        }
    }
    *pos += last_nl as u64 + 1;
}

fn drain(log: &Path, pos: &mut u64) {
    let size = fs::metadata(log).map(|m| m.len()).unwrap_or(*pos);
    if size < *pos {
        *pos = 0;
    }
    if size <= *pos {
        return;
    }
    if let Ok(mut f) = File::open(log)
        && f.seek(SeekFrom::Start(*pos)).is_ok()
    {
        let mut buf = Vec::new();
        if f.read_to_end(&mut buf).is_ok() {
            let _ = std::io::stdout().write_all(&buf);
            *pos = size;
        }
    }
}

fn cmd_log(name: &str) -> Result<()> {
    require_exists("log", name)?;
    let log = log_path(name);
    if !log.exists() {
        return bail(format!("log: no log for '{name}' yet"));
    }
    let data = fs::read(&log).map_err(|e| Error(format!("read log: {e}")))?;
    std::io::stdout()
        .write_all(&data)
        .map_err(|e| Error(format!("write stdout: {e}")))
}

// --- merge -----------------------------------------------------------

const SUMMARY_TMPL: &str = r#"change_id.short() ++ " " ++ description.first_line() ++ "\n""#;

fn cmd_merge(a: MergeArgs) -> Result<()> {
    require_exists("merge", &a.name)?;
    let inspect = format!(
        "Inspect: subagents log {}; then drop it: subagents delete {}",
        a.name, a.name
    );
    match effective_status(&a.name) {
        State::Running => return bail(format!("merge: '{}' is still running", a.name)),
        State::Done(0) => {}
        State::Done(c) => return bail(format!("merge: '{}' exited {c} — refusing. {inspect}", a.name)),
        State::Crashed => return bail(format!("merge: '{}' crashed — refusing. {inspect}", a.name)),
    }

    let meta = read_meta(&a.name)?;
    if meta.surface == Surface::Properties {
        println!("{} (properties): nothing to merge — changes are in the jj op log.", a.name);
        return Ok(());
    }

    let revset = format!("{}..{}@", meta.fork_change_id, a.name);
    jj_maybe(&["abandon", "-r", &format!("empty() & ({revset})")]);

    let roots = change_ids(&format!("roots({revset})"));
    let heads = change_ids(&format!("heads({revset})"));
    if roots.is_empty() {
        println!("{} produced no non-empty commits — nothing to merge", a.name);
        return Ok(());
    }
    if roots.len() > 1 {
        return bail(format!("merge: '{}' has {} roots, expected 1", a.name, roots.len()));
    }
    if heads.len() > 1 {
        return bail(format!("merge: '{}' has {} heads, expected 1", a.name, heads.len()));
    }
    let root = &roots[0];
    let tip = &heads[0];

    let advance = a.onto.is_none();
    let onto = a.onto.as_deref().unwrap_or("@");

    let old_at = if advance {
        jj(&["log", "-r", "@", "--no-graph", "-T", "change_id"])?.trim().to_string()
    } else {
        String::new()
    };

    jj(&["rebase", "--source", root, "--onto", onto])?;

    if advance {
        jj(&["new", tip])?;
    }
    if let Some(bm) = &a.bookmark {
        jj(&["bookmark", "create", bm, "-r", tip])?;
    }

    println!("{} merged. Commits:", a.name);
    print!("{}", jj(&["log", "-r", &format!("{root}::{tip}"), "--no-graph", "-T", SUMMARY_TMPL])?);

    if advance && !old_at.is_empty() {
        jj_maybe(&["abandon", "-r", &format!("empty() & {old_at}")]);
    }
    Ok(())
}

// --- delete ----------------------------------------------------------

fn cmd_delete(name: &str) -> Result<()> {
    require_exists("delete", name)?;
    let meta = read_meta(name).ok();

    if let Some(m) = &meta
        && matches!(effective_status(name), State::Running)
    {
        // Kill the pi child so the runner records `done` and exits cleanly;
        // fall back to the runner itself if pi hasn't been spawned yet.
        let child_pid = fs::read_to_string(child_pid_path(name))
            .ok()
            .and_then(|s| s.trim().parse::<u32>().ok());
        match child_pid {
            Some(cp) => signal(cp, "TERM"),
            None => signal(m.pid, "TERM"),
        }
        for _ in 0..20 {
            if !is_alive(m.pid) {
                break;
            }
            sleep(Duration::from_millis(100));
        }
        if is_alive(m.pid) {
            if let Some(cp) = child_pid {
                signal(cp, "KILL");
            }
            signal(m.pid, "KILL");
        }
        if read_done(name).is_none() {
            write_done(name, &Done { exit_code: 130, ended_at: now_ms() });
        }
    }

    if let Some(m) = &meta
        && m.surface == Surface::Artifact
    {
        jj_maybe(&["workspace", "forget", name]);
        let repo_root = jj_maybe(&["workspace", "root"]).trim().to_string();
        let ws = Path::new(&m.workspace_dir);
        if ws.exists() && m.workspace_dir != repo_root {
            let _ = fs::remove_dir_all(ws);
        }
    }

    let _ = fs::remove_dir_all(scratch_path(name));
    let _ = fs::remove_dir_all(state_dir(name));
    println!("{name} deleted");
    Ok(())
}

// --- main ------------------------------------------------------------

fn main() {
    let cli = Cli::parse();
    let res = match cli.cmd {
        Cmd::Create(a) => cmd_create(a),
        Cmd::List => cmd_list(),
        Cmd::Tail(a) => cmd_tail(a),
        Cmd::Log(a) => cmd_log(&a.name),
        Cmd::Merge(a) => cmd_merge(a),
        Cmd::Delete(a) => cmd_delete(&a.name),
        Cmd::Run(a) => cmd_run(&a.name),
    };
    if let Err(e) = res {
        eprintln!("subagents: {e}");
        exit(1);
    }
}
