---
name: jj-interdiff
description: Compare the *patches* of two jj revisions with `jj interdiff` — "how does what commit A does differ from what commit B does". Use when reviewing what changed in a commit since the last push, comparing two alternative implementations of the same change, checking a rebase/squash introduced no content drift, or verifying an amend across revisions with different parents. NOT for comparing file contents between two revisions (that's `jj diff --from/--to`) or for the full evolution of one change (`jj evolog -p`).
---

# jj interdiff

`jj interdiff` diffs two *diffs*. It rebases `--from` onto `--to`'s parents,
then diffs the result against `--to`. So it answers **"how do the
modifications introduced by A differ from those introduced by B?"** and
deliberately ignores everything the two revisions' parents differ by.

Verified against jj 0.44.0.

## Signature

```
jj interdiff [OPTIONS] <--from <REVSET>|--to <REVSET>> [FILESETS]...
```

- `-f, --from <REVSET>` — first revision (default `@`)
- `-t, --to <REVSET>` — second revision (default `@`)
- At least one of `--from`/`--to` **must** be given; there is no `-r`.
- Trailing positional args are filesets that restrict the diff to paths.

Diff formatting flags are the same family as `jj diff`:
`-s/--summary`, `--stat`, `--types`, `--name-only`, `--git`, `--color-words`,
`--tool <TOOL>` (or `--tool=:git`), `--context <N>`, `-w`, `-b`.

## interdiff vs diff vs evolog

| Want | Command |
| --- | --- |
| Difference between two commits' *patches* | `jj interdiff --from A --to B` |
| Difference between two commits' *file contents* | `jj diff --from A --to B` |
| The patch of a single commit | `jj diff -r A` |
| Everything one change did over its whole evolution | `jj evolog -p -r A` |

The distinction only matters when A and B have different parents:
`jj diff --from A --to B` folds in the changes between their parents,
`jj interdiff` does not.

## Recipes

Review what a change did since it was last pushed (the canonical use):

```sh
jj interdiff --from push-xyz@origin --to push-xyz
jj interdiff --from mybookmark@origin --to mybookmark --stat
```

Compare against the previous version of the *same* change after an amend or
rebase (use `evolog` to get the older commit id first):

```sh
jj evolog -r @ -T 'commit_id.short() ++ " " ++ description.first_line() ++ "\n"' --no-graph
jj interdiff --from <older-commit-id> --to @
```

Prove a rebase/squash changed nothing semantically — empty output means the
patch is identical:

```sh
jj interdiff --from <pre-rebase-commit-id> --to <post-rebase-change-id> --stat
```

Compare two alternative implementations of the same feature:

```sh
jj interdiff --from feature-v1 --to feature-v2 --git
```

Narrow to paths, and use `--from`'s default of `@`:

```sh
jj interdiff --to other-change src/ Cargo.toml
```

## Gotchas

- Empty output = the two revisions introduce the same patch. That's the
  success signal when validating a rebase, not a broken command.
- `--from`/`--to` take **revsets**, so `@-`, bookmarks, `push-*@origin`, and
  operators all work; a revset resolving to more than one commit is an error.
- Comparing a change with its own pre-rewrite version needs a **commit id**
  from `jj evolog`, because the change id now points at the new version.
- Non-conflicting merge-ish weirdness: interdiff rebases `--from` onto
  `--to`'s parents, so a `--from` that conflicts when rebased will show
  conflict markers in the output rather than failing.
- Pair with `--ignore-working-copy` when you just want to read state without
  snapshotting.
