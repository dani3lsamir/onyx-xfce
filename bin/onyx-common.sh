# shellcheck shell=bash
# Onyx XFCE — helpers shared by the genmon module scripts.
# Sourced, never executed. Keep it small: it is read on every module refresh.
# shellcheck disable=SC2034  # variables used by the module scripts

ONYX_BIN="${BASH_SOURCE[0]%/*}"
ONYX_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/onyx-xfce/onyx.conf"
# Runtime state lives in tmpfs (/run/user/UID) so refreshes never touch the HDD.
ONYX_RUN="${XDG_RUNTIME_DIR:-/dev/shm}/onyx-xfce"

ONYX_DIM='#8c8c8c'
ONYX_ACTIVE='#f0f0f0'
ONYX_MODULE='#101010'

# shellcheck source=/dev/null
[[ -r $ONYX_CONF ]] && . "$ONYX_CONF"
[[ -d $ONYX_RUN ]] || (umask 077 && mkdir -p "$ONYX_RUN")

# Escape text for Pango markup (song titles, SSIDs, ...).
# Replacements are quoted: bash 5.2 expands a bare '&' to the match.
onyx_esc() {
    local s=${1//&/'&amp;'}
    s=${s//</'&lt;'}
    printf '%s' "${s//>/'&gt;'}"
}

# Hidden module: a zero-size progress bar is the only genmon element that
# renders nothing (the CSS collapses it), so the module leaves no gap.
onyx_hide() {
    printf '<bar>0</bar>'
}

# Ask the panel to re-run one genmon plugin right now (id = plugin number).
# Plain D-Bus on purpose: `xfce4-panel --plugin-event` would start a second
# panel when none is running.
onyx_refresh() {
    [[ -n $1 ]] && dbus-send --session --type=method_call --dest=org.xfce.Panel \
        /org/xfce/Panel org.xfce.Panel.PluginEvent \
        string:"genmon-$1" string:refresh variant:boolean:true >/dev/null 2>&1
}

# Start a command fully detached. genmon passes its own pipe descriptors to
# the command (not only stdout/stderr), so every inherited fd is closed;
# otherwise the panel plugin keeps waiting for them until the command exits.
onyx_detach() {
    (
        for fd in /proc/self/fd/*; do
            fd=${fd##*/}
            ((fd > 2 && fd != 255)) && eval "exec $fd>&-"
        done 2>/dev/null
        exec setsid "$@" </dev/null >/dev/null 2>&1
    ) &
}

# Current time in seconds without forking date(1).
onyx_now() {
    printf '%(%s)T' -1
}
