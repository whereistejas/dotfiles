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
        "WORKSPACE".into(),
    ]];
    for name in &names {
        let Ok(m) = read_meta(name) else {
            rows.push([name.clone(), "?".into(), "corrupt".into(), "-".into(), "-".into()]);
            continue;
        };
        let (status, exit) = match effective_status(name) {
            State::Running => ("running".to_string(), "-".to_string()),
            State::Done(c) => ("done".to_string(), c.to_string()),
            State::Crashed => ("crashed".to_string(), "-1".to_string()),
        };
        rows.push([
            name.clone(),
            m.surface.as_str().to_string(),
            status,
            exit,
            m.workspace_dir,
        ]);
    }
    let widths: Vec<usize> = (0..5)
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
    if !log.exists() {
        return bail(format!("tail: no log for '{}' yet", a.name));
    }

    let content = fs::read_to_string(&log).map_err(|e| Error(format!("read log: {e}")))?;
    let lines: Vec<&str> = content.lines().collect();
    let start = lines.len().saturating_sub(a.n);
    for l in &lines[start..] {
        println!("{l}");
    }
    if !a.follow {
        return Ok(());
    }

    let mut pos = fs::metadata(&log).map(|m| m.len()).unwrap_or(0);
    loop {
        sleep(Duration::from_millis(200));
        drain(&log, &mut pos);
        if read_done(&a.name).is_some() {
            drain(&log, &mut pos);
            return Ok(());
        }
    }
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
