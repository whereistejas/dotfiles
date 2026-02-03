ulimit -n unlimited

set -o vi

source "$HOME/.bash/paths"
source "$HOME/.bash/functions"
source "$HOME/.bash/sourced"
source "$HOME/.bash/exports"
source "$HOME/.bash/aliases"

fortune | cowsay
