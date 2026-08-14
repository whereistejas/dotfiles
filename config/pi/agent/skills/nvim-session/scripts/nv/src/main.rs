//! `nv` - talk to a live Neovim session over msgpack-RPC.
//!
//! Three principles, in priority order:
//!
//! 1. **Fail fast and loudly.** Any input that is not valid is rejected
//!    immediately. Nothing is coerced, defaulted, or ignored.
//! 2. **Parse, don't validate.** Arguments and quickfix items are parsed into
//!    typed values up front. Past the parse boundary every value is known-good,
//!    so no operation re-checks its inputs.
//! 3. **Helpful errors.** Every failure names what was wrong and prints the
//!    usage for the command that was attempted.

mod rpc;

use rmpv::Value;
use rpc::{Error, Handle, Nvim};
use serde_json::Value as J;
use std::io::{IsTerminal, Read};
use std::os::unix::fs::FileTypeExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(5);

// ---------------------------------------------------------------------------
// failure: message + the usage for whatever was attempted
// ---------------------------------------------------------------------------

struct Fail {
    message: String,
    usage: &'static str,
}

impl Fail {
    fn new(message: impl Into<String>, usage: &'static str) -> Self {
        Fail {
            message: message.into(),
            usage,
        }
    }
}

impl std::fmt::Display for Fail {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}\n\nusage:\n{}", self.message, self.usage)
    }
}

impl From<Error> for Fail {
    fn from(e: Error) -> Self {
        Fail::new(e.to_string(), USAGE)
    }
}

const USAGE: &str = "\
  nv sockets                 discover reachable nvim sessions
  nv ping                    liveness + api level
  nv cursor                  current file, line, col, modified, line text
  nv selection               last visual selection (side-effect free)
  nv buffers [--modified]    open buffers, optionally only unsaved ones
  nv qf <title>              populate quickfix from JSON items on stdin
  nv open <file> <line>      open a file at a line
  nv cwd                     working directory of every scope
  nv cd <dir> --scope S      set the working directory (S: global|tab|window|buffer)
  nv cd --unset --scope S    drop a local directory (S: tab|window|buffer)

  --socket PATH              unix socket of the nvim session
                             (or set NVIM_AGENT_SOCKET)";

const USAGE_SOCKETS: &str = "\
  nv sockets

  Lists candidate nvim sockets and probes each one. Needs no --socket.
  Use the returned `socket` value for every other command.
  If more than one session is alive, ask the user which they mean.";
const USAGE_PING: &str = "  nv ping\n\n  Takes no arguments.";
const USAGE_CURSOR: &str = "  nv cursor\n\n  Takes no arguments.";
const USAGE_SELECTION: &str = "  nv selection\n\n  Takes no arguments.";
const USAGE_BUFFERS: &str = "\
  nv buffers [--modified]

  --modified   list only buffers with unsaved changes";
const USAGE_QF: &str = "\
  nv qf <title> < items.json

  Reads a JSON array of quickfix items on stdin. Each item:

    {\"filename\": \"src/foo.zig\", \"lnum\": 42, \"text\": \"why it matters\"}

  Required: filename (string), lnum (positive integer), text (string).
  Optional: col (positive integer).

  Example:
    echo '[{\"filename\":\"a.zig\",\"lnum\":1,\"text\":\"here\"}]' | nv qf \"my search\"";
const USAGE_OPEN: &str = "\
  nv open <file> <line>

  file   path to open (relative to the editor's cwd, or absolute)
  line   positive integer line number

  Example:
    nv open src/link/MappedFile.zig 766";
const USAGE_CWD: &str = "\
  nv cwd

  Takes no arguments. Reports the directory of every scope, and whether each
  is set locally:

    effective   what relative paths in the session resolve against right now
    global      :cd    - the whole session
    tab         :tcd   - current tabpage
    window      :lcd   - current window
    buffer      :bcd   - current buffer (nvim 0.13+)

  Read this before `nv cd` so you never guess what you are changing.";
const USAGE_CD: &str = "\
  nv cd <dir> --scope <global|tab|window|buffer>

  dir      existing directory; resolved to an absolute path before being sent,
           so it is never relative to whatever the editor happens to be in
  --scope  required. There is no safe default - the scopes are not equivalent:

    global   :cd    moves the user's whole session
    tab      :tcd   moves every window in the current tabpage
    window   :lcd   moves the current window; sticky, new windows inherit it
    buffer   :bcd   moves the current buffer only; not sticky (nvim 0.13+)

  Aliases: cd/tcd/lcd/bcd may be used in place of the scope names.
  Reports before/after for all scopes, so a re-root is never silent.

  Narrow scopes SHADOW wider ones: with a buffer-local directory set, a later
  --scope global changes `global` while `effective` does not move. If a re-root
  appears to do nothing, read `effective` in the report and drop the narrower
  scope:

    nv cd --unset --scope buffer    :bcd!  (also tab/window; global has no unset)

  Examples:
    nv cd /Users/you/build/dotfiles --scope global
    nv cd --unset --scope buffer";

// ---------------------------------------------------------------------------
// parse, don't validate
// ---------------------------------------------------------------------------

/// Which `:cd` family command to issue. Kept distinct because they are *not*
/// interchangeable: global/tab move what the user sees, window/buffer do not.
#[derive(Clone, Copy)]
enum Scope {
    Global,
    Tab,
    Window,
    Buffer,
}

impl Scope {
    fn parse(raw: &str) -> Result<Self, Fail> {
        match raw {
            "global" | "cd" => Ok(Scope::Global),
            "tab" | "tcd" => Ok(Scope::Tab),
            "window" | "lcd" => Ok(Scope::Window),
            "buffer" | "bcd" => Ok(Scope::Buffer),
            other => Err(Fail::new(
                format!(
                    "unknown scope {other:?}. Expected global, tab, window or buffer \
                     (or the vim names cd, tcd, lcd, bcd)"
                ),
                USAGE_CD,
            )),
        }
    }

    /// The Ex command, which is also the key this scope reports under in `nv cwd`.
    fn command(self) -> &'static str {
        match self {
            Scope::Global => "cd",
            Scope::Tab => "tcd",
            Scope::Window => "lcd",
            Scope::Buffer => "bcd",
        }
    }

    fn name(self) -> &'static str {
        match self {
            Scope::Global => "global",
            Scope::Tab => "tab",
            Scope::Window => "window",
            Scope::Buffer => "buffer",
        }
    }
}

/// Every variant here is already known-good. Operations below never re-check.
enum Command {
    Sockets,
    Ping,
    Cursor,
    Selection,
    Buffers { only_modified: bool },
    Qf { title: String, items: Vec<QfItem> },
    Open { file: String, line: u64 },
    Cwd,
    /// `dir: None` means unset this scope's local directory (`:lcd!` and friends).
    Cd { dir: Option<String>, scope: Scope },
}

impl Command {
    fn usage(&self) -> &'static str {
        match self {
            Command::Sockets => USAGE_SOCKETS,
            Command::Ping => USAGE_PING,
            Command::Cursor => USAGE_CURSOR,
            Command::Selection => USAGE_SELECTION,
            Command::Buffers { .. } => USAGE_BUFFERS,
            Command::Qf { .. } => USAGE_QF,
            Command::Open { .. } => USAGE_OPEN,
            Command::Cwd => USAGE_CWD,
            Command::Cd { .. } => USAGE_CD,
        }
    }
}

struct QfItem {
    filename: String,
    lnum: u64,
    col: Option<u64>,
    text: String,
}

/// Discovery needs no session; everything else does. Encoding that here means
/// `execute` never has to ask whether a socket is present.
enum Invocation {
    Local(Command),
    Remote { socket: String, command: Command },
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();

    if args.first().is_some_and(|a| a == "help" || a == "--help") {
        println!("nv - drive a live Neovim session over msgpack-RPC\n\n{USAGE}");
        return;
    }

    let invocation = match parse(&args) {
        Ok(i) => i,
        Err(e) => die(e),
    };
    match execute(invocation) {
        Ok(json) => println!("{json}"),
        Err(e) => die(e),
    }
}

fn die(e: Fail) -> ! {
    eprintln!("nv: {e}");
    std::process::exit(1);
}

fn parse(args: &[String]) -> Result<Invocation, Fail> {
    let mut socket = std::env::var("NVIM_AGENT_SOCKET").ok();
    let mut scope: Option<&str> = None;
    let mut positional: Vec<&str> = Vec::new();
    let mut flags: Vec<&str> = Vec::new();

    let mut i = 0;
    while i < args.len() {
        let arg = args[i].as_str();
        match arg {
            "--socket" | "-s" => {
                let value = args.get(i + 1).ok_or_else(|| {
                    Fail::new(format!("{arg} requires a path, but none was given"), USAGE)
                })?;
                if value.starts_with('-') {
                    return Err(Fail::new(
                        format!("{arg} requires a path, but got the flag {value:?}"),
                        USAGE,
                    ));
                }
                socket = Some(value.clone());
                i += 2;
            }
            "--scope" => {
                let value = args.get(i + 1).ok_or_else(|| {
                    Fail::new(
                        "--scope requires a value: global, tab, window or buffer",
                        USAGE_CD,
                    )
                })?;
                if value.starts_with('-') {
                    return Err(Fail::new(
                        format!("--scope requires a value, but got the flag {value:?}"),
                        USAGE_CD,
                    ));
                }
                scope = Some(value.as_str());
                i += 2;
            }
            flag if flag.starts_with("--") => {
                flags.push(flag);
                i += 1;
            }
            value => {
                positional.push(value);
                i += 1;
            }
        }
    }

    let name = *positional.first().ok_or_else(|| {
        Fail::new(
            "no command given. Expected one of: sockets, ping, cursor, selection, buffers, qf, open, cwd, cd",
            USAGE,
        )
    })?;
    let rest = &positional[1..];

    // Reject a misplaced --scope here rather than ignoring it: a silently
    // dropped scope on the wrong verb looks exactly like a successful no-op.
    if scope.is_some() && name != "cd" {
        return Err(Fail::new(
            format!("--scope applies only to `nv cd`, not to {name:?}"),
            USAGE,
        ));
    }

    let command = match name {
        "sockets" => {
            no_positional(name, rest, USAGE_SOCKETS)?;
            no_flags(name, &flags, &[], USAGE_SOCKETS)?;
            return Ok(Invocation::Local(Command::Sockets));
        }
        "ping" => {
            no_positional(name, rest, USAGE_PING)?;
            no_flags(name, &flags, &[], USAGE_PING)?;
            Command::Ping
        }
        "cursor" => {
            no_positional(name, rest, USAGE_CURSOR)?;
            no_flags(name, &flags, &[], USAGE_CURSOR)?;
            Command::Cursor
        }
        "selection" => {
            no_positional(name, rest, USAGE_SELECTION)?;
            no_flags(name, &flags, &[], USAGE_SELECTION)?;
            Command::Selection
        }
        "buffers" => {
            no_positional(name, rest, USAGE_BUFFERS)?;
            no_flags(name, &flags, &["--modified"], USAGE_BUFFERS)?;
            Command::Buffers {
                only_modified: flags.contains(&"--modified"),
            }
        }
        "qf" => {
            no_flags(name, &flags, &[], USAGE_QF)?;
            let title = match rest {
                [title] => (*title).to_string(),
                [] => {
                    return Err(Fail::new(
                        "qf requires a title so the user can tell lists apart",
                        USAGE_QF,
                    ))
                }
                _ => {
                    return Err(Fail::new(
                        format!(
                            "qf takes exactly one title, got {}: {:?}. Quote titles containing spaces.",
                            rest.len(),
                            rest
                        ),
                        USAGE_QF,
                    ))
                }
            };
            Command::Qf {
                title,
                items: parse_qf_items()?,
            }
        }
        "open" => {
            no_flags(name, &flags, &[], USAGE_OPEN)?;
            let (file, line) = match rest {
                [file, line] => (*file, *line),
                [_] => {
                    return Err(Fail::new(
                        "open requires a line number. Pass 1 to open at the top of the file.",
                        USAGE_OPEN,
                    ))
                }
                [] => return Err(Fail::new("open requires a file and a line", USAGE_OPEN)),
                _ => {
                    return Err(Fail::new(
                        format!("open takes exactly a file and a line, got {rest:?}"),
                        USAGE_OPEN,
                    ))
                }
            };
            Command::Open {
                file: file.to_string(),
                line: parse_line(line, "open", USAGE_OPEN)?,
            }
        }
        "cwd" => {
            no_positional(name, rest, USAGE_CWD)?;
            no_flags(name, &flags, &[], USAGE_CWD)?;
            Command::Cwd
        }
        "cd" => {
            no_flags(name, &flags, &["--unset"], USAGE_CD)?;
            let unset = flags.contains(&"--unset");
            let dir = match (unset, rest) {
                (true, []) => None,
                (true, extra) => {
                    return Err(Fail::new(
                        format!("cd --unset takes no directory, got {extra:?}"),
                        USAGE_CD,
                    ))
                }
                (false, [dir]) => Some(*dir),
                (false, []) => {
                    return Err(Fail::new(
                        "cd requires a directory, or --unset to drop a local one",
                        USAGE_CD,
                    ))
                }
                (false, _) => {
                    return Err(Fail::new(
                        format!(
                            "cd takes exactly one directory, got {}: {:?}. Quote paths containing spaces.",
                            rest.len(),
                            rest
                        ),
                        USAGE_CD,
                    ))
                }
            };
            let scope = scope.ok_or_else(|| {
                Fail::new(
                    "cd requires --scope. There is no safe default: global and tab move what \
                     the user sees, window and buffer do not. Run `nv cwd` first if you are \
                     unsure what the session is currently rooted at.",
                    USAGE_CD,
                )
            })?;
            let scope = Scope::parse(scope)?;
            if unset && matches!(scope, Scope::Global) {
                return Err(Fail::new(
                    "the global directory cannot be unset - there is nothing wider to fall \
                     back to. Pass an explicit directory instead, or unset the tab, window \
                     or buffer scope that is shadowing it.",
                    USAGE_CD,
                ));
            }
            Command::Cd {
                dir: dir.map(parse_dir).transpose()?,
                scope,
            }
        }
        other => {
            return Err(Fail::new(
                format!(
                    "unknown command {other:?}. Expected one of: sockets, ping, cursor, selection, buffers, qf, open, cwd, cd"
                ),
                USAGE,
            ))
        }
    };

    let socket = socket.ok_or_else(|| {
        Fail::new(
            "no socket given. Pass --socket PATH or set NVIM_AGENT_SOCKET.\n\
             Run `nv sockets` to discover reachable sessions.\n\
             If none are listed, ask the user to start or attach one - do not \
             start an editor yourself.",
            command.usage(),
        )
    })?;

    Ok(Invocation::Remote { socket, command })
}

fn no_positional(name: &str, rest: &[&str], usage: &'static str) -> Result<(), Fail> {
    if rest.is_empty() {
        return Ok(());
    }
    Err(Fail::new(
        format!("{name} takes no arguments, got {rest:?}"),
        usage,
    ))
}

fn no_flags(
    name: &str,
    flags: &[&str],
    allowed: &[&str],
    usage: &'static str,
) -> Result<(), Fail> {
    for flag in flags {
        if !allowed.contains(flag) {
            let detail = if allowed.is_empty() {
                format!("{name} accepts no flags")
            } else {
                format!("{name} accepts only: {}", allowed.join(", "))
            };
            return Err(Fail::new(
                format!("unknown flag {flag:?} for {name}. {detail}"),
                usage,
            ));
        }
    }
    Ok(())
}

/// Resolved to an absolute path up front: a relative `nv cd` would otherwise be
/// relative to the editor's cwd, which is the very thing being changed.
fn parse_dir(raw: &str) -> Result<String, Fail> {
    if raw.starts_with('~') {
        return Err(Fail::new(
            format!(
                "cd: {raw:?} starts with ~, which the shell did not expand. \
                 Pass an unquoted path or an absolute one."
            ),
            USAGE_CD,
        ));
    }
    let path = std::fs::canonicalize(raw)
        .map_err(|e| Fail::new(format!("cd: cannot resolve {raw:?}: {e}"), USAGE_CD))?;
    if !path.is_dir() {
        return Err(Fail::new(
            format!("cd: {raw:?} is not a directory"),
            USAGE_CD,
        ));
    }
    path.into_os_string().into_string().map_err(|p| {
        Fail::new(
            format!("cd: path is not valid UTF-8: {}", p.to_string_lossy()),
            USAGE_CD,
        )
    })
}

fn parse_line(raw: &str, name: &str, usage: &'static str) -> Result<u64, Fail> {
    let line: u64 = raw.parse().map_err(|_| {
        Fail::new(
            format!("{name}: line must be a positive integer, got {raw:?}"),
            usage,
        )
    })?;
    if line == 0 {
        return Err(Fail::new(
            format!("{name}: line numbers start at 1, got 0"),
            usage,
        ));
    }
    Ok(line)
}

/// Reads stdin and parses it into typed items. Refuses to read from a terminal,
/// which would otherwise hang forever waiting for input that is not coming.
fn parse_qf_items() -> Result<Vec<QfItem>, Fail> {
    if std::io::stdin().is_terminal() {
        return Err(Fail::new(
            "qf reads items from stdin, but stdin is a terminal. Pipe JSON in.",
            USAGE_QF,
        ));
    }

    let mut raw = String::new();
    std::io::stdin()
        .read_to_string(&mut raw)
        .map_err(|e| Fail::new(format!("cannot read quickfix items from stdin: {e}"), USAGE_QF))?;

    if raw.trim().is_empty() {
        return Err(Fail::new(
            "no quickfix items on stdin. Send a JSON array; use [] to clear the list.",
            USAGE_QF,
        ));
    }

    let parsed: serde_json::Value = serde_json::from_str(&raw)
        .map_err(|e| Fail::new(format!("quickfix items are not valid JSON: {e}"), USAGE_QF))?;

    let array = parsed.as_array().ok_or_else(|| {
        Fail::new(
            format!(
                "quickfix items must be a JSON array, got {}",
                json_kind(&parsed)
            ),
            USAGE_QF,
        )
    })?;

    array.iter().enumerate().map(parse_qf_item).collect()
}

fn parse_qf_item((index, value): (usize, &serde_json::Value)) -> Result<QfItem, Fail> {
    let at = format!("quickfix item [{index}]");
    let object = value.as_object().ok_or_else(|| {
        Fail::new(
            format!("{at} must be an object, got {}", json_kind(value)),
            USAGE_QF,
        )
    })?;

    for key in object.keys() {
        if !matches!(key.as_str(), "filename" | "lnum" | "col" | "text") {
            return Err(Fail::new(
                format!("{at} has unknown field {key:?}. Allowed: filename, lnum, col, text"),
                USAGE_QF,
            ));
        }
    }

    let string_field = |name: &str| -> Result<String, Fail> {
        match object.get(name) {
            Some(serde_json::Value::String(s)) if !s.is_empty() => Ok(s.clone()),
            Some(serde_json::Value::String(_)) => Err(Fail::new(
                format!("{at} has an empty {name}"),
                USAGE_QF,
            )),
            Some(other) => Err(Fail::new(
                format!("{at} field {name} must be a string, got {}", json_kind(other)),
                USAGE_QF,
            )),
            None => Err(Fail::new(format!("{at} is missing {name}"), USAGE_QF)),
        }
    };

    let positive_field = |name: &str, required: bool| -> Result<Option<u64>, Fail> {
        match object.get(name) {
            None | Some(serde_json::Value::Null) if !required => Ok(None),
            None | Some(serde_json::Value::Null) => {
                Err(Fail::new(format!("{at} is missing {name}"), USAGE_QF))
            }
            Some(serde_json::Value::Number(n)) => match n.as_u64() {
                Some(0) => Err(Fail::new(
                    format!("{at} has {name} 0, but line and column numbers start at 1"),
                    USAGE_QF,
                )),
                Some(v) => Ok(Some(v)),
                None => Err(Fail::new(
                    format!("{at} field {name} must be a positive integer, got {n}"),
                    USAGE_QF,
                )),
            },
            Some(other) => Err(Fail::new(
                format!(
                    "{at} field {name} must be a positive integer, got {}",
                    json_kind(other)
                ),
                USAGE_QF,
            )),
        }
    };

    Ok(QfItem {
        filename: string_field("filename")?,
        lnum: positive_field("lnum", true)?.expect("required"),
        col: positive_field("col", false)?,
        text: string_field("text")?,
    })
}

fn json_kind(v: &serde_json::Value) -> &'static str {
    match v {
        J::Null => "null",
        J::Bool(_) => "a boolean",
        J::Number(_) => "a number",
        J::String(_) => "a string",
        J::Array(_) => "an array",
        J::Object(_) => "an object",
    }
}

// ---------------------------------------------------------------------------
// execute: every input here is already known-good
// ---------------------------------------------------------------------------

fn execute(invocation: Invocation) -> Result<String, Fail> {
    let (socket, command) = match invocation {
        Invocation::Local(command) => {
            let out = match command {
                Command::Sockets => discover_sockets(),
                _ => unreachable!("only Sockets is local"),
            };
            return serde_json::to_string_pretty(&out)
                .map_err(|e| Fail::new(format!("cannot serialise result: {e}"), USAGE_SOCKETS));
        }
        Invocation::Remote { socket, command } => (socket, command),
    };

    let usage = command.usage();
    let mut nvim = Nvim::connect(&socket, DEFAULT_TIMEOUT).map_err(|e| {
        Fail::new(
            format!(
                "{e}\n\
                 Run `nv sockets` to see which sessions are reachable.\n\
                 If none are, ask the user to start or attach one - do not \
                 start an editor yourself."
            ),
            usage,
        )
    })?;

    let out = match command {
        Command::Sockets => unreachable!("handled above"),
        Command::Ping => ping(&mut nvim),
        Command::Cursor => cursor(&mut nvim),
        Command::Selection => selection(&mut nvim),
        Command::Buffers { only_modified } => buffers(&mut nvim, only_modified),
        Command::Qf { ref title, ref items } => qf_set(&mut nvim, title, items),
        Command::Open { ref file, line } => open(&mut nvim, file, line),
        Command::Cwd => cwd(&mut nvim),
        Command::Cd { ref dir, scope } => cd(&mut nvim, dir.as_deref(), scope),
    }
    .map_err(|e| Fail::new(e.to_string(), usage))?;

    serde_json::to_string_pretty(&out)
        .map_err(|e| Fail::new(format!("cannot serialise result: {e}"), usage))
}

/// Filesystem scan for candidate sockets, then a liveness probe on each.
/// Deliberately reports what it found rather than choosing - picking between
/// several live sessions is the user's call, not ours.
fn discover_sockets() -> serde_json::Value {
    let mut roots: Vec<PathBuf> = Vec::new();
    if let Ok(p) = std::env::var("NVIM_AGENT_SOCKET") {
        roots.push(PathBuf::from(p));
    }
    if let Ok(home) = std::env::var("HOME") {
        roots.push(PathBuf::from(home).join(".cache"));
    }
    roots.push(PathBuf::from(
        std::env::var("TMPDIR").unwrap_or_else(|_| "/tmp".into()),
    ));

    let mut candidates: Vec<PathBuf> = Vec::new();
    for root in roots {
        collect_sockets(&root, 0, &mut candidates);
    }
    candidates.sort();
    candidates.dedup();

    let sessions: Vec<serde_json::Value> = candidates
        .iter()
        .map(|path| {
            let socket = path.display().to_string();
            match probe(path) {
                Ok(v) => v,
                Err(e) => serde_json::json!({
                    "socket": socket,
                    "alive": false,
                    "reason": e.to_string(),
                }),
            }
        })
        .collect();

    let alive = sessions.iter().filter(|s| s["alive"] == J::Bool(true)).count();
    serde_json::json!({
        "sessions": sessions,
        "alive": alive,
        "note": if alive == 0 {
            "No reachable session. Ask the user to start or attach one; do not start an editor yourself."
        } else if alive > 1 {
            "Several sessions are alive. Ask the user which one they mean."
        } else {
            "One session alive; use its socket value."
        },
    })
}

fn collect_sockets(path: &Path, depth: u32, out: &mut Vec<PathBuf>) {
    let Ok(meta) = std::fs::symlink_metadata(path) else {
        return;
    };
    if meta.file_type().is_socket() {
        out.push(path.to_path_buf());
        return;
    }
    if !meta.is_dir() || depth >= 3 {
        return;
    }
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
    // Only descend into plausible places, so this stays fast on a big $TMPDIR.
    if depth > 0 && !name.starts_with("nvim") {
        return;
    }
    let Ok(entries) = std::fs::read_dir(path) else {
        return;
    };
    for entry in entries.flatten() {
        let child = entry.path();
        let child_name = entry.file_name();
        let child_name = child_name.to_str().unwrap_or("");
        if depth == 0 && !child_name.starts_with("nvim") {
            continue;
        }
        collect_sockets(&child, depth + 1, out);
    }
}

fn probe(path: &Path) -> Result<serde_json::Value, Error> {
    let mut nvim = Nvim::connect(&path.display().to_string(), Duration::from_millis(500))?;
    let cwd = nvim.call_function("getcwd", vec![])?;
    let buf = nvim.call("nvim_get_current_buf", vec![])?;
    let file = nvim.call("nvim_buf_get_name", vec![buf])?;
    Ok(serde_json::json!({
        "socket": path.display().to_string(),
        "alive": true,
        "cwd": cwd.as_str().unwrap_or_default(),
        "file": file.as_str().unwrap_or_default(),
    }))
}

fn ping(nvim: &mut Nvim) -> Result<serde_json::Value, Error> {
    let mode = nvim.call("nvim_get_mode", vec![])?;
    let info = nvim.call("nvim_get_api_info", vec![])?;
    let api_level = info
        .as_array()
        .and_then(|a| a.get(1))
        .and_then(|m| lookup(m, "version"))
        .and_then(|v| lookup(&v, "api_level"))
        .and_then(|v| v.as_u64());
    Ok(serde_json::json!({
        "alive": true,
        "mode": to_json(&mode),
        "api_level": api_level,
    }))
}

fn cursor(nvim: &mut Nvim) -> Result<serde_json::Value, Error> {
    let buf = nvim.call("nvim_get_current_buf", vec![])?;
    let name = nvim.call("nvim_buf_get_name", vec![buf.clone()])?;
    let pos = nvim.call("nvim_win_get_cursor", vec![Value::from(0)])?;
    let (line, col) = pos_pair(&pos);
    let text = nvim
        .call(
            "nvim_buf_get_lines",
            vec![
                buf.clone(),
                Value::from(line.saturating_sub(1)),
                Value::from(line),
                Value::from(false),
            ],
        )?
        .as_array()
        .and_then(|a| a.first().cloned())
        .map(|v| to_json(&v));

    Ok(serde_json::json!({
        "file": name.as_str().unwrap_or_default(),
        "line": line,
        "col": col,
        "modified": buf_modified(nvim, &buf)?,
        "text": text,
    }))
}

/// Reads the `'<` / `'>` marks directly. Issues **no motions** and touches no
/// registers - reading context must never mutate the editor.
fn selection(nvim: &mut Nvim) -> Result<serde_json::Value, Error> {
    let buf = nvim.call("nvim_get_current_buf", vec![])?;
    let start = nvim.call("nvim_buf_get_mark", vec![buf.clone(), Value::from("<")])?;
    let end = nvim.call("nvim_buf_get_mark", vec![buf.clone(), Value::from(">")])?;
    let (start_line, start_col) = pos_pair(&start);
    let (end_line, end_col) = pos_pair(&end);

    if start_line == 0 || end_line == 0 {
        return Ok(serde_json::json!({ "selection": null }));
    }

    let lines = nvim.call(
        "nvim_buf_get_lines",
        vec![
            buf.clone(),
            Value::from(start_line.saturating_sub(1)),
            Value::from(end_line),
            Value::from(false),
        ],
    )?;
    let name = nvim.call("nvim_buf_get_name", vec![buf.clone()])?;

    Ok(serde_json::json!({
        "file": name.as_str().unwrap_or_default(),
        "start_line": start_line,
        "start_col": start_col,
        "end_line": end_line,
        "end_col": end_col,
        "modified": buf_modified(nvim, &buf)?,
        "lines": to_json(&lines),
    }))
}

fn buffers(nvim: &mut Nvim, only_modified: bool) -> Result<serde_json::Value, Error> {
    let bufs = nvim.call("nvim_list_bufs", vec![])?;
    let mut out = Vec::new();
    for buf in bufs.as_array().cloned().unwrap_or_default() {
        let modified = buf_modified(nvim, &buf)?;
        if only_modified && !modified {
            continue;
        }
        let name = nvim.call("nvim_buf_get_name", vec![buf.clone()])?;
        let name = name.as_str().unwrap_or_default().to_string();
        if name.is_empty() {
            continue;
        }
        let lines = nvim.call("nvim_buf_line_count", vec![buf.clone()])?.as_u64();
        out.push(serde_json::json!({
            "file": name,
            "modified": modified,
            "lines": lines,
        }));
    }
    Ok(serde_json::json!({ "buffers": out }))
}

fn qf_set(nvim: &mut Nvim, title: &str, items: &[QfItem]) -> Result<serde_json::Value, Error> {
    let encoded = Value::Array(
        items
            .iter()
            .map(|item| {
                let mut fields = vec![
                    (Value::from("filename"), Value::from(item.filename.as_str())),
                    (Value::from("lnum"), Value::from(item.lnum)),
                    (Value::from("text"), Value::from(item.text.as_str())),
                ];
                if let Some(col) = item.col {
                    fields.push((Value::from("col"), Value::from(col)));
                }
                Value::Map(fields)
            })
            .collect(),
    );

    nvim.call_function("setqflist", vec![encoded, Value::from("r")])?;
    nvim.call_function(
        "setqflist",
        vec![
            Value::Array(vec![]),
            Value::from("a"),
            Value::Map(vec![(Value::from("title"), Value::from(title))]),
        ],
    )?;
    let size = nvim.call_function(
        "getqflist",
        vec![Value::Map(vec![(Value::from("size"), Value::from(0))])],
    )?;
    Ok(serde_json::json!({
        "title": title,
        "size": lookup(&size, "size").and_then(|v| v.as_u64()),
    }))
}

fn open(nvim: &mut Nvim, file: &str, line: u64) -> Result<serde_json::Value, Error> {
    // Escape via Neovim itself rather than hand-rolling vim quoting.
    let escaped = nvim.call_function("fnameescape", vec![Value::from(file)])?;
    let escaped = escaped.as_str().unwrap_or(file).to_string();
    nvim.call_function(
        "execute",
        vec![Value::from(format!("edit +{line} {escaped}"))],
    )?;
    cursor(nvim)
}

/// Reports every scope, not just the effective one. The scopes shadow each
/// other (buffer > window > tab > global), so a single number cannot answer
/// "what will change if I re-root this?".
fn cwd(nvim: &mut Nvim) -> Result<serde_json::Value, Error> {
    let effective = getcwd(nvim, vec![])?;
    let global = getcwd(nvim, vec![Value::from(-1), Value::from(-1)])?;
    let tab = getcwd(nvim, vec![Value::from(-1)])?;
    let window = getcwd(nvim, vec![Value::from(0)])?;
    let tab_local = haslocaldir(nvim, vec![Value::from(-1)])?;
    let window_local = haslocaldir(nvim, vec![Value::from(0)])?;

    // getcwd()'s bufnr form and :bcd both landed in 0.13; older sessions have
    // no buffer scope at all, which is different from "buffer scope is unset".
    let buffer_args = vec![Value::from(-1), Value::from(-1), Value::from(0)];
    let (buffer, buffer_local, buffer_supported) = if bcd_supported(nvim)? {
        (
            Some(getcwd(nvim, buffer_args.clone())?),
            haslocaldir(nvim, buffer_args)?,
            true,
        )
    } else {
        (None, false, false)
    };

    Ok(serde_json::json!({
        "effective": effective,
        "global": { "dir": global },
        "tab": { "dir": tab, "local": tab_local },
        "window": { "dir": window, "local": window_local },
        "buffer": { "dir": buffer, "local": buffer_local, "supported": buffer_supported },
    }))
}

/// Re-roots one scope (or unsets it, when `dir` is None), reporting before and
/// after. The report is the point: a directory change is invisible in the
/// editor, so it must not be invisible here.
fn cd(nvim: &mut Nvim, dir: Option<&str>, scope: Scope) -> Result<serde_json::Value, Error> {
    if matches!(scope, Scope::Buffer) && !bcd_supported(nvim)? {
        return Err(Error::Unsupported {
            feature: ":bcd (buffer-local directory)".to_string(),
            hint: "It was added in nvim 0.13. Use --scope window for the narrowest \
                   alternative this session has, or --scope tab."
                .to_string(),
        });
    }

    let before = cwd(nvim)?;
    let ex = match dir {
        // Escape via Neovim itself rather than hand-rolling vim quoting.
        Some(dir) => {
            let escaped = nvim.call_function("fnameescape", vec![Value::from(dir)])?;
            let escaped = escaped.as_str().unwrap_or(dir).to_string();
            format!("{} {escaped}", scope.command())
        }
        None => format!("{}!", scope.command()),
    };
    nvim.call_function("execute", vec![Value::from(ex.clone())])?;
    let after = cwd(nvim)?;

    Ok(serde_json::json!({
        "scope": scope.name(),
        "command": format!(":{ex}"),
        "dir": dir,
        "unset": dir.is_none(),
        "before": before,
        "after": after,
    }))
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn getcwd(nvim: &mut Nvim, args: Vec<Value>) -> Result<String, Error> {
    let v = nvim.call_function("getcwd", args)?;
    Ok(v.as_str().unwrap_or_default().to_string())
}

fn haslocaldir(nvim: &mut Nvim, args: Vec<Value>) -> Result<bool, Error> {
    let v = nvim.call_function("haslocaldir", args)?;
    Ok(v.as_u64() == Some(1))
}

/// `exists(':bcd')` returns 2 for a full command match.
fn bcd_supported(nvim: &mut Nvim) -> Result<bool, Error> {
    let v = nvim.call_function("exists", vec![Value::from(":bcd")])?;
    Ok(v.as_u64().unwrap_or(0) >= 2)
}

fn buf_modified(nvim: &mut Nvim, buf: &Handle) -> Result<bool, Error> {
    let v = nvim.call(
        "nvim_get_option_value",
        vec![
            Value::from("modified"),
            Value::Map(vec![(Value::from("buf"), buf.clone())]),
        ],
    )?;
    Ok(v.as_bool().unwrap_or(false))
}

/// `[row, col]` from mark/cursor calls; row is 1-indexed, col 0-indexed.
fn pos_pair(v: &Value) -> (u64, u64) {
    let a = v.as_array().map(|a| a.to_vec()).unwrap_or_default();
    (
        a.first().and_then(Value::as_u64).unwrap_or(0),
        a.get(1).and_then(Value::as_u64).unwrap_or(0),
    )
}

fn lookup(v: &Value, key: &str) -> Option<Value> {
    v.as_map()?
        .iter()
        .find(|(k, _)| k.as_str() == Some(key))
        .map(|(_, v)| v.clone())
}

fn to_json(v: &Value) -> serde_json::Value {
    match v {
        Value::Nil => J::Null,
        Value::Boolean(b) => J::Bool(*b),
        Value::Integer(i) => i
            .as_i64()
            .map(Into::into)
            .or_else(|| i.as_u64().map(Into::into))
            .unwrap_or(J::Null),
        Value::F32(f) => serde_json::Number::from_f64(*f as f64).map_or(J::Null, J::Number),
        Value::F64(f) => serde_json::Number::from_f64(*f).map_or(J::Null, J::Number),
        Value::String(s) => s.as_str().map_or(J::Null, |s| J::String(s.to_string())),
        Value::Binary(b) => J::String(String::from_utf8_lossy(b).into_owned()),
        Value::Array(a) => J::Array(a.iter().map(to_json).collect()),
        Value::Map(m) => J::Object(
            m.iter()
                .map(|(k, v)| (k.as_str().unwrap_or_default().to_string(), to_json(v)))
                .collect(),
        ),
        Value::Ext(tag, _) => J::String(format!("<handle:{tag}>")),
    }
}
