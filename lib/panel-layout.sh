# shellcheck shell=bash
# Onyx XFCE — writes the panel layout into xfconf (channel xfce4-panel).
# Sourced by install.sh. The panel must NOT be running while this executes.
#
# One visual bar made of three panels that tile the top edge seamlessly, so
# the clock sits in the exact middle of the screen no matter how wide the
# left or right groups become:
#
#   panel-1  top-left   43%  workspaces · Brave Origin · tray · music
#   panel-2  top-center 15%  clock (between two expanding separators)
#   panel-3  top-right  43%  cpu ram temp weather bt wifi vol bright kbd power
#
# The segments overlap by a few pixels (43+15+43 > 100); the overlap only
# contains bar background, so the seams are invisible.

ONYX_BAR_HEIGHT=27

_xq() { # property type value
    xfconf-query -c xfce4-panel -p "$1" -n -t "$2" -s "$3"
}
_xq_strings() { # property value...
    local prop=$1 args=()
    shift
    for v in "$@"; do args+=(-t string -s "$v"); done
    xfconf-query -c xfce4-panel -p "$prop" -n -a "${args[@]}"
}
_xq_ints() {
    local prop=$1 args=()
    shift
    for v in "$@"; do args+=(-t int -s "$v"); done
    xfconf-query -c xfce4-panel -p "$prop" -n -a "${args[@]}"
}

_panel() { # n position length plugin-ids...
    local pos=$2 len=$3 p=/panels/panel-$1
    shift 3
    _xq "$p/position" string "$pos"
    _xq "$p/position-locked" bool true
    _xq "$p/mode" uint 0
    _xq "$p/size" uint "$ONYX_BAR_HEIGHT"
    _xq "$p/icon-size" uint 16
    _xq "$p/nrows" uint 1
    _xq "$p/length" double "$len"
    _xq "$p/length-adjust" bool true
    _xq "$p/enter-opacity" uint 100
    _xq "$p/leave-opacity" uint 100
    _xq "$p/autohide-behavior" uint 0
    _xq "$p/disable-struts" bool false
    _xq "$p/dark-mode" bool true
    _xq "$p/background-style" uint 1
    xfconf-query -c xfce4-panel -p "$p/background-rgba" -n -a \
        -t double -s 0.145098 -t double -s 0.145098 -t double -s 0.145098 -t double -s 1.0
    _xq_ints "$p/plugin-ids" "$@"
}

_genmon() { # id script period-ms
    local id=$1
    _xq "/plugins/plugin-$id" string genmon
    cat >"$ONYX_PANEL_DIR/genmon-$id.rc" <<EOF
Command=$ONYX_BIN_DIR/$2 $id
UseLabel=0
Text=
UpdatePeriod=$3
Font=DejaVu Sans Mono 9
EOF
}

_separator() { # id
    _xq "/plugins/plugin-$1" string separator
    _xq "/plugins/plugin-$1/style" uint 0
    _xq "/plugins/plugin-$1/expand" bool true
}

# Copy a .desktop file; if its icon is not installed anywhere, use the
# generic "web-browser" icon instead of a "missing image" placeholder.
_launcher_copy() {
    local src=$1 dst=$2 icon
    cp "$src" "$dst"
    icon=$(sed -n 's/^Icon=//p' "$src" | head -1)
    [[ -z $icon || $icon == /* && -f $icon ]] && return 0
    local d
    for d in "$HOME/.local/share/icons" /usr/share/icons /usr/share/pixmaps \
        /var/lib/flatpak/exports/share/icons "$HOME/.local/share/flatpak/exports/share/icons"; do
        [[ -d $d ]] && [[ -n $(find "$d" -name "$icon.*" -print -quit 2>/dev/null) ]] && return 0
    done
    sed -i 's/^Icon=.*/Icon=web-browser/' "$dst"
}

# onyx_write_panel <bin-dir> <browser-desktop-file-or-empty>
onyx_write_panel() {
    ONYX_BIN_DIR=$1
    local browser=$2
    ONYX_PANEL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/xfce4/panel"
    export LC_ALL=C # xfconf-query parses doubles with the C locale

    xfconf-query -c xfce4-panel -p / -R -r 2>/dev/null
    mkdir -p "$ONYX_PANEL_DIR"
    rm -rf "$ONYX_PANEL_DIR"/launcher-* "$ONYX_PANEL_DIR"/genmon-*.rc

    _xq /configver int 2
    _xq_ints /panels 1 2 3
    _xq /panels/dark-mode bool true

    local left=(1 3 4)
    [[ -n $browser ]] && left=(1 2 3 4)
    _panel 1 "p=6;x=0;y=0" 43 "${left[@]}"
    _panel 2 "p=9;x=683;y=0" 15 5 6 7
    _panel 3 "p=2;x=1366;y=0" 43 8 9 10 11 12 13 14 15 16 17 18

    # 1 — workspaces: three named buttons, never miniatures
    _xq /plugins/plugin-1 string pager
    _xq /plugins/plugin-1/rows uint 1
    _xq /plugins/plugin-1/miniature-view bool false
    _xq /plugins/plugin-1/numbering bool false
    _xq /plugins/plugin-1/wrap-workspaces bool false

    # 2 — the only pinned launcher: Brave Origin
    if [[ -n $browser ]]; then
        _xq /plugins/plugin-2 string launcher
        mkdir -p "$ONYX_PANEL_DIR/launcher-2"
        _launcher_copy "$browser" "$ONYX_PANEL_DIR/launcher-2/onyx-browser.desktop"
        _xq_strings /plugins/plugin-2/items onyx-browser.desktop
        _xq /plugins/plugin-2/show-label bool false
        _xq /plugins/plugin-2/move-first bool false
    fi

    # 3 — tray for background apps (Dropbox, Nextcloud...). Wi-Fi, Bluetooth
    # and power have their own modules on the right, so their icons are hidden.
    _xq /plugins/plugin-3 string systray
    _xq /plugins/plugin-3/icon-size uint 16
    _xq /plugins/plugin-3/square-icons bool true
    _xq /plugins/plugin-3/single-row bool true
    _xq /plugins/plugin-3/symbolic-icons bool true
    _xq /plugins/plugin-3/menu-is-primary bool false
    _xq_strings /plugins/plugin-3/hidden-items nm-applet blueman blueman-tray xfce4-power-manager
    _xq_strings /plugins/plugin-3/hidden-legacy-items nm-applet blueman-applet blueman-tray \
        xfce4-power-manager "network" "bluetooth"

    # 4 — music, hidden while no MPRIS player is active (event driven)
    _genmon 4 onyx-music 30000

    # 5..7 — clock centred in panel-2
    _separator 5
    _genmon 6 onyx-clock 10000
    _separator 7

    # 8..18 — right group, pushed to the right edge by separator 8
    _separator 8
    _genmon 9 onyx-cpu 12000
    _genmon 10 onyx-ram 12000
    _genmon 11 onyx-temp 12000
    _genmon 12 onyx-weather 600000
    _genmon 13 onyx-bluetooth 15000
    _genmon 14 onyx-network 15000

    _xq /plugins/plugin-15 string pulseaudio
    _xq /plugins/plugin-15/enable-keyboard-shortcuts bool true
    _xq /plugins/plugin-15/enable-mpris bool false
    _xq /plugins/plugin-15/volume-step uint 5
    command -v pavucontrol >/dev/null && _xq /plugins/plugin-15/mixer-command string pavucontrol

    _genmon 16 onyx-brightness 15000

    _xq /plugins/plugin-17 string xkb
    _xq /plugins/plugin-17/display-type uint 2   # system font text: "US" / "ES"
    _xq /plugins/plugin-17/display-name uint 0   # country code
    _xq /plugins/plugin-17/group-policy uint 0   # one layout for all windows
    _xq /plugins/plugin-17/caps-lock-indicator bool false
    _xq /plugins/plugin-17/display-tooltip-icon bool false

    _xq /plugins/plugin-18 string actions
    _xq /plugins/plugin-18/appearance uint 1     # menu
    _xq /plugins/plugin-18/button-title uint 3   # custom (empty; icon via CSS)
    _xq /plugins/plugin-18/custom-title string ""
    _xq /plugins/plugin-18/ask-confirmation bool true
    _xq_strings /plugins/plugin-18/items +shutdown +restart +separator +logout-dialog \
        -lock-screen -switch-user -suspend -hibernate -hybrid-sleep -logout
}
