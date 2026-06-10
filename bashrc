# Portable bashrc, shared between macOS and the Linux dev container.
# macOS-only setup lives in bashrc.macos, sourced first below.

# Dotfiles repo: real checkout on the host, read-only mount in the container.
export DOTFILES="$HOME/build/dotfiles"
[ -d /opt/dotfiles ] && DOTFILES=/opt/dotfiles

# Ghostty integration must run first; Homebrew gets lowest PATH priority.
[[ "$OSTYPE" == darwin* ]] && [ -f "$DOTFILES/bashrc.macos" ] && source "$DOTFILES/bashrc.macos"

# Dev container: Nix toolchain profile (sshd login shells don't inherit ENV).
if [ -d /nix/var/nix/profiles/devtools ]; then
    export PATH="/nix/var/nix/profiles/devtools/bin:$PATH"
    export PKG_CONFIG_PATH="/nix/var/nix/profiles/devtools/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    # ghostty.terminfo from the profile; trailing ':' keeps ncurses' defaults.
    export TERMINFO_DIRS="/nix/var/nix/profiles/devtools/share/terminfo:${TERMINFO_DIRS:-}"
fi
# Machine-local env (untracked): corp cert, etc.
[ -f "$DOTFILES/config/dev-container/env.sh" ] && source "$DOTFILES/config/dev-container/env.sh"

# Environment variables (non-PATH)
export EDITOR="nvim"
export LS_OPTIONS="--color=auto"
export GPG_TTY=$(tty)
export PS1='\W \$ '
export BUN_INSTALL="$HOME/.bun"

# PATH — user tools
export PATH="$BUN_INSTALL/bin:$PATH"
export PATH="$HOME/.local/bin:$PATH"
[ -d "$HOME/.cargo/bin" ] && export PATH="$HOME/.cargo/bin:$PATH"

# Completions
command -v jj >/dev/null && source <(jj util completion bash)

# Aliases
alias ..="cd .."
alias ...="cd ../.."
alias ....="cd ../../.."
alias .....="cd ../../../.."
alias ......="cd ../../../../.."

alias c="clear"

alias cp="cp -r "
alias mkdir="mkdir -p "
alias rg="rg --hidden --smart-case "
alias cat="bat --theme-light=Coldark-Cold "
alias ls="eza "
alias lsa="eza -al"

alias pgrep="pgrep -fil "

alias diff="jj diff"
alias vim="nvim "

alias pi='bun run $(which pi)'

# Functions
_jj_each() {
    local cmd="$1"; shift
    local repos
    repos=$(find . -mindepth 2 -maxdepth 2 -name .jj -type d | grep -E "${1:-.}" | sort | sed 's|/.jj$||')
    if [ -z "$repos" ]; then
        jj $cmd
        return
    fi
    for dir in $repos; do
        echo "=== ${dir#./} ==="
        jj $cmd -R "$dir" 2>/dev/null
        echo
    done
}

jjs() { _jj_each st "$1"; }
jjl() { _jj_each log "$1"; }
jjgf() { _jj_each gf "$1"; }

jjgp() {
    local bookmark
    bookmark=$(jj log -r 'latest(::@ & bookmarks())' --no-graph -T 'local_bookmarks.join(",")' --limit 1)
    if [ -n "$bookmark" ]; then
        jj git push -b "$bookmark" "$@"
    else
        echo "No bookmark found in ancestry of @"
    fi
}

inn() { pushd "$1" > /dev/null && shift && "$@"; popd > /dev/null; }

# Clipboard over SSH (dev container): OSC 52 — the terminal on the host side
# does the copy, so `cmd | pbcopy` works through ssh with no extra plumbing.
if ! command -v pbcopy >/dev/null; then
    pbcopy() { printf '\e]52;c;%s\a' "$(base64 -w0)" > /dev/tty; }
fi

cfg-bashrc() { $EDITOR "$DOTFILES/bashrc" ;}
cfg-vimrc() { $EDITOR "$DOTFILES/config/nvim/init.lua" ;}
cfg-git() { $EDITOR "$DOTFILES/gitconfig" ;}
cfg-jj() { $EDITOR "$DOTFILES/config/jj/config.toml" ;}
rld-bashrc() { source "$DOTFILES/bashrc" ;}

# Interactive settings
set -o vi
command -v fortune >/dev/null && command -v cowsay >/dev/null && fortune | cowsay
