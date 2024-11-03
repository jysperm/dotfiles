export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

eval "$(starship init zsh)"
eval "$(direnv hook zsh)"
FPATH="$(brew --prefix)/share/zsh/site-functions:${FPATH}"
autoload -Uz compinit; compinit
source $(brew --prefix)/share/zsh-autosuggestions/zsh-autosuggestions.zsh
source $(brew --prefix)/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

alias ll='ls -lah'

zstyle -e ':completion:*:default' list-colors 'reply=("${PREFIX:+=(#bi)($PREFIX:t)(?)*==02=01}:${(s.:.)LS_COLORS}")'

setopt HIST_IGNORE_SPACE

export CLICOLOR=1
