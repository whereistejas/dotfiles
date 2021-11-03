source "$HOME/.bash/sourced"
source "$HOME/.bash/exports"
source "$HOME/.bash/functions"
source "$HOME/.bash/paths"
source "$HOME/.bash/aliases"

eval "$(fasd --init auto)"

fortune | cowsay
