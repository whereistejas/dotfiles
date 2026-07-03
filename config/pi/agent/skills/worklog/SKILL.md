---
name: worklog
description: Where and how to record daily work notes across projects. Use whenever asked to "log", "write up", or "update the worklog" for a work session, or when starting a session that should be logged.
---

# worklog

Two-tier convention, both tiers living in the Obsidian vault: a short
daily summary, plus a full-detail per-project log.

- Vault: `~/build/notes` (has both `.git` and `.jj` — use `jj` for VCS
  operations there, per the global convention of preferring `jj`).

## Tooling: use the Obsidian CLI only

All worklog reads and writes MUST go through the `obsidian` CLI (see the
`obsidian-cli` skill). Do **not** read or edit vault files directly with
filesystem tools (`Read`/`Write`/`Edit`, or `cat`/`sed`/redirects in
`bash`) — even though the vault path is known, direct edits bypass
Obsidian's index and daily-note/template handling.

- Read a note: `obsidian read path="..."` (or `obsidian daily:read`).
- Append to a note: `obsidian append path="..." content="..."` (or
  `obsidian daily:append content="..."`).
- Create a note: `obsidian create name="..." content="..." silent`.
- Toggle/complete a task checkbox: `obsidian task path="..." line=<n> done`
  (find the line with `obsidian tasks path="..." verbose`).
- Set frontmatter/properties: `obsidian property:set name="..." value="..." path="..."`.
- Target this vault explicitly with `vault="notes"` when the focused vault
  is ambiguous.

Obsidian must be running for the CLI to work; if a command reports no
running instance, say so rather than falling back to direct file edits.

## Daily summary

- Lives at `Daily Notes/YYYY.MM.DD.md` (matches the vault's
  `.obsidian/daily-notes.json` config: `format: "YYYY.MM.DD"`,
  `folder: "Daily Notes"`).
- Append (don't replace) a `## Work Log` section to the day's note. If the
  note or section doesn't exist yet, create it.
- Keep this section a *summary*: what repo/ticket/branch, what got
  decided, what got done, what's still open — a few bullets per thread,
  not a full transcript. Link out to the detailed log (see below) with a
  wikilink rather than duplicating it.
- For any nontrivial piece of work, mention explicitly: the repository,
  any Jira ticket it's tied to, and the branch/bookmark name(s) involved.
  Don't assume these are obvious from context later.

## Detailed log

- Lives in the vault too, at `Work Logs/<project>/YYYY-MM-DD.md` (e.g.
  `Work Logs/agentic-sdlc/2026-07-08.md`) — **not** in the project's own
  repo. `<project>` is the repo/project name the work is about.
- Full session detail goes here: what was tried, what broke, exact
  commands, decisions and why, file/line references.
- One file per day per project thread; append new sessions to the same
  day's file if you pick the thread back up later that day (add a new
  `## Session N: ...` heading rather than rewriting prior sessions).
- The daily summary note should link here with a wikilink, e.g.:
  `[[Work Logs/agentic-sdlc/2026-07-08|agentic-sdlc work log]]`.

## Session id tracking

Every pi session has an id, visible in the filename of its transcript
under `~/.pi/agent/sessions/<escaped-cwd>/<timestamp>_<session-id>.jsonl`
(the `<session-id>` is the UUID after the underscore; match by cwd and
recency, or by grepping the `.jsonl` files for distinctive session
content if the cwd differs from where the log is being written).

Record which session(s) authored each note in that note's frontmatter, as
a `sessions` list (one entry per session that appended to the note,
across its lifetime — don't overwrite earlier entries when a new session
appends):

```yaml
---
sessions:
  - id: 019f4126-6595-7a5c-be85-b98a1bf2477d
    date: 2026-07-08T09:54:23Z
---
```

Apply this to both the daily summary note and the detailed per-project
log note. If a note already has content predating this convention and
the authoring session can't be identified with confidence, say so
explicitly (e.g. `id: unknown # predates session-id tracking`) rather
than guessing.

## Formatting

Use standard Obsidian-flavored Markdown (see the `obsidian-markdown`
skill for wikilinks, callouts, properties, etc.) where it helps
readability, but don't over-format — this is a working log, not a
polished note.

## Rationale

Keeping both tiers in the vault (rather than the detail living in each
project's own repo) makes the vault the single source of truth for work
history, searchable/linkable across projects in one place, and avoids
scattering log files across unrelated repos. The daily note stays a fast,
skimmable index; the per-project log holds the messy detail.
