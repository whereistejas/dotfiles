# Dotfiles

## Commit author

Commits that land on `main` must be authored as `Tejas Sanap <email@whereistejas.xyz>`.

The local `local: work identity and Beacon notes (do not push)` commit switches the jj
`user.email` to the work address, so any commit created while the working copy sits on
top of it gets the wrong author. Before pushing, check with:

```bash
jj log -r 'main..@' -T 'author.email() ++ " " ++ description.first_line() ++ "\n"' --no-graph
```

Fix a wrong author with:

```bash
jj metaedit -r <rev> --author "Tejas Sanap <email@whereistejas.xyz>"
```
