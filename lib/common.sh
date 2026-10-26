# shellcheck shell=bash
# Onyx XFCE — helpers shared by install.sh and restore.sh.
# shellcheck disable=SC2034  # the paths below are used by the sourcing scripts

ONYX_VERSION="1.0.0"
ONYX_DATA="${XDG_DATA_HOME:-$HOME/.local/share}/onyx-xfce"
ONYX_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/onyx-xfce"
ONYX_BACKUPS="$ONYX_DATA/backups"
ONYX_ICONS="${XDG_DATA_HOME:-$HOME/.local/share}/icons/Onyx"
GTK_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gtk-3.0"
XFCONF_XML="${XDG_CONFIG_HOME:-$HOME/.config}/xfce4/xfconf/xfce-perchannel-xml"
PANEL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/xfce4/panel"
TERM_SCHEMES="${XDG_DATA_HOME:-$HOME/.local/share}/xfce4/terminal/colorschemes"

# xfconf properties changed outside the panel: channel, property, type, array?
ONYX_XFCONF_PROPS=(
    "xfwm4 /general/workspace_count int 0"
    "xfwm4 /general/workspace_names string 1"
    "keyboard-layout /Default/XkbDisable bool 0"
    "keyboard-layout /Default/XkbLayout string 0"
    "keyboard-layout /Default/XkbVariant string 0"
    "xfce4-power-manager /xfce4-power-manager/show-tray-icon bool 0"
)

if [[ -t 1 ]]; then
    C_B=$'\e[1m' C_D=$'\e[90m' C_R=$'\e[0m'
else
    C_B="" C_D="" C_R=""
fi
say() { printf '%s\n' "$*"; }
step() { printf '\n%s==>%s %s%s%s\n' "$C_B" "$C_R" "$C_B" "$*" "$C_R"; }
info() { printf '    %s\n' "$*"; }
note() { printf '    %s%s%s\n' "$C_D" "$*" "$C_R"; }
warn() { printf '    %s[!]%s %s\n' "$C_B" "$C_R" "$*" >&2; }
die() {
    printf '%s[x]%s %s\n' "$C_B" "$C_R" "$*" >&2
    exit 1
}

confirm() { # question; honours ASSUME_YES
    [[ ${ASSUME_YES:-0} == 1 ]] && return 0
    local answer
    read -r -p "    $1 [s/N] " answer
    [[ $answer == [sSyY]* ]]
}

# Block markers, written as comments of the file's language.
marks() {
    if [[ $1 == *.css ]]; then
        MARK_BEGIN="/* >>> onyx-xfce >>> */" MARK_END="/* <<< onyx-xfce <<< */"
    else
        MARK_BEGIN="# >>> onyx-xfce >>>" MARK_END="# <<< onyx-xfce <<<"
    fi
}

# Remove the ">>> onyx-xfce >>>" ... "<<< onyx-xfce <<<" block of a file.
strip_block() {
    local file=$1 tmp
    [[ -f $file ]] || return 0
    marks "$file"
    grep -qF "$MARK_BEGIN" "$file" || return 0
    tmp=$(mktemp)
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip' "$file" >"$tmp"
    cat "$tmp" >"$file" # keep the original inode, owner and mode
    rm -f "$tmp"
}

# Add a marked block (replacing an older one) at the end of a file, or at
# the top with "top" (CSS ignores an @import that follows other rules).
put_block() {
    local file=$1 body=$2 where=${3:-bottom} tmp
    strip_block "$file"
    marks "$file"
    if [[ $where == top ]]; then
        tmp=$(mktemp)
        { printf '%s\n%s\n%s\n' "$MARK_BEGIN" "$body" "$MARK_END"; cat "$file"; } >"$tmp"
        cat "$tmp" >"$file"
        rm -f "$tmp"
    else
        printf '%s\n%s\n%s\n' "$MARK_BEGIN" "$body" "$MARK_END" >>"$file"
    fi
}

panel_running() { pgrep -x -u "$(id -u)" xfce4-panel >/dev/null; }

panel_stop() {
    panel_running || return 0
    xfce4-panel --quit >/dev/null 2>&1 || true
    for _ in {1..50}; do
        panel_running || break
        sleep 0.1
    done
    panel_running && pkill -x -u "$(id -u)" xfce4-panel
    # External plugins live in wrapper processes that exit a moment later.
    for _ in {1..30}; do
        pgrep -u "$(id -u)" -f "xfce4/panel/wrapper-2.0" >/dev/null || return 0
        sleep 0.1
    done
}

panel_start() {
    if panel_running; then
        xfce4-panel -r >/dev/null 2>&1 || true
    else
        setsid -f xfce4-panel >/dev/null 2>&1 </dev/null
    fi
}

# Stop the music listener and its playerctl child (the listener keeps the
# old plugin id in its arguments).
stop_watchers() {
    pkill -u "$(id -u)" -f "onyx-xfce/bin/onyx-music [0-9]+ watch" 2>/dev/null || true
    pkill -u "$(id -u)" -f "playerctl.* --follow metadata --format \{\{status\}\}" 2>/dev/null || true
}

# Read an xfconf property as "type<TAB>v1<TAB>v2..." or "unset".
xfconf_dump() { # channel property type is_array
    local out
    if ! out=$(LC_ALL=C xfconf-query -c "$1" -p "$2" 2>/dev/null); then
        printf 'unset'
        return
    fi
    if [[ $4 == 1 ]]; then
        # "Value is an array with N items:" + blank line + one value per line
        printf '%s' "$3"
        tail -n +3 <<<"$out" | while IFS= read -r v; do printf '\t%s' "$v"; done
    else
        printf '%s\t%s' "$3" "$out"
    fi
}

# Set an xfconf property from "type<TAB>v1..." (as written by xfconf_dump).
xfconf_load() { # channel property is_array dump
    local ch=$1 prop=$2 arr=$3 type args=() v
    if [[ $4 == unset ]]; then
        xfconf-query -c "$ch" -p "$prop" -r 2>/dev/null || true
        return
    fi
    IFS=$'\t' read -r -a vals <<<"$4"
    type=${vals[0]}
    for v in "${vals[@]:1}"; do args+=(-t "$type" -s "$v"); done
    if [[ $arr == 1 ]]; then
        LC_ALL=C xfconf-query -c "$ch" -p "$prop" -n -a "${args[@]}"
    else
        LC_ALL=C xfconf-query -c "$ch" -p "$prop" -n -t "$type" -s "${vals[1]}"
    fi
}

# xfwm4 only applies a workspace count when the value changes, so step
# through the current real count first.
set_workspace_count() {
    local want=$1 now
    now=$(xprop -root _NET_NUMBER_OF_DESKTOPS 2>/dev/null | awk '{print $NF}')
    [[ $now =~ ^[0-9]+$ ]] || now=$want
    xfconf-query -c xfwm4 -p /general/workspace_count -n -t int -s "$now"
    [[ $now != "$want" ]] && sleep 0.3
    xfconf-query -c xfwm4 -p /general/workspace_count -n -t int -s "$want"
}
