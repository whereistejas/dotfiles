# Ghostty shell integration for Bash. This must be at the top of your bashrc!
if [ -n "${GHOSTTY_RESOURCES_DIR}" ]; then
    builtin source "${GHOSTTY_RESOURCES_DIR}/shell-integration/bash/ghostty.bash"
fi

export PATH="/opt/homebrew/bin:$PATH"
export PATH="/opt/homebrew/opt/node@16/bin:$PATH"
export PATH="/opt/homebrew/opt/ruby@3.2/bin:$PATH"
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"
export PATH="~/.local/bin:$PATH"

export EDITOR="nvim"
export LS_OPTIONS="--color=auto"
export GPG_TTY=$(tty)
export PS1='\W \$ '
export NVM_DIR="$HOME/.nvm"
export NODE_EXTRA_CA_CERTS="/tmp/corp-cert.pem"

[[ -r "/opt/vagrant/embedded/gems/gems/vagrant-2.4.9/contrib/bash/completion.sh" ]] && . "/opt/vagrant/embedded/gems/gems/vagrant-2.4.9/contrib/bash/completion.sh"
[ -f /opt/homebrew/share/bash-completion/bash_completion ] && . /opt/homebrew/share/bash-completion/bash_completion
[[ -r "/opt/homebrew/Cellar/autojump/22.5.3_3/share/autojump/autojump.bash" ]] && . "/opt/homebrew/Cellar/autojump/22.5.3_3/share/autojump/autojump.bash"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion

source <(jj util completion bash)
. "$HOME/.cargo/env"

alias rg="rg --hidden"
alias cat="bat --theme-light=Coldark-Cold "

alias c="clear"
alias z="j "

alias rm="rm -rf "
alias cp="cp -r "
alias mkdir="mkdir -p "

alias pgrep="pgrep -fil "

alias diff="jj diff"

alias vim="nvim "

alias ls="eza "
alias lsa="eza -al"

alias ..="cd .."
alias ...="cd ../.."
alias ....="cd ../../.."
alias .....="cd ../../../.."
alias ......="cd ../../../../.."

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

cfg-bashrc() { $EDITOR ~/build/dotfiles/.bashrc ;}
cfg-vimrc() { $EDITOR ~/build/dotfiles/.config/nvim/init.lua ;}
cfg-git() { $EDITOR ~/build/dotfiles/.gitconfig ;}
cfg-jj() { $EDITOR ~/build/dotfiles/.config/jj/config.toml ;}
rld-bashrc() { source ~/build/dotfiles/.bashrc ;}

ulimit -n unlimited

set -o vi

fortune | cowsay

