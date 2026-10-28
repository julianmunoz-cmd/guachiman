#!/bin/bash
# Relay de Guachiman: sesión de Claude Code en segundo plano.
#   start.sh         arranca el relay (idempotente)
#   start.sh stop    detiene el relay si está corriendo
# Env: CLAUDE_BIN (ruta de claude), RELAY_CWD (directorio de trabajo; debe ser confiable para Claude Code).
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
NAME="guachiman-relay"

# Imprime "<pid> <jobId>" de la sesión del relay viva, si existe.
find_relay() {
  local f pid job
  for f in "$HOME"/.claude/sessions/*.json; do
    [ -e "$f" ] || continue
    grep -q "\"name\":\"$NAME\"" "$f" 2>/dev/null || continue
    pid="$(basename "$f" .json)"
    kill -0 "$pid" 2>/dev/null || continue
    job="$(sed -n 's/.*"jobId":"\([^"]*\)".*/\1/p' "$f")"
    echo "$pid $job"
    return 0
  done
  return 1
}

if [ "${1:-}" = "stop" ]; then
  read -r pid job < <(find_relay) || { echo "relay no está corriendo"; exit 0; }
  "$CLAUDE" stop "${job:-$pid}" >/dev/null 2>&1
  echo "relay detenido (pid $pid)"
  exit 0
fi

if read -r pid _ < <(find_relay); then
  echo "relay ya corriendo (pid $pid)"
  exit 0
fi

# Claude Code se niega a correr --bg en un workspace no confiable (no hay flag para saltarlo). Se prueban, en orden:
# RELAY_CWD y ~/Library/Application Support/Guachiman/relay-cwd (hay que confiar en él una vez: ejecutar `claude` ahí).
# No se usan carpetas protegidas (Documents, etc.): sin permiso de TCC la app queda colgada al entrar en ellas.
CANDIDATES=()
[ -n "${RELAY_CWD:-}" ] && CANDIDATES+=("$RELAY_CWD")
CANDIDATES+=("$HOME/Library/Application Support/Guachiman/relay-cwd")

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
for cwd in "${CANDIDATES[@]}"; do
  mkdir -p "$cwd" 2>/dev/null
  cd "$cwd" || continue
  # Sin Bash: solo estas herramientas existen (--tools). bypassPermissions para que sus mensajes no queden retenidos
  # por la sesión receptora (modos de permisos distintos).
  "$CLAUDE" --bg --name "$NAME" --model haiku \
    --permission-mode bypassPermissions \
    --tools "Monitor,SendMessage,ListAgents,Read,ToolSearch" \
    --append-system-prompt-file "$DIR/brief.md" \
    "Arma el monitor de alertas ahora y quédate en espera." >"$LOG" 2>&1 </dev/null
  rc=$?
  out="$(cat "$LOG")"
  echo "$out"
  [ $rc -eq 0 ] && exit 0
  case "$out" in *"not trusted"*) continue ;; *) exit $rc ;; esac
done
echo "ningún directorio confiable para el relay; ejecuta 'claude' una vez en ~/Library/Application Support/Guachiman/relay-cwd y acepta la confianza" >&2
exit 1
