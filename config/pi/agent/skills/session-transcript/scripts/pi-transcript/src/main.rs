mod model;
mod render;
mod sessions;

use std::io::Write;
use std::path::{Path, PathBuf};

use clap::{Parser, Subcommand, ValueEnum};

use render::{RenderOptions, ToolMode};
use sessions::SessionSummary;

/// Compact renderer for past pi session transcripts.
#[derive(Parser, Debug)]
#[command(
    name = "pi-transcript",
    about = "Find and render past pi session transcripts in compact Markdown",
    version
)]
struct Cli {
    /// Sessions root (default: $PI_SESSIONS_DIR or ~/.pi/agent/sessions)
    #[arg(long, global = true)]
    sessions_dir: Option<PathBuf>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Locate sessions by id, cwd or date.
    Find(FindArgs),
    /// Render one session as compact Markdown.
    Read(ReadArgs),
}

#[derive(Parser, Debug)]
struct FindArgs {
    /// Session id or unique id prefix
    #[arg(long)]
    id: Option<String>,
    /// Match sessions whose header cwd equals or contains this path
    #[arg(long)]
    cwd: Option<String>,
    /// Only sessions started on or after this date (YYYY-MM-DD)
    #[arg(long)]
    since: Option<String>,
    /// Only sessions started on or before this date (YYYY-MM-DD)
    #[arg(long)]
    until: Option<String>,
    /// Maximum number of sessions to print, most recent first
    #[arg(long, default_value_t = 20)]
    limit: usize,
    /// Output format
    #[arg(long, value_enum, default_value_t = OutputFormat::Table)]
    format: OutputFormat,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
enum OutputFormat {
    Table,
    Json,
}

#[derive(Parser, Debug)]
struct ReadArgs {
    /// Session id or unique id prefix
    id: String,
    /// Include assistant thinking blocks (default)
    #[arg(long)]
    thinking: bool,
    /// Omit assistant thinking blocks
    #[arg(long, conflicts_with = "thinking")]
    no_thinking: bool,
    /// Truncate each thinking block to N chars (0 = no truncation)
    #[arg(long, default_value_t = 300)]
    thinking_chars: usize,
    /// How to render tool calls
    #[arg(long, value_enum, default_value_t = ToolMode::Digest)]
    tools: ToolMode,
    /// Include tool results, truncated to N chars each (0 = omit results)
    #[arg(long, default_value_t = 0)]
    results: usize,
    /// Render every entry in file order, including abandoned branches
    #[arg(long)]
    all_branches: bool,
    /// Only render entries containing this substring (case-insensitive)
    #[arg(long)]
    grep: Option<String>,
}

fn main() {
    let cli = Cli::parse();
    let root = cli
        .sessions_dir
        .clone()
        .unwrap_or_else(sessions::default_sessions_dir);

    let result = match &cli.command {
        Command::Find(args) => run_find(&root, args),
        Command::Read(args) => run_read(&root, args),
    };

    if let Err(err) = result {
        eprintln!("pi-transcript: {err}");
        std::process::exit(1);
    }
}

fn run_find(root: &Path, args: &FindArgs) -> Result<(), sessions::Error> {
    let mut found: Vec<SessionSummary> = sessions::all_summaries(root)?
        .into_iter()
        .filter(|s| match &args.id {
            Some(id) => {
                let needle = id.to_ascii_lowercase();
                let sid = s.id.to_ascii_lowercase();
                sid == needle || sid.starts_with(&needle)
            }
            None => true,
        })
        .filter(|s| match &args.cwd {
            Some(cwd) => s.cwd == *cwd || s.cwd.contains(cwd.as_str()),
            None => true,
        })
        .filter(|s| match &args.since {
            Some(since) => s.started.as_str() >= since.as_str(),
            None => true,
        })
        .filter(|s| match &args.until {
            // compare on the date prefix so --until 2026-07-08 includes that day
            Some(until) => s.started.len() >= 10 && &s.started[..10] <= until.as_str(),
            None => true,
        })
        .collect();

    found.truncate(args.limit);

    let stdout = std::io::stdout();
    let mut out = stdout.lock();

    match args.format {
        OutputFormat::Json => {
            let items: Vec<serde_json::Value> = found
                .iter()
                .map(|s| {
                    serde_json::json!({
                        "id": s.id,
                        "cwd": s.cwd,
                        "started": s.started,
                        "ended": s.ended,
                        "durationSeconds": render::duration_between(&s.started, &s.ended),
                        "messages": s.messages,
                        "entries": s.entries,
                        "bytes": s.bytes,
                        "path": s.path.display().to_string(),
                    })
                })
                .collect();
            let _ = writeln!(
                out,
                "{}",
                serde_json::to_string_pretty(&items).unwrap_or_default()
            );
        }
        OutputFormat::Table => {
            if found.is_empty() {
                let _ = writeln!(out, "no sessions matched");
                return Ok(());
            }
            let _ = writeln!(
                out,
                "{:<36}  {:<20}  {:<20}  {:>8}  {:>5}  {:>6}  CWD",
                "ID", "STARTED", "ENDED", "DURATION", "MSGS", "SIZE"
            );
            for s in &found {
                let dur = render::duration_between(&s.started, &s.ended)
                    .map(render::format_duration)
                    .unwrap_or_else(|| "-".to_string());
                let _ = writeln!(
                    out,
                    "{:<36}  {:<20}  {:<20}  {:>8}  {:>5}  {:>6}  {}",
                    s.id,
                    render::short_ts(&s.started),
                    render::short_ts(&s.ended),
                    dur,
                    s.messages,
                    render::format_bytes(s.bytes),
                    s.cwd
                );
            }
        }
    }
    Ok(())
}

fn run_read(root: &Path, args: &ReadArgs) -> Result<(), sessions::Error> {
    let summary = sessions::resolve(root, &args.id)?;
    let loaded = sessions::load(&summary.path)?;
    let opts = RenderOptions {
        thinking: !args.no_thinking,
        thinking_chars: args.thinking_chars,
        tools: args.tools,
        results: args.results,
        all_branches: args.all_branches,
        grep: args.grep.clone(),
    };
    let markdown = render::render(&summary, &loaded, &opts);
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    let _ = out.write_all(markdown.as_bytes());
    Ok(())
}
