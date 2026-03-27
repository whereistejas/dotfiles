---
name: plans
description: Create and maintain .plans directory for storing plans, decisions, and conversation context
triggers:
  - user
  - model
---

# Plans Directory Convention

## Rule

Every repository you work in MUST have a `.plans/` directory at its root. This directory stores plans, architectural decisions, conversation summaries, and context that persists across sessions.

## When to Create

- At the **start of any significant task** (multi-step feature, refactor, investigation), create or update a plan file.
- When the user discusses **architecture, design decisions, or trade-offs**, capture the outcome.
- When a **conversation contains important context** that would be useful in future sessions, save it.
- You do NOT need to create a plan for trivial one-off tasks (renaming a variable, fixing a typo).

## Directory Structure

```
.plans/
├── README.md                          # Index of all plans
├── YYYY-MM-DD-short-description.md    # Individual plan files
└── archive/                           # Completed/obsolete plans (optional)
```

## File Naming

Use the format: `YYYY-MM-DD-short-kebab-case-description.md`

Examples:
- `2026-03-16-sdlc-webview-redesign.md`
- `2026-03-16-shell-manager-refactor.md`
- `2026-03-16-jj-migration-plan.md`

## Plan File Template

```markdown
# <Title>

**Date:** YYYY-MM-DD
**Status:** draft | in-progress | completed | abandoned

## Context

Why are we doing this? What problem are we solving?

## Decision / Approach

What did we decide? What approach are we taking?

## Tasks

- [ ] Task 1
- [ ] Task 2
- [ ] Task 3

## Notes

Any additional context, conversation highlights, or references.
```

## README.md Index

Maintain a `README.md` inside `.plans/` that lists all active plans:

```markdown
# Plans

## Active
- [SDLC Webview Redesign](./2026-03-16-sdlc-webview-redesign.md) - Migrating SDLC panel to new React architecture

## Completed
- [Shell Manager Refactor](./2026-03-15-shell-manager-refactor.md) - Unified local/WMP shell interface
```

## Gitignore

The `.plans/` directory SHOULD be committed to the repository so the team has shared context. However, if the user prefers to keep plans private, respect that and add `.plans/` to `.gitignore`.

## Behavior Rules

1. **Always check for `.plans/` at the start of a session** when working in a repository. If it exists, read the README.md to understand ongoing work.
2. **Create `.plans/` if it doesn't exist** when starting a non-trivial task. Ask the user if unsure.
3. **Update plan files** as work progresses — check off completed tasks, add notes about decisions made during implementation.
4. **Capture conversation context** — when a discussion leads to an important decision or reveals useful information, append it to the relevant plan or create a new one.
5. **Keep plans concise** — these are working documents, not essays. Bullet points and short descriptions are preferred.
