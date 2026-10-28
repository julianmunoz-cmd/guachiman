#!/bin/bash
# Arranca el relay de Guachiman como sesión de Claude Code en segundo plano (idempotente).
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
NAME="guachiman-relay"

for f in "$HOME"/.claude/sessions/*.json; do
  [ -e "$f" ] || continue
  if grep -q "\"name\":\"$NAME\"" "$f" 2>/dev/null; then
    pid="$(basename "$f" .json)"
    if kill -0 "$pid" 2>/dev/null; then
      echo "relay ya corriendo (pid $pid)"
      exit 0
    fi
  fi
done

# El directorio debe estar marcado como confiable por Claude Code (lo fija make relay-install).
RELAY_CWD="${RELAY_CWD:-$HOME}"
cd "$RELAY_CWD" || exit 1
exec "$CLAUDE" --bg --name "$NAME" --model haiku \
  "Arma el monitor de alertas ahora y quédate en espera." \
  --append-system-prompt-file "$DIR/brief.md" \
  --allowedTools "Monitor" "SendMessage" "ListAgents" "ToolSearch" \
    "Read($HOME/.claude/sessions/*)" \
    "Bash(ps *)" "Bash(tail *)" "Bash(cat *)" "Bash(ls *)"
