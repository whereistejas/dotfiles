# Dotfiles

## Commit author

Commits that land on `main` must have `Tejas Sanap <email@whereistejas.xyz>` as both
author and committer, and must not mention the employer anywhere.

The local `local: work identity and Beacon notes (do not push)` commit switches the jj
`user.email` to the work address, so any commit created *or rewritten* while the working
copy sits on top of it gets the wrong author or committer. Run jj commands that create or
rewrite commits with `JJ_USER="Tejas Sanap" JJ_EMAIL=email@whereistejas.xyz`. Before
pushing, check with:

```bash
jj log -r 'main..@' -T 'author.email() ++ " " ++ committer.email() ++ " " ++ description.first_line() ++ "\n"' --no-graph
```

Fix a wrong author or committer on everything above the local commit with:

```bash
JJ_USER="Tejas Sanap" JJ_EMAIL=email@whereistejas.xyz jj metaedit --update-author --force-rewrite -r '<local-commit>..@'
```
