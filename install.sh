#!/usr/bin/env bash
# Onyx XFCE — installer.
#
#   ./install.sh            check, show the plan, ask, back up, install
#   ./install.sh --dry-run  only check and show what would change
#   ./install.sh --yes      do not ask for confirmation
#   ./install.sh --no-deps  never call apt (fail if something is missing)
#
# Safe to run again: the first run keeps the pre-Onyx state as the
# "original" backup and later runs never overwrite it. Only the current
# user's configuration is touched; no system file, service, partition,
# boot loader, kernel or driver is modified. Programs are never removed.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=lib/panel-layout.sh
. "$ROOT/lib/panel-layout.sh"

DRY_RUN=0 ASSUME_YES=0 NO_DEPS=0
for arg in "$@"; do
    case $arg in
        --dry-run | -n) DRY_RUN=1 ;;
        --yes | -y) ASSUME_YES=1 ;;
        --no-deps) NO_DEPS=1 ;;
        --help | -h)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) die "Opción desconocida: $arg (usa --help)" ;;
    esac
done

say "${C_B}Onyx XFCE $ONYX_VERSION${C_R} — instalador"

# --------------------------------------------------------------------------
step "Compatibilidad"
[[ $EUID -ne 0 ]] || die "Ejecuta el instalador como tu usuario, no con sudo."
((BASH_VERSINFO[0] >= 5)) || die "Se necesita bash 5 o superior."

distro="desconocida"
if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    distro=$(. /etc/os-release && printf '%s %s' "${NAME:-?}" "${VERSION_ID:-?}")
fi
info "Sistema:   $distro"
if ! grep -qiE '^(ID|ID_LIKE)=.*(ubuntu|debian|linuxmint)' /etc/os-release 2>/dev/null; then
    warn "Probado para Linux Mint 22.x XFCE (base Ubuntu 24.04)."
    confirm "¿Continuar de todos modos?" || exit 1
fi

panel_ver=$(xfce4-panel --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)
[[ -n $panel_ver ]] || die "No se encontró xfce4-panel: este proyecto es para XFCE."
info "Panel:     xfce4-panel $panel_ver"
IFS=. read -r pmaj pmin _ <<<"$panel_ver"
((pmaj > 4 || (pmaj == 4 && pmin >= 16))) || die "Se necesita xfce4-panel 4.16 o superior."

session=${XDG_SESSION_TYPE:-}
[[ -z $session && -n ${DISPLAY:-} ]] && session=x11
info "Sesión:    ${session:-sin sesión gráfica} / ${XDG_CURRENT_DESKTOP:-?}"
[[ $session == x11 ]] || die "Ejecuta el instalador dentro de la sesión gráfica XFCE (X11)."
[[ ${XDG_CURRENT_DESKTOP:-XFCE} == *XFCE* ]] || warn "El escritorio no se identifica como XFCE."

# --------------------------------------------------------------------------
step "Dependencias"
plugin_dir=""
for d in /usr/lib/x86_64-linux-gnu/xfce4/panel/plugins /usr/lib/xfce4/panel/plugins \
    /usr/lib64/xfce4/panel/plugins /usr/lib/*/xfce4/panel/plugins; do
    [[ -d $d ]] && plugin_dir=$d && break
done

missing=()
need_cmd() { command -v "$1" >/dev/null 2>&1 || missing+=("$2"); }
need_plugin() { [[ -n $plugin_dir && -e $plugin_dir/$1 ]] || missing+=("$2"); }
need_cmd xfconf-query xfconf
need_cmd playerctl playerctl
need_cmd curl curl
need_cmd dbus-send dbus-bin
need_cmd flock util-linux
need_cmd xprop x11-utils
need_cmd rfkill rfkill
need_plugin libgenmon.so xfce4-genmon-plugin
need_plugin libpulseaudio-plugin.so xfce4-pulseaudio-plugin
need_plugin libxkb.so xfce4-xkb-plugin
python3 -c 'import gi; gi.require_version("Gtk", "3.0"); from gi.repository import Gtk' \
    >/dev/null 2>&1 || missing+=(python3-gi gir1.2-gtk-3.0)
[[ -n $(fc-list "DejaVu Sans Mono" family 2>/dev/null) ]] || missing+=(fonts-dejavu-core)

if ((${#missing[@]})); then
    info "Faltan paquetes: ${missing[*]}"
else
    info "Todo lo necesario está instalado."
fi
for opt in "blueman-manager:blueman (gestor Bluetooth)" \
    "nm-connection-editor:network-manager-gnome (editor de conexiones)" \
    "pavucontrol:pavucontrol (mezclador de volumen)"; do
    command -v "${opt%%:*}" >/dev/null || note "Opcional, no instalado: ${opt#*:}"
done

# --------------------------------------------------------------------------
step "Brave Origin"
browser=${ONYX_BROWSER_DESKTOP:-}
if [[ -z $browser ]]; then
    for dir in "$HOME/.local/share/applications" /usr/share/applications \
        "$HOME/.local/share/flatpak/exports/share/applications" \
        /var/lib/flatpak/exports/share/applications /var/lib/snapd/desktop/applications; do
        [[ -d $dir ]] || continue
        for f in "$dir"/*.desktop; do
            [[ -f $f ]] || continue
            if [[ ${f,,} == *brave-origin* ]] || grep -qE '^Name=Brave Origin' "$f"; then
                # skip the beta/nightly channels unless nothing else exists
                if [[ ${f,,} == *beta* || ${f,,} == *nightly* ]]; then
                    fallback=${fallback:-$f}
                    continue
                fi
                browser=$f
                break 2
            fi
        done
    done
    browser=${browser:-${fallback:-}}
fi
if [[ -n $browser && -f $browser ]]; then
    info "Lanzador anclado: $browser"
else
    browser=""
    warn "No se encontró Brave Origin: no se anclará ningún lanzador (sin botones falsos)."
    note "Instálalo y vuelve a ejecutar ./install.sh, o usa ONYX_BROWSER_DESKTOP=/ruta/archivo.desktop"
fi

# --------------------------------------------------------------------------
step "Hardware detectado"
temp_src="ninguno (el módulo se ocultará)"
for h in /sys/class/hwmon/hwmon*; do
    [[ -r $h/name ]] || continue
    n=$(<"$h/name")
    case $n in k10temp | coretemp | acpitz | amdgpu) temp_src="$n"; [[ $n == k10temp || $n == coretemp ]] && break ;; esac
done
info "Temperatura: $temp_src"
bl=""
for d in /sys/class/backlight/*; do [[ -e $d ]] && bl=${d##*/} && break; done
info "Brillo:      ${bl:-sin retroiluminación (el módulo se ocultará)}"
bt="no (el módulo se ocultará)"
compgen -G "/sys/class/bluetooth/hci*" >/dev/null && bt="sí"
grep -qs bluetooth /sys/class/rfkill/*/type && bt="sí"
info "Bluetooth:   $bt"
wifi="no"
compgen -G "/sys/class/net/*/wireless" >/dev/null && wifi="sí"
info "Wi-Fi:       $wifi"
note "La batería no se muestra en ningún módulo."

# --------------------------------------------------------------------------
step "Cambios que se aplicarán"
icon_theme=$(xfconf-query -c xsettings -p /Net/IconThemeName 2>/dev/null || echo hicolor)
cat <<EOF
    Panel XFCE      se reemplaza por la barra Onyx (3 segmentos, arriba, 27 px)
    Escritorios     3 escritorios llamados "-", "--", "---"
    Teclado         distribuciones us,es (cambio con clic en el indicador)
    Energía         se oculta el icono de bandeja de xfce4-power-manager
    Archivos nuevos $ONYX_DATA/bin/  (scripts de los módulos)
                    $ONYX_ICONS/  (iconos, solo dentro del panel)
                    $GTK_DIR/onyx-panel.css
                    $ONYX_CFG/onyx.conf  (solo si no existe)
                    $ONYX_CFG/prompt.bash
                    $TERM_SCHEMES/onyx.theme  (opcional en la terminal)
    Bloque marcado  $GTK_DIR/gtk.css  (@import de onyx-panel.css)
                    $HOME/.bashrc  (carga el prompt)
    Respaldo        $ONYX_BACKUPS/
EOF
note "No se tocan Firefox, Brave Origin ni otros programas; no se usa sudo salvo para apt."

if ((DRY_RUN)); then
    say ""
    say "Modo --dry-run: no se ha modificado nada."
    exit 0
fi
confirm "¿Aplicar estos cambios?" || {
    say "Cancelado. No se ha modificado nada."
    exit 0
}

if ((${#missing[@]})); then
    ((NO_DEPS)) && die "Faltan dependencias y se indicó --no-deps."
    step "Instalando dependencias (sudo apt)"
    info "sudo apt-get install --no-install-recommends ${missing[*]}"
    sudo apt-get install -y --no-install-recommends "${missing[@]}"
fi

# --------------------------------------------------------------------------
step "Respaldo"
stamp=$(date +%Y%m%d-%H%M%S)
if [[ -d $ONYX_BACKUPS/original ]]; then
    backup="$ONYX_BACKUPS/$stamp"
else
    backup="$ONYX_BACKUPS/original"
fi
mkdir -p "$backup"
chmod 700 "$ONYX_BACKUPS"
if panel_running; then xfce4-panel --save >/dev/null 2>&1 || true; fi
info "Esperando a que xfconf escriba la configuración actual en disco…"
sleep 6
[[ -f $XFCONF_XML/xfce4-panel.xml ]] && cp -p "$XFCONF_XML/xfce4-panel.xml" "$backup/"
[[ -d $PANEL_DIR ]] && tar -C "$(dirname "$PANEL_DIR")" -czf "$backup/panel-dir.tar.gz" panel
[[ -f $GTK_DIR/gtk.css ]] && cp -p "$GTK_DIR/gtk.css" "$backup/gtk.css"
[[ -f $HOME/.bashrc ]] && cp -p "$HOME/.bashrc" "$backup/bashrc"
: >"$backup/xfconf.tsv"
for entry in "${ONYX_XFCONF_PROPS[@]}"; do
    read -r ch prop type arr <<<"$entry"
    printf '%s\t%s\t%s\t%s\n' "$ch" "$prop" "$arr" "$(xfconf_dump "$ch" "$prop" "$type" "$arr")" >>"$backup/xfconf.tsv"
done
printf 'onyx-xfce %s\ncreated %s\nfrom %s\n' "$ONYX_VERSION" "$(date -Is)" "$ROOT" >"$backup/MANIFEST"
info "Guardado en $backup"

# --------------------------------------------------------------------------
step "Instalando archivos"
mkdir -p "$ONYX_DATA/bin" "$ONYX_CFG" "$GTK_DIR" "$(dirname "$ONYX_ICONS")"
install -m 755 "$ROOT"/bin/onyx-* "$ONYX_DATA/bin/"
chmod 644 "$ONYX_DATA/bin/onyx-common.sh"

rm -rf "$ONYX_ICONS"
cp -r "$ROOT/icons/Onyx" "$ONYX_ICONS"
# Inherit the user's theme so app icons in the panel (Brave, tray) still resolve.
sed -i "s/^Inherits=.*/Inherits=${icon_theme},Adwaita,hicolor/" "$ONYX_ICONS/index.theme"
gtk-update-icon-cache -q -f -t "$ONYX_ICONS" 2>/dev/null || true

install -m 644 "$ROOT/config/gtk-3.0/onyx-panel.css" "$GTK_DIR/onyx-panel.css"
touch "$GTK_DIR/gtk.css"
put_block "$GTK_DIR/gtk.css" '@import url("onyx-panel.css");' top

if [[ -f $ONYX_CFG/onyx.conf ]]; then
    note "Se conserva tu $ONYX_CFG/onyx.conf"
else
    install -m 644 "$ROOT/config/onyx.conf" "$ONYX_CFG/onyx.conf"
fi
install -m 644 "$ROOT/config/bash/prompt.bash" "$ONYX_CFG/prompt.bash"
mkdir -p "$TERM_SCHEMES"
install -m 644 "$ROOT/config/terminal/onyx.theme" "$TERM_SCHEMES/onyx.theme"
touch "$HOME/.bashrc"
put_block "$HOME/.bashrc" "[ -f \"$ONYX_CFG/prompt.bash\" ] && . \"$ONYX_CFG/prompt.bash\""
info "Hecho."

# --------------------------------------------------------------------------
step "Configurando XFCE"
export LC_ALL=C
set_workspace_count 3
xfconf-query -c xfwm4 -p /general/workspace_names -n -a -t string -s "-" -t string -s "--" -t string -s "---"
info "Escritorios: - -- ---"
layouts=us,es
xfconf-query -c keyboard-layout -p /Default/XkbDisable -n -t bool -s false
xfconf-query -c keyboard-layout -p /Default/XkbLayout -n -t string -s "$layouts"
xfconf-query -c keyboard-layout -p /Default/XkbVariant -n -t string -s ","
info "Teclado: $layouts"
xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/show-tray-icon -n -t bool -s false
info "Bandeja: sin icono de batería"

panel_stop
stop_watchers # after the panel: a last refresh could restart the listener
onyx_write_panel "$ONYX_DATA/bin" "$browser"
sleep 0.5
panel_start
info "Panel Onyx iniciado."

# --------------------------------------------------------------------------
step "Comprobación rápida de los módulos"
check() { # label script
    local out
    out=$("$ONYX_DATA/bin/$2" 0 2>/dev/null || true)
    if [[ $out == '<bar>0</bar>' ]]; then
        info "$(printf '%-12s' "$1") oculto (no disponible en este equipo)"
    else
        out=${out%%<tool>*}
        out=$(sed -e 's/<\(icon\|iconclick\|txtclick\)>[^<]*<\/[a-z]*>//g' -e 's/<[^>]*>//g' <<<"$out")
        info "$(printf '%-12s' "$1") ${out:-visible (icono)}"
    fi
}
check Reloj onyx-clock
check CPU onyx-cpu
check RAM onyx-ram
check Temperatura onyx-temp
check Bluetooth onyx-bluetooth
check Red onyx-network
check Brillo onyx-brightness
note "El clima aparece al completar la primera descarga (segundos)."

say ""
say "${C_B}Listo.${C_R} Abre una terminal nueva para ver el prompt."
say "Para volver a la configuración anterior: ./restore.sh"
