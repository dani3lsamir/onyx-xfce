#!/usr/bin/env bash
# Onyx XFCE — restore the configuration saved by install.sh.
#
#   ./restore.sh                 restore the state from before the first install
#   ./restore.sh --from NAME     restore another backup (see --list)
#   ./restore.sh --list          list backups
#   ./restore.sh --yes           do not ask for confirmation
#
# Restores the panel, workspaces, keyboard layouts and power-manager tray
# setting, removes the Onyx blocks from gtk.css and .bashrc and deletes the
# installed Onyx files. Backups and onyx.conf are kept.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"

ASSUME_YES=0 FROM=original
while (($#)); do
    case $1 in
        --yes | -y) ASSUME_YES=1 ;;
        --from)
            FROM=${2:?--from necesita un nombre}
            shift
            ;;
        --list)
            ls -1 "$ONYX_BACKUPS" 2>/dev/null || say "No hay respaldos."
            exit 0
            ;;
        --help | -h)
            sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) die "Opción desconocida: $1 (usa --help)" ;;
    esac
    shift
done

backup="$ONYX_BACKUPS/$FROM"
[[ -d $backup ]] || die "No existe el respaldo '$FROM' en $ONYX_BACKUPS (usa --list)."
[[ $EUID -ne 0 ]] || die "Ejecuta restore.sh como tu usuario, no con sudo."

say "${C_B}Onyx XFCE${C_R} — restaurar desde ${C_B}$FROM${C_R}"
cat <<EOF
    Panel           $( [[ -f $backup/xfce4-panel.xml ]] && echo "configuración guardada" || echo "configuración por defecto de XFCE")
    xfconf          escritorios, teclado, icono de energía (valores previos)
    gtk.css/.bashrc se quitan los bloques "onyx-xfce"
    Se eliminan     $ONYX_DATA/bin  $ONYX_ICONS
                    $GTK_DIR/onyx-panel.css  $ONYX_CFG/prompt.bash
                    $TERM_SCHEMES/onyx.theme
    Se conservan    $ONYX_BACKUPS  $ONYX_CFG/onyx.conf
EOF
confirm "¿Restaurar?" || {
    say "Cancelado."
    exit 0
}

export LC_ALL=C

step "Panel"
panel_stop
stop_watchers # after the panel: a last refresh could restart the listener
xfconf-query -c xfce4-panel -p / -R -r 2>/dev/null || true
rm -rf "$PANEL_DIR"
if [[ -f $backup/panel-dir.tar.gz ]]; then
    mkdir -p "$(dirname "$PANEL_DIR")"
    tar -C "$(dirname "$PANEL_DIR")" -xzf "$backup/panel-dir.tar.gz"
fi
if [[ -f $backup/xfce4-panel.xml ]]; then
    # Replay the saved channel through xfconfd (no daemon is stopped).
    python3 - "$backup/xfce4-panel.xml" <<'PY'
import subprocess, sys
import xml.etree.ElementTree as ET

def q(*args):
    subprocess.run(["xfconf-query", "-c", "xfce4-panel", *args], check=False)

def walk(node, prefix):
    for prop in node.findall("property"):
        path = prefix + "/" + prop.get("name")
        kind = prop.get("type")
        if kind == "array":
            args = []
            for v in prop.findall("value"):
                args += ["-t", v.get("type"), "-s", v.get("value", "")]
            if args:
                q("-p", path, "-n", "-a", *args)
        elif kind not in (None, "empty"):
            q("-p", path, "-n", "-t", kind, "-s", prop.get("value", ""))
        walk(prop, path)

walk(ET.parse(sys.argv[1]).getroot(), "")
PY
    info "Configuración del panel restaurada."
else
    info "No había configuración previa: XFCE creará su panel por defecto."
fi

step "Ajustes de XFCE"
if [[ -f $backup/xfconf.tsv ]]; then
    while IFS=$'\t' read -r ch prop arr dump; do
        [[ -n $ch ]] || continue
        if [[ $prop == /general/workspace_count && $dump != unset ]]; then
            set_workspace_count "${dump#*$'\t'}"
        else
            xfconf_load "$ch" "$prop" "$arr" "$dump"
        fi
        info "$ch $prop"
    done <"$backup/xfconf.tsv"
fi

step "Archivos"
strip_block "$GTK_DIR/gtk.css"
[[ -f $GTK_DIR/gtk.css && ! -s $GTK_DIR/gtk.css && ! -f $backup/gtk.css ]] && rm -f "$GTK_DIR/gtk.css"
strip_block "$HOME/.bashrc"
rm -rf "${ONYX_DATA:?}/bin" "${ONYX_ICONS:?}"
rm -f "$GTK_DIR/onyx-panel.css" "$ONYX_CFG/prompt.bash" "$TERM_SCHEMES/onyx.theme"
rm -rf "${XDG_RUNTIME_DIR:-/dev/shm}/onyx-xfce"
info "Archivos de Onyx eliminados; respaldos en $ONYX_BACKUPS"

# Start the panel last, once onyx-panel.css is gone, so no Onyx style lingers.
panel_start

say ""
say "${C_B}Restaurado.${C_R} Abre una terminal nueva para recuperar tu prompt anterior."
