# Ghostty shell integration for Bash. This must be at the top of your bashrc!
if [ -n "${GHOSTTY_RESOURCES_DIR}" ]; then
    builtin source "${GHOSTTY_RESOURCES_DIR}/shell-integration/bash/ghostty.bash"
fi

export PATH="/opt/homebrew/bin:$PATH"
export PATH="/opt/homebrew/opt/node@16/bin:$PATH"
export PATH="/opt/homebrew/opt/ruby@3.2/bin:$PATH"
export PATH="~/.local/bin:$PATH"
export PATH="~/.scripts:$PATH"
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

export EDITOR="nvim"
export LS_OPTIONS="--color=auto"
export GPG_TTY=$(tty)
export PS1='\W \$ '
export NVM_DIR="$HOME/.nvm"

source <(jj util completion bash)
[[ -r "/opt/homebrew/etc/profile.d/bash_completion.sh" ]] && . "/opt/homebrew/etc/profile.d/bash_completion.sh"
[[ -r "/opt/vagrant/embedded/gems/gems/vagrant-2.4.9/contrib/bash/completion.sh" ]] && . "/opt/vagrant/embedded/gems/gems/vagrant-2.4.9/contrib/bash/completion.sh"
[[ -r "/opt/homebrew/Cellar/autojump/22.5.3_3/share/autojump/autojump.bash" ]] && . "/opt/homebrew/Cellar/autojump/22.5.3_3/share/autojump/autojump.bash"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
. "$HOME/.cargo/env"

alias rg="rg --hidden"
alias cat="bat --theme-light=Coldark-Cold "

alias c="clear"
alias z="j "

alias rm="rm -rf "
alias cp="cp -r "
alias mkdir="mkdir -p "

alias pgrep="pgrep -fil "

alias jjl="jj l "
alias jjs="jj status "
alias diff="jj diff"

alias vim="nvim "

alias ls="eza "
alias lsa="eza -al"

alias ..="cd .."
alias ...="cd ../.."
alias ....="cd ../../.."
alias .....="cd ../../../.."
alias ......="cd ../../../../.."

cfg-bashrc() { $EDITOR ~/.bashrc ;}
rld-bashrc() { source ~/.bashrc ;}
cfg-vimrc() { $EDITOR ~/.config/nvim/init.lua ;}
cfg-git() { $EDITOR ~/.gitconfig ;}
cfg-jj() { $EDITOR ~/.config/jj/config.toml ;}

ulimit -n unlimited

set -o vi

fortune | cowsay

