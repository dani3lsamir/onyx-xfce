# shellcheck shell=bash
# Onyx XFCE — Bash prompt in black, white and grey.
#
#   daniel ~/proyectos/onyx  main  [1] $
#
# user (white) · directory (light grey) · git branch (grey) · last exit code
# when it is not 0 · "$" ("#" as root). Plain ASCII only: no Nerd Font glyphs.
# The git branch is read from .git/HEAD by Bash itself, so the prompt starts
# no extra processes, even inside repositories on a slow HDD.
# Set ONYX_PROMPT_GIT_DIRTY=1 to also show "*" for uncommitted changes
# (that one runs `git`).

[[ $- == *i* ]] || return 0

# Sets __onyx_branch (no command substitution: that would fork a subshell).
__onyx_git_branch() {
    local dir=$PWD head=""
    __onyx_branch=""
    while [[ -n $dir ]]; do
        if [[ -f $dir/.git/HEAD ]]; then
            read -r head <"$dir/.git/HEAD"
            break
        elif [[ -f $dir/.git ]]; then # worktree / submodule: "gitdir: path"
            local gitdir
            read -r _ gitdir <"$dir/.git"
            [[ $gitdir == /* ]] || gitdir=$dir/$gitdir
            [[ -f $gitdir/HEAD ]] && read -r head <"$gitdir/HEAD"
            break
        fi
        dir=${dir%/*}
    done
    [[ -n $head ]] || return 0
    if [[ $head == ref:* ]]; then
        __onyx_branch=${head#ref: refs/heads/}
    else
        __onyx_branch=${head:0:7} # detached HEAD
    fi
}

__onyx_prompt() {
    local status=$? w=$'\[\e[38;5;255m\]' l=$'\[\e[38;5;250m\]' g=$'\[\e[38;5;244m\]'
    local b=$'\[\e[1m\]' r=$'\[\e[0m\]' ps=""
    [[ -n $SSH_CONNECTION ]] && ps+="$b$w\\u$r$g@\\h$r " || ps+="$b$w\\u$r "
    __onyx_venv=${VIRTUAL_ENV##*/}
    [[ -n $VIRTUAL_ENV ]] && ps+="$g(\${__onyx_venv})$r "
    ps+="$l\\w$r"
    __onyx_git_branch
    if [[ -n $__onyx_branch ]]; then
        # referenced, not pasted: a branch named '$(cmd)' must never run
        ps+="  $g\${__onyx_branch}"
        if [[ ${ONYX_PROMPT_GIT_DIRTY:-0} == 1 ]] && ! git diff --quiet HEAD -- 2>/dev/null; then
            ps+="*"
        fi
        ps+="$r"
    fi
    ((status)) && ps+="  $b${w}[${status}]$r"
    ((EUID)) && ps+=" $w\$$r " || ps+=" $b$w#$r "
    PS1=$ps
}

PROMPT_DIRTRIM=3
if [[ $PROMPT_COMMAND != *__onyx_prompt* ]]; then
    PROMPT_COMMAND="__onyx_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
fi
