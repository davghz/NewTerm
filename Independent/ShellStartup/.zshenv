# Restore the user's startup directory before zsh reads .zprofile and .zshrc.
if [[ ${T3RM_HAD_ZDOTDIR-} == 1 ]]; then
    export ZDOTDIR=$T3RM_ORIGINAL_ZDOTDIR
else
    unset ZDOTDIR
fi
unset T3RM_HAD_ZDOTDIR T3RM_ORIGINAL_ZDOTDIR
if [[ -r ${ZDOTDIR-$HOME}/.zshenv && ${ZDOTDIR-$HOME}/.zshenv != ${${(%):-%N}:A} ]]; then
    source "${ZDOTDIR-$HOME}/.zshenv"
fi

# Change only the stock prompts after normal login configuration has run.
if [[ -o interactive ]]; then
    function _t3rm_first_prompt() {
        case "$PROMPT" in
            '%m%::%~ %n%# ' | '%m%# ' | '%n@%m %1~ %# ') PROMPT='%1~ > ' ;;
        esac
        precmd_functions=( "${(@)precmd_functions:#_t3rm_first_prompt}" )
        unfunction _t3rm_first_prompt
    }
    typeset -ga precmd_functions
    precmd_functions+=( _t3rm_first_prompt )
fi
