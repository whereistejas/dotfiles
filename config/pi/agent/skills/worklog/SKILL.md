---
name: worklog
description: How work is recorded in the Obsidian vault — one worklog note per pi session, work items as nested tags carrying a Jira key, ticket notes, and an itemized daily note. Use whenever asked to "log", "write up", or "update the worklog" for a work session, when starting a session that should be logged, or when asked what the current work item is.
---

# worklog

## Start here: read the current work item FIRST

Whenever a request touches the worklog — "check the worklog", "log this",
"update the worklog", "what am I working on" — the **first** action is to
read the current work item. Do not open worklog notes, grep the vault, or
ask the user what they're working on before doing this.

```bash
DAILY=$(obsidian vault="notes" daily:path)
obsidian vault="notes" property:read name="tags" path="$DAILY" | head -n 1
```

The first line of the daily note's `tags` **is** the current work item —
see [The `tags` invariant](#the-tags-invariant). It yields, for free:

- the Jira key → `Tickets/<KEY>.md` and `jira-cli read <KEY>`
- the slug → the `#wi/<KEY>/<slug>` section heading to search for
- which of the day's sections is the live one

The work item is set deliberately so the agent can reach the current task
and its context immediately. Treat it as the entry point, not as trivia
to confirm later.

## The model

```
Jira ticket  >  work item  >  session  >  worklog
```

- **One worklog note per pi session.** Never more, never fewer.
- A worklog contains one or more **sections**; each section is one unit of
  work.
- A section that has a Jira ticket **is a work item** and carries a
  `#wi/<KEY>/<slug>` tag.
- A section without a ticket is not a work item and carries `#untracked`.
- **Work items are tags, not notes and not folders.** Tickets are notes.

The vault is `~/build/notes` (has both `.git` and `.jj` — use `jj` there,
per the global convention).

## Tooling: use the Obsidian CLI only

All vault reads and writes MUST go through the `obsidian` CLI. Do **not**
read or edit vault notes with filesystem tools (`Read`/`Write`/`Edit`, or
`cat`/`sed`/redirects in `bash`) — even though the vault path is known,
direct edits bypass Obsidian's index and daily-note/template handling.

- Read a note: `obsidian vault="notes" read path="..."` (or `daily:read`).
- Append: `obsidian vault="notes" append path="..." content="..."`.
- Create: `obsidian vault="notes" create path="..." template="Worklog"`.
- Properties: `obsidian vault="notes" property:read name="..." path="..."`
  and `property:set name="..." value="..." type="..." path="..."`.
- Always pass `vault="notes"` — the focused vault is otherwise ambiguous.

Obsidian must be running. If a command reports no running instance, **say
so** rather than falling back to direct file edits.

**Exception:** `.obsidian/*.json` config files and `.base` files are not
notes and have no CLI command. Those are written directly on disk, then
`obsidian vault="notes" reload`. The canonical copies live in this
skill's `assets/` directory (see [Vault assets](#vault-assets)).

## Finding the session id

Inside a running pi session the environment already has it — this is the
cheapest source and should be the default:

```bash
echo "$PI_SESSION_ID"     # 019fa8ca-c427-7d17-a5ed-e8650281064f
echo "$PI_SESSION_FILE"   # .../sessions/<escaped-cwd>/<timestamp>_<id>.jsonl
```

For a **past** session, use the `session-transcript` skill and its
`pi-transcript` CLI (`find` to locate a session, `read` to reconstruct
it). As a last-resort fallback, session ids are also the UUID after the
underscore in transcript filenames under
`~/.pi/agent/sessions/<escaped-cwd>/<timestamp>_<session-id>.jsonl`
— match by cwd and recency.

The session start time (for `started:`) is the timestamp in the
transcript filename, or the first entry in the transcript. **End time is
not stored** in the note; it is derivable from the transcript.

## Naming conventions

| thing | form | example |
| --- | --- | --- |
| worklog file | `Work Logs/<session-id>.md`, **flat** | `Work Logs/019fa8ca-c427-7d17-a5ed-e8650281064f.md` |
| worklog alias | `YYYY-MM-DD <primary-repo> — <short title>` | `2026-01-15 widget-lib — add response caching` |
| work item tag | `#wi/<TICKET-KEY>/<kebab-slug>` | `#wi/ABC-123/add-response-caching` |
| unticketed section | `#untracked` | `#untracked` |
| ticket note | `Tickets/<KEY>.md`, alias `<KEY> — <jira summary>` | `Tickets/ABC-123.md` |
| legacy notes | `Work Logs/Legacy/` | — |

- The filename is the **full UUID**, exactly matching the session id in
  the transcript filename. No subfolders. The old
  `Work Logs/<project>/YYYY-MM-DD.md` layout is **retired**.
- Wikilinks resolve through aliases, so `[[2026-01-15 widget-lib — rebase
  caching MRs]]` reads naturally while the file stays a UUID.
- **The ticket key in a work item tag is MANDATORY.** That is the whole
  point — it forces work to be ticketed. `#wi/ABC-123` then collects
  every work item on that ticket via the tag pane.
- `#untracked` exists so unticketed work stays greppable and can be
  retro-ticketed later.
- If a session crosses midnight, the alias date and the `date:` property
  are the session **start** date.

## Section headers

H2, with the tag at the **end of the heading line**:

```markdown
## ABC-123 — rebase the three caching MRs #wi/ABC-123/add-response-caching
## fastmcp reconnaissance #untracked
```

One H2 per unit of work. Sub-structure (H3+) inside a section is free-form.

## Worklog frontmatter

```yaml
---
aliases:
  - 2026-01-15 widget-lib — add response caching
session_id: 019fa8ca-c427-7d17-a5ed-e8650281064f
date: 2026-01-15
started: 2026-01-15T09:30:00Z
summary: One-sentence description of the whole session.
tickets:
  - "[[Tickets/ABC-123|ABC-123]]"
repos:
  - widget-lib
  - widget-app
branches:
  - "widget-lib:ABC-123-add-caching"
changes:
  - "widget-lib:qpvuntsm"
commits:
  - "widget-lib:b2c3d4e5"
reviews:
  - "gitlab:example-org/widgets/widget-lib!23"
  - "codereview:4242"
---
```

Rules — these are decided, do not improvise:

- `tickets` entries are **wikilinks**. The ticket note's backlinks pane is
  then the ticket→worklog index for free, at zero maintenance cost.
- `branches`, `changes`, `commits` are `<repo>:<value>` — **flat lists,
  never nested objects.** Obsidian properties cannot represent objects.
- `changes` are **jj change ids** (stable across rebase); `commits` are
  **git shas at push time** (unstable). Record **BOTH** — this was an
  explicit decision; the change id survives rebases, the sha is what
  reviewers and CI actually saw.
- `reviews` are prefixed `gitlab:`, `github:`, or `codereview:`.
- **Work items are deliberately NOT a frontmatter property.** They live as
  body tags only; Bases reads them via `file.tags`. Do not duplicate them
  into frontmatter.
- There is **no `status` property**.
- There is **no `sessions` list** — that was the old multi-session model.
  One session per note, so `session_id` is singular.
- End time is not stored.

### The body table

Frontmatter cannot hold everything legibly. When several repos are
involved, the body should still carry a markdown table joining
repo → MR → branch → before/after sha:

```markdown
| repo | MR | bookmark | before → after | main was ahead by |
| --- | --- | --- | --- | --- |
| `widget-lib` | [!23](https://gitlab.example.com/example-org/widgets/widget-lib/-/merge_requests/23) | `ABC-123-add-caching` | `a1b2c3d4` → `b2c3d4e5` | 16 |
| `widget-app` | [!69](https://gitlab.example.com/example-org/widgets/widget-app/-/merge_requests/69) | `ABC-123-wire-cache` | `c3d4e5f6` → `d4e5f6a7` | 39 |
```

Beyond that, the body carries the real detail: what was tried, what
broke, exact commands, decisions and why, file/line references, and an
explicit "still open" list.

## Creating a worklog

```bash
W="Work Logs/${PI_SESSION_ID}.md"
obsidian vault="notes" create path="$W" template="Worklog"
```

The core Templates plugin only substitutes `{{title}}`, `{{date}}` and
`{{time}}` — it **cannot** fill `session_id`, `tickets`, `repos`, etc.
So the template is a skeleton with empty properties and the agent fills
the rest afterwards:

```bash
obsidian vault="notes" property:set path="$W" name="session_id" \
  value="$PI_SESSION_ID" type="text"
obsidian vault="notes" property:set path="$W" name="started" \
  value="2026-01-15T09:30:00Z" type="datetime"
obsidian vault="notes" property:set path="$W" name="date" \
  value="2026-01-15" type="date"
obsidian vault="notes" property:set path="$W" name="summary" \
  value="Rebased the three ABC-123 caching MRs onto main." type="text"
obsidian vault="notes" property:set path="$W" name="aliases" \
  value="2026-01-15 widget-lib — add response caching" type="list"
obsidian vault="notes" property:set path="$W" name="tickets" \
  value="[[Tickets/ABC-123|ABC-123]]" type="list"
obsidian vault="notes" property:set path="$W" name="repos" \
  value="widget-lib,widget-app,widget-infra" type="list"
obsidian vault="notes" property:set path="$W" name="branches" \
  value="widget-lib:ABC-123-add-caching,widget-app:ABC-123-wire-cache" type="list"
obsidian vault="notes" property:set path="$W" name="changes" \
  value="widget-lib:qpvuntsm,widget-infra:kkmpptxz" type="list"
obsidian vault="notes" property:set path="$W" name="commits" \
  value="widget-lib:b2c3d4e5,widget-app:d4e5f6a7" type="list"
obsidian vault="notes" property:set path="$W" name="reviews" \
  value="gitlab:example-org/widgets/widget-lib!23,codereview:4242" type="list"
```

`type="list"` takes a comma-separated `value` and writes a proper YAML
list. Body content (sections, tables, prose) goes in with `append`.

## Gathering the metadata mechanically

Fill the frontmatter from commands, not from memory.

### repos / branches / changes / commits — `jj`

Run these **in each repo** the session touched.

```bash
# repo name (the value used as the <repo> prefix everywhere)
basename "$(jj root)"

# bookmarks in this repo, with their change + commit ids
jj bookmark list

# the commits on a bookmark that are not yet on trunk:
# change id (stable across rebase) + git sha (what was pushed)
jj log -r 'trunk()..ABC-123-add-caching' --no-graph \
  -T 'change_id.short(8) ++ " " ++ commit_id.short(8) ++ " " ++ description.first_line() ++ "\n"'

# everything authored in this session's working stack, if no bookmark yet
jj log -r '::@ & ~::trunk()' --no-graph \
  -T 'change_id.short(8) ++ " " ++ commit_id.short(8) ++ " " ++ description.first_line() ++ "\n"'

# before → after shas for the body table, around a rebase/force-push
jj log -r 'ABC-123-add-caching@origin' --no-graph -T 'commit_id.short(8)'
jj log -r 'ABC-123-add-caching'        --no-graph -T 'commit_id.short(8)'
```

`change_id` values go in `changes:`, `commit_id` values in `commits:`,
each prefixed `<repo>:`.

### merge requests — the `gitlab` skill

Use the `gitlab` skill's CLI to fetch MR metadata (title, state,
source/target branch) for the `reviews:` entry and the body table. See
that skill's SKILL.md for the exact invocation.

Check the remote first — not every host has merge requests:

```bash
jj git remote list
```

### Code review ids — the `codereview` skill

Hosts without merge requests use a separate review system; those are
recorded as `codereview:<id>`, where the id is the numeric review id from
the review URL. See the `codereview` skill for how to fetch one.

### Jira ticket summary/status — the `jira` skill

Needed to write or refresh a ticket note:

```bash
cargo run -q --offline \
  --manifest-path ~/.pi/agent/skills/jira/scripts/jira-cli/Cargo.toml \
  -- read ABC-123
```

```bash
# find a ticket when you only know roughly what it is
cargo run -q --offline \
  --manifest-path ~/.pi/agent/skills/jira/scripts/jira-cli/Cargo.toml \
  -- search "assignee = currentUser() ORDER BY updated DESC" --max 10
```

## Ticket notes

`Tickets/<KEY>.md`, alias `<KEY> — <jira summary>` (summary taken from
`jira-cli read`).

```bash
obsidian vault="notes" create path="Tickets/ABC-123.md"
obsidian vault="notes" property:set path="Tickets/ABC-123.md" name="aliases" \
  value="ABC-123 — Add response caching to the widget service" type="list"
```

The note itself only needs the ticket's own context. It does **not** need
a manually maintained list of worklogs — the `tickets:` wikilinks in
every worklog make the backlinks pane that index automatically.

If a section has no ticket, tag it `#untracked` and, when a ticket is
later created, replace the tag with `#wi/<KEY>/<slug>` and add the
wikilink to `tickets:`.

## Daily note

- Path `Daily Notes/YYYY.MM.DD.md` — format `YYYY.MM.DD`, folder
  `Daily Notes`, from `.obsidian/daily-notes.json`.
- The daily note is an **itemized summary of the day: one entry per
  section / work item, not one per worklog.** A session with three
  sections produces three daily-note entries.
- Each entry links to the worklog **by alias**:
  `[[2026-01-15 widget-lib — add response caching]]`.
- Each entry **repeats the work item tag** (or `#untracked`).
- Every entry must explicitly name **the repository, the Jira ticket, and
  the branch/bookmark**. Do not assume these are obvious in hindsight.
- Keep entries a summary — what got decided, what got done, what's still
  open. The detail lives in the worklog.
- A session crossing midnight is mentioned in the **start day's** note,
  and also in the next day's note if substantive work continued.

```markdown
## Work Log

### ABC-123 — rebased all three caching MRs onto main #wi/ABC-123/add-response-caching
- **Repos** `widget-lib`, `widget-app`, `widget-infra`; **branches**
  `ABC-123-add-caching`, `ABC-123-wire-cache`,
  `ABC-123-example-adr`; **Jira** [[Tickets/ABC-123|ABC-123]].
- All three force-pushed; jj 0.43 silently drops a gitlink when
  "resolving" a 2-sided submodule conflict — worked around with a carrier
  commit.
- Still open: `widget-lib` pin must move to a merged sha before either
  dependent MR merges.
- Detail: [[2026-01-15 widget-lib — add response caching]].

### fastmcp reconnaissance #untracked
- **Repo** `other-repo`; **branch** none yet; **Jira** none yet — needs a
  ticket.
- Reconnaissance only, no code changed.
- Detail: [[2026-01-15 other-repo — fastmcp reconnaissance]].
```

```bash
obsidian vault="notes" daily:append content="..."
```

## The `tags` invariant

> **The daily note's `tags` property is used for NOTHING except work item
> tags, most recent first. The first entry is the current work item.**

This is a manually upheld invariant, and **everything downstream depends
on it** — status bars, footers, and any tooling that asks "what am I
working on right now" read the first line of that property and nothing
else. Never put a topic tag, a mood tag, or any other tag in a daily
note's `tags`. If you need other tags on a daily note, put them in the
body.

(The old dedicated work-item frontmatter property is **retired**. It no
longer exists anywhere and must not be reintroduced — the daily note's
`tags` property is the single source of truth.)

Verified CLI behaviour:

```bash
DAILY=$(obsidian vault="notes" daily:path)

# one tag per line, WITHOUT a leading "#", in frontmatter order
# → the current work item is the FIRST line
obsidian vault="notes" property:read name="tags" path="$DAILY"

# same tags WITH "#", but sorted alphabetically — not usable for "current"
obsidian vault="notes" tags path="$DAILY"
```

Setting `tags` — comma-separated `value` with `type="list"` writes a
proper YAML list:

```bash
obsidian vault="notes" property:set name="tags" \
  value="wi/ABC-123/add-response-caching,untracked" type="list" path="$DAILY"
```

To switch the current work item, **prepend** and de-duplicate rather than
overwriting, so the day's history is preserved in order:

```bash
DAILY=$(obsidian vault="notes" daily:path)
NEW="wi/ABC-123/add-response-caching"
CUR=$(obsidian vault="notes" property:read name="tags" path="$DAILY")
LIST=$(printf '%s\n%s\n' "$NEW" "$CUR" | awk 'NF && !seen[$0]++' | paste -sd, -)
obsidian vault="notes" property:set name="tags" value="$LIST" type="list" path="$DAILY"
```

Frontmatter tags carry no leading `#` — write `wi/ABC-123/slug`, not
`#wi/ABC-123/slug`. Consumers add the `#` for display.

## Vault assets

Canonical copies live in this skill's `assets/` directory and are
installed into the vault:

| asset | installs to | how |
| --- | --- | --- |
| `assets/Worklog.md` | `Templates/Worklog.md` | via `obsidian create`; core Templates plugin points at `Templates/` |
| `assets/Work Logs.base` | `Work Logs.base` (vault root) | written directly, then `obsidian reload` |
| `assets/types-additions.json` | merged into `.obsidian/types.json` | written directly, then `obsidian reload` |

`.base` and `.obsidian/*.json` are not notes, have no CLI command, and
are the only files written to the vault with filesystem tools.

`Work Logs.base` provides five views: **All worklogs** (date DESC),
**By ticket**, **By repo**, **Untracked** (work still needing a ticket),
and **Legacy**.

The clickable title column is the **`worklog` formula**, not `aliases`:
Bases renders a raw `aliases` property as plain text, so it cannot be
clicked. The formula wraps it in a link —
`file.asLink(if(note.aliases.isEmpty(), file.name, note.aliases.join(", ")))`
— and every view orders on `formula.worklog`. Do not put bare `aliases`
back in a view's `order`.

`types-additions.json` registers the new schema's property types
(`session_id`, `started`, `summary`, `tickets`, `repos`, `branches`,
`changes`, `commits`, `reviews`). `multitext` is Obsidian's internal name
for the List type.

## Legacy notes

`Work Logs/Legacy/` holds pre-convention notes that could not be
retrofitted to the session-based model (no identifiable session id, or
several sessions merged into one file). They are excluded from the main
Base view and surfaced by the **Legacy** view instead. Don't add new
notes there.

## Formatting

Standard Obsidian-flavored Markdown — wikilinks, callouts, properties —
where it helps readability, but don't over-format. This is a working log,
not a polished note.

## Rationale

Keying the worklog to the session id makes the note a faithful, 1:1
record of an actual unit of agent work, reconstructible from the
transcript at any time, with no ambiguity about what "the same day's log"
means when several threads run in parallel.

Making work items *tags* rather than notes or folders means a unit of
work costs nothing to create, can span repos, and is queryable two ways
at once: `#wi/ABC-123` for everything on a ticket, and the full
`#wi/ABC-123/<slug>` for one specific unit. Requiring the ticket key in
the tag is the forcing function that keeps work ticketed; `#untracked` is
the escape hatch that stays visible until it's paid off.
