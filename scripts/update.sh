#!/bin/bash
# Actualiza Guachiman con Homebrew.
# Códigos de salida: 0 actualizado, 10 ya estaba al día, 2 no instalado con Homebrew, 1 error.
set -u
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

BREW=""
for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  [ -x "$b" ] && { BREW="$b"; break; }
done
if [ -z "$BREW" ] || ! "$BREW" list guachiman >/dev/null 2>&1; then
  echo "Guachiman no se instaló con Homebrew"
  exit 2
fi

"$BREW" update -q >/dev/null 2>&1 || true
if [ -z "$("$BREW" outdated --quiet guachiman 2>/dev/null)" ]; then
  echo "Ya tienes la última versión"
  exit 10
fi

echo "Actualizando Guachiman…"
if ! "$BREW" upgrade guachiman >/dev/null 2>&1; then
  echo "No se pudo actualizar con Homebrew"
  exit 1
fi

# El reinicio mata a la app que lo lanzó: va desacoplado y con retraso.
if "$BREW" services list 2>/dev/null | grep -Eq '^guachiman[[:space:]]+started'; then
  nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' bash -c "sleep 1; '$BREW' services restart guachiman" >/dev/null 2>&1 &
else
  APP="$("$BREW" --prefix)/opt/guachiman/Guachiman.app"
  nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' bash -c "sleep 1; pkill -x Guachiman; sleep 1; open '$APP'" >/dev/null 2>&1 &
fi
echo "Guachiman actualizado"
exit 0
