# Dotfiles

Configuration files for macOS, managed with [Jujutsu](https://martinvonz.github.io/jj/).

## Software

### Terminal & Shell

- [Ghostty](https://ghostty.org/) — terminal emulator
- Bash — shell (vi mode, readline customizations in `.inputrc`)
- [Berkeley Mono](https://berkeleygraphics.com/typefaces/berkeley-mono/) — terminal font

### Window Management

- [AeroSpace](https://nikitabobko.github.io/AeroSpace/) — tiling window manager
- [Karabiner-Elements](https://karabiner-elements.pqrs.org/) — keyboard customization

### Version Control

- [Jujutsu (jj)](https://martinvonz.github.io/jj/) — primary VCS
- Git — secondary VCS, SSH commit signing via `gpg.format = ssh`
- [Difftastic](https://difftastic.wilfred.me/) — structural diff tool
- Git LFS

### Editor

- [Neovim](https://neovim.io/) — primary editor (single `init.lua`, uses built-in `vim.pack`)
- [GitHub Copilot](https://github.com/features/copilot) — AI completion

### CLI Tools

- [Homebrew](https://brew.sh/) — package manager
- [ripgrep](https://github.com/BurntSushi/ripgrep) — fast search
- [bat](https://github.com/sharkdp/bat) — cat replacement
- [eza](https://eza.rocks/) — ls replacement
- [autojump](https://github.com/wting/autojump) — directory navigation
- [vifm](https://vifm.info/) — terminal file manager
- [fortune](https://formulae.brew.sh/formula/fortune) + [cowsay](https://formulae.brew.sh/formula/cowsay)

### Languages & Runtimes

- [Rust](https://www.rust-lang.org/) (via cargo)
- [Node.js](https://nodejs.org/) (via [nvm](https://github.com/nvm-sh/nvm))
- [Bun](https://bun.sh/)
- [Ruby 3.2](https://www.ruby-lang.org/) (via Homebrew)

### Apps

- [Raycast](https://www.raycast.com/) — launcher
- [Claude Code](https://claude.ai/code) — AI assistant

## Neovim Dependencies

The Neovim config expects these external tools to be installed:

### LSP Servers

| Language | Server | Install |
|---|---|---|
| Lua | `lua-language-server` | `brew install lua-language-server` |
| TypeScript/JavaScript | `typescript-language-server` | `npm install -g typescript-language-server typescript` |
| ESLint | `vscode-eslint-language-server` | `npm install -g vscode-langservers-extracted` |
| Python (lint/format) | `ruff` | `brew install ruff` |
| Python (types) | `ty` | `pip install ty` |
| Ruby | `ruby-lsp` | `gem install ruby-lsp` |
| OCaml | `ocamllsp` | `opam install ocaml-lsp-server` |
| Bash | `bash-language-server` | `bun install -g bash-language-server` |
| Markdown | `marksman` | `brew install marksman` |
| Rust | `rust-analyzer` | `rustup component add rust-analyzer` |

### Build Tools

- `make` — required for building `telescope-fzf-native.nvim`
- `ripgrep` — used by Telescope for live grep

### Neovim Plugins

Managed via `vim.pack` (Neovim's built-in package manager):

- telescope.nvim (+ fzf-native, file-browser, live-grep-args)
- nvim-treesitter
- nvim-lspconfig, lazydev.nvim
- blink.cmp, friendly-snippets
- gitsigns.nvim, jj.nvim, hunk.nvim
- copilot.vim
- vim-surround, vim-fetch, goyo.vim
- github-nvim-theme, gruvbox.nvim
