. "$HOME/.bash/functions"
. "$HOME/.bash/paths"
. "$HOME/.bash/sourced"
. "$HOME/.bash/exports"
. "$HOME/.bash/aliases"

ulimit -n unlimited

set -o vi

fortune | cowsay
[ -f "/Users/whereistejas/.ghcup/env" ] && source "/Users/whereistejas/.ghcup/env" # ghcup-env
. "$HOME/.cargo/env"

