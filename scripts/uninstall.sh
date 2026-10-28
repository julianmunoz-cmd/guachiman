#!/bin/bash
# Desinstalación completa de Guachiman. Cada paso tolera fallos y el script sigue con el siguiente.
# Uso: guachiman --uninstall  (o Ajustes > "Desinstalar…")
set -u
# Si se lanza desde la app (que se cierra durante el proceso), ignora la señal de cierre.
trap '' HUP TERM
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

DIR="$(cd "$(dirname "$0")" && pwd)"
ID="io.github.guachiman"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# 1. Detiene el relay de IA, si existe.
if [ -f "$DIR/relay/start.sh" ]; then
  echo "Deteniendo el relay…"
  /bin/bash "$DIR/relay/start.sh" stop 2>/dev/null || true
fi

# 2. Quita el LaunchAgent de "Iniciar al encender".
echo "Quitando el inicio automático…"
launchctl bootout "gui/$(id -u)/$ID" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$ID.plist"

# 3. Borra la copia en ~/Applications, los datos y las preferencias.
echo "Borrando la app, los datos y las preferencias…"
rm -rf "$HOME/Applications/Guachiman.app" "$HOME/Library/Application Support/Guachiman"
defaults delete "$ID" 2>/dev/null || true
rm -f "$HOME/Library/Preferences/$ID.plist"

# 4. Quita los registros de Launch Services.
for app in "$HOME/Applications/Guachiman.app" /opt/homebrew/Cellar/guachiman/*/Guachiman.app /usr/local/Cellar/guachiman/*/Guachiman.app; do
  [ -e "$app" ] || continue
  "$LSREG" -u "$app" 2>/dev/null || true
done

# 5. Homebrew (se mantiene el tap). Al final: puede terminar la app en ejecución.
BREW=""
for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  [ -x "$b" ] && { BREW="$b"; break; }
done
if [ -n "$BREW" ] && "$BREW" list guachiman >/dev/null 2>&1; then
  echo "Desinstalando de Homebrew…"
  "$BREW" uninstall --force guachiman 2>/dev/null || true
  "$BREW" services stop guachiman 2>/dev/null || true
  launchctl bootout "gui/$(id -u)/homebrew.mxcl.guachiman" 2>/dev/null || true
  launchctl bootout "gui/$(id -u)/sh.brew.guachiman" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/homebrew.mxcl.guachiman.plist" "$HOME/Library/LaunchAgents/sh.brew.guachiman.plist"
fi

# 6. Cierra cualquier Guachiman que siga corriendo (lanzamientos fuera de brew).
pkill -x Guachiman 2>/dev/null || true

echo "Guachiman desinstalado. El permiso de notificaciones se quita en Ajustes del Sistema > Notificaciones."
