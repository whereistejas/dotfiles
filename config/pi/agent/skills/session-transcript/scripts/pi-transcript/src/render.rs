use chrono::{DateTime, Utc};

use crate::model::{Block, Content, Entry, Message};
use crate::sessions::{LoadedSession, SessionSummary, active_path};

#[derive(Debug, Clone, Copy, PartialEq, Eq, clap::ValueEnum)]
pub enum ToolMode {
    /// One line per tool call with truncated arguments.
    Digest,
    /// Omit tool calls entirely.
    None,
    /// Full, pretty-printed arguments.
    Full,
}

#[derive(Debug, Clone)]
pub struct RenderOptions {
    pub thinking: bool,
    pub thinking_chars: usize,
    pub tools: ToolMode,
    pub results: usize,
    pub all_branches: bool,
    pub grep: Option<String>,
}

const ARG_DIGEST_CHARS: usize = 160;

pub fn parse_ts(s: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|d| d.with_timezone(&Utc))
}

pub fn hhmmss(ts: &str) -> String {
    match parse_ts(ts) {
        Some(d) => d.format("%H:%M:%S").to_string(),
        None => ts.to_string(),
    }
}

pub fn short_ts(ts: &str) -> String {
    match parse_ts(ts) {
        Some(d) => d.format("%Y-%m-%dT%H:%M:%SZ").to_string(),
        None => ts.to_string(),
    }
}

pub fn duration_between(from: &str, to: &str) -> Option<i64> {
    let a = parse_ts(from)?;
    let b = parse_ts(to)?;
    Some((b - a).num_seconds())
}

pub fn format_duration(secs: i64) -> String {
    if secs < 0 {
        return "-".to_string();
    }
    let h = secs / 3600;
    let m = (secs % 3600) / 60;
    let s = secs % 60;
    if h > 0 {
        format!("{h}h {m}m")
    } else if m > 0 {
        format!("{m}m {s}s")
    } else {
        format!("{s}s")
    }
}

pub fn format_bytes(n: u64) -> String {
    if n >= 1024 * 1024 {
        format!("{:.1}M", n as f64 / (1024.0 * 1024.0))
    } else if n >= 1024 {
        format!("{:.0}K", n as f64 / 1024.0)
    } else {
        format!("{n}B")
    }
}

fn thousands(n: u64) -> String {
    let s = n.to_string();
    let mut out = String::new();
    for (i, c) in s.chars().enumerate() {
        if i > 0 && (s.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(c);
    }
    out
}

fn truncate(s: &str, max: usize) -> String {
    if max == 0 {
        return s.to_string();
    }
    let mut out = String::new();
    for (i, c) in s.chars().enumerate() {
        if i >= max {
            out.push('…');
            return out;
        }
        out.push(c);
    }
    out
}

fn one_line(s: &str, max: usize) -> String {
    let flat = s.split_whitespace().collect::<Vec<_>>().join(" ");
    truncate(&flat, max)
}

fn fence(text: &str) -> String {
    let mut ticks = 3;
    for line in text.lines() {
        let t = line.trim_start();
        if t.starts_with("```") {
            let n = t.chars().take_while(|c| *c == '`').count();
            if n >= ticks {
                ticks = n + 1;
            }
        }
    }
    let bar = "`".repeat(ticks);
    format!("{bar}\n{}\n{bar}", text.trim_end())
}

/// Render a whole session to Markdown.
pub fn render(summary: &SessionSummary, loaded: &LoadedSession, opts: &RenderOptions) -> String {
    let entries = &loaded.entries;
    let path = active_path(entries);
    let selected: Vec<&Entry> = if opts.all_branches {
        entries.iter().collect()
    } else {
        path.iter().map(|&i| &entries[i]).collect()
    };
    let omitted = entries.len().saturating_sub(path.len());

    let cwd = loaded
        .header
        .as_ref()
        .map(|h| h.cwd.clone())
        .unwrap_or_else(|| summary.cwd.clone());
    let started = loaded
        .header
        .as_ref()
        .map(|h| h.timestamp.clone())
        .filter(|t| !t.is_empty())
        .unwrap_or_else(|| summary.started.clone());
    let ended = selected
        .last()
        .and_then(|e| e.timestamp.clone())
        .unwrap_or_else(|| summary.ended.clone());

    let mut out = String::new();
    out.push_str(&format!("# Session {}\n", summary.id));
    if !cwd.is_empty() {
        out.push_str(&format!("- cwd: {cwd}\n"));
    }
    out.push_str(&format!("- started: {}\n", short_ts(&started)));
    match duration_between(&started, &ended) {
        Some(secs) => out.push_str(&format!(
            "- ended: {} ({})\n",
            short_ts(&ended),
            format_duration(secs)
        )),
        None => out.push_str(&format!("- ended: {}\n", short_ts(&ended))),
    }
    if opts.all_branches {
        out.push_str(&format!(
            "- messages: {} (all branches, linear file order)\n",
            summary.messages
        ));
    } else {
        let msgs_on_path = selected.iter().filter(|e| e.kind == "message").count();
        if omitted > 0 {
            out.push_str(&format!(
                "- messages: {} ({} entries on abandoned branches, omitted)\n",
                msgs_on_path, omitted
            ));
        } else {
            out.push_str(&format!("- messages: {}\n", msgs_on_path));
        }
    }
    if loaded.bad_lines > 0 {
        out.push_str(&format!("- unparsable lines: {}\n", loaded.bad_lines));
    }
    out.push_str(&format!("- source: {}\n", summary.path.display()));

    let needle = opts.grep.as_ref().map(|g| g.to_lowercase());
    let mut matched = 0usize;
    let mut blocks = Vec::new();
    for entry in &selected {
        if let Some(block) = render_entry(entry, opts) {
            if let Some(n) = &needle {
                if !block.to_lowercase().contains(n.as_str()) {
                    continue;
                }
                matched += 1;
            }
            blocks.push(block);
        }
    }

    if let Some(g) = &opts.grep {
        out.push_str(&format!("- grep: `{g}` ({matched} matching entries)\n"));
    }
    if !opts.all_branches && omitted > 0 {
        out.push_str(&format!(
            "\n_({omitted} entries on abandoned branches omitted; --all-branches to include)_\n"
        ));
    }
    out.push('\n');
    out.push_str(&blocks.join("\n"));
    if !out.ends_with('\n') {
        out.push('\n');
    }
    out
}

fn render_entry(entry: &Entry, opts: &RenderOptions) -> Option<String> {
    let time = entry.timestamp.as_deref().map(hhmmss).unwrap_or_default();
    match entry.kind.as_str() {
        "message" => render_message(entry, &time, opts),
        "model_change" => Some(format!(
            "_[model: {}/{}]_\n",
            entry.provider.as_deref().unwrap_or("?"),
            entry.model_id.as_deref().unwrap_or("?")
        )),
        "thinking_level_change" => Some(format!(
            "_[thinking level: {}]_\n",
            entry.thinking_level.as_deref().unwrap_or("?")
        )),
        "compaction" => {
            let tokens = entry
                .tokens_before
                .map(thousands)
                .unwrap_or_else(|| "?".to_string());
            let mut s = format!("_[compaction: {tokens} tokens summarized]_\n");
            if let Some(sum) = &entry.summary {
                s.push_str(&format!("> {}\n", one_line(sum, 300)));
            }
            Some(s)
        }
        "branch_summary" => {
            let mut s = format!(
                "_[branch summary: returned from an abandoned branch at {}]_\n",
                entry.from_id.as_deref().unwrap_or("?")
            );
            if let Some(sum) = &entry.summary {
                s.push_str(&format!("> {}\n", one_line(sum, 300)));
            }
            Some(s)
        }
        "label" => entry.label.as_ref().map(|l| {
                format!(
                    "_[label: {} on {}]_\n",
                    one_line(l, 80),
                    entry.target_id.as_deref().unwrap_or("?")
                )
            }),
        "session_info" => entry
            .name
            .as_ref()
            .map(|n| format!("_[session name: {}]_\n", one_line(n, 80))),
        "custom_message" => {
            if entry.display == Some(false) {
                return None;
            }
            let text = entry
                .content
                .as_ref()
                .map(|c| c.plain_text())
                .unwrap_or_default();
            if text.trim().is_empty() {
                return None;
            }
            Some(format!(
                "## custom:{} · {time}\n\n{}\n",
                entry.custom_type.as_deref().unwrap_or("?"),
                text.trim_end()
            ))
        }
        "custom" => None,
        _ => None,
    }
}

fn render_message(entry: &Entry, time: &str, opts: &RenderOptions) -> Option<String> {
    let message = entry.message.as_ref()?;
    match message {
        Message::User { content } => {
            let text = render_user_content(content);
            if text.trim().is_empty() {
                return None;
            }
            Some(format!("## user · {time}\n\n{}\n", text.trim_end()))
        }
        Message::Assistant {
            content,
            stop_reason,
            error_message,
            ..
        } => {
            let mut body = String::new();
            for block in content.blocks() {
                match block {
                    Block::Thinking { thinking, redacted } => {
                        if !opts.thinking {
                            continue;
                        }
                        if redacted == Some(true) {
                            body.push_str("(thinking) _[redacted]_\n\n");
                            continue;
                        }
                        let t = thinking.trim();
                        if t.is_empty() {
                            continue;
                        }
                        body.push_str(&format!(
                            "(thinking) {}\n\n",
                            truncate(t, opts.thinking_chars)
                        ));
                    }
                    Block::Text { text } => {
                        let t = text.trim();
                        if !t.is_empty() {
                            body.push_str(t);
                            body.push_str("\n\n");
                        }
                    }
                    Block::ToolCall { name, arguments } => match opts.tools {
                        ToolMode::None => {}
                        ToolMode::Digest => {
                            let args = serde_json::to_string(&arguments).unwrap_or_default();
                            body.push_str(&format!(
                                "→ {name} {}\n",
                                one_line(&args, ARG_DIGEST_CHARS)
                            ));
                        }
                        ToolMode::Full => {
                            let args =
                                serde_json::to_string_pretty(&arguments).unwrap_or_default();
                            body.push_str(&format!("→ {name}\n{}\n", fence(&args)));
                        }
                    },
                    Block::Image { mime_type } => {
                        body.push_str(&format!(
                            "_[image: {}]_\n\n",
                            mime_type.as_deref().unwrap_or("image")
                        ));
                    }
                    Block::Other => {}
                }
            }
            if let Some(err) = error_message {
                body.push_str(&format!("_[error: {}]_\n", one_line(err, 200)));
            } else if stop_reason.as_deref() == Some("aborted") {
                body.push_str("_[aborted]_\n");
            }
            if body.trim().is_empty() {
                return None;
            }
            Some(format!(
                "## assistant · {time}\n\n{}\n",
                body.trim_end()
            ))
        }
        Message::ToolResult {
            tool_name,
            content,
            is_error,
        } => {
            if opts.results == 0 {
                return None;
            }
            let name = tool_name.as_deref().unwrap_or("tool");
            let text = content.plain_text();
            let marker = if *is_error { " (error)" } else { "" };
            let body = truncate(text.trim_end(), opts.results);
            if body.trim().is_empty() {
                return Some(format!("_[result: {name}{marker} — empty]_\n"));
            }
            Some(format!(
                "_[result: {name}{marker}]_\n{}\n",
                fence(&body)
            ))
        }
        Message::BashExecution {
            command,
            output,
            exit_code,
        } => {
            let mut s = format!("## bash · {time}\n\n$ {}\n", one_line(command, 200));
            if let Some(code) = exit_code
                && *code != 0
            {
                s.push_str(&format!("_[exit {code}]_\n"));
            }
            if opts.results > 0 && !output.trim().is_empty() {
                s.push_str(&fence(&truncate(output.trim_end(), opts.results)));
                s.push('\n');
            }
            Some(s)
        }
        Message::Other => None,
    }
}

fn render_user_content(content: &Content) -> String {
    let mut out = String::new();
    match content {
        Content::Blocks(blocks) => {
            for block in blocks {
                match block {
                    Block::Text { text } => {
                        out.push_str(text.trim());
                        out.push_str("\n\n");
                    }
                    Block::Image { mime_type } => out.push_str(&format!(
                        "_[image: {}]_\n\n",
                        mime_type.as_deref().unwrap_or("image")
                    )),
                    _ => {}
                }
            }
        }
        other => out.push_str(other.plain_text().trim()),
    }
    out
}
