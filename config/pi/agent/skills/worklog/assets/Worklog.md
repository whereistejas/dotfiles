---
aliases:
  - "{{date}} <repo> — <short title>"
session_id:
date: {{date}}
started:
summary:
tickets:
repos:
branches:
changes:
commits:
reviews:
---

<!--
Skeleton only. Obsidian's core Templates plugin substitutes {{title}},
{{date}} and {{time}} and nothing else — session_id, tickets, repos,
branches, changes, commits and reviews are filled in afterwards with
`obsidian property:set`. See the `worklog` skill.

One worklog note per pi session. File name is the full session UUID:
Work Logs/<session-id>.md — flat, no subfolders.
-->

## <TICKET-KEY> — <what this unit of work was> #wi/<TICKET-KEY>/<kebab-slug>

<!-- A section WITHOUT a Jira ticket is tagged #untracked instead:
     ## <what this was> #untracked -->

| repo | MR / review | bookmark | before → after | notes |
| --- | --- | --- | --- | --- |
| `<repo>` | [!NN](<url>) | `<branch>` | `<sha>` → `<sha>` |  |

### What happened

-

### Decisions

-

### Still open

-
