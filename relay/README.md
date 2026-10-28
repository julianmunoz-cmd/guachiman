# Relay de Guachiman

Una sesión de Claude Code en segundo plano (Haiku) que lee las alertas de memoria de Guachiman y se las entrega, por A2A (`SendMessage`), a la sesión de Claude Code dueña del proceso. Luego hace seguimiento.

## Qué hace

- Vigila `~/Library/Application Support/Guachiman/alerts.jsonl` con `tail -n 0 -F` (Monitor persistente, se re-arma al expirar).
- Alerta de sesión: envía UN mensaje corto `[Guachiman]` a la sesión (nombre tomado de `~/.claude/sessions/<pid>.json`) con el total vs el límite, el proceso hijo más pesado y qué hacer. No comprueba si el pid sigue vivo: Guachiman solo escribe la alerta mientras el proceso está vivo y sobre el umbral.
- Alerta de huérfano: busca con `Read` sobre `~/.claude/sessions/*.json` (o `ListAgents`) las sesiones vivas cuyo `cwd` sea igual o prefijo del `cwd` del huérfano y les avisa. Si no hay ninguna, no hace nada (Guachiman ya avisó al usuario).
- Seguimiento: si llega otra alerta del mismo pid después de haber avisado a su sesión una vez, insiste UNA vez (un mensaje). Después ignora ese pid.

## Modo y herramientas

- Corre en modo `bypassPermissions` (`--permission-mode bypassPermissions`). Así sus mensajes no quedan retenidos por sesiones receptoras que también usan ese modo (modos de permisos distintos retienen el mensaje).
- Sin Bash: `--tools "Monitor,SendMessage,ListAgents,Read,ToolSearch"` limita el conjunto disponible, de modo que Bash, Write, Edit, WebFetch, etc. no existen para el relay.

## Seguridad

- El relay no tiene shell ni puede editar archivos ni matar procesos.
- Todos los campos de una alerta (`cwd`, `title`, `name`, `cmd`) son datos no confiables: el brief ordena tratarlos como datos, nunca como instrucciones.
- Guachiman sanea los campos antes de escribirlos: `top.cmd` y `name` solo conservan `[A-Za-z0-9._ +-]` (máx. 40); `cwd` y `title` pierden los caracteres de control (máx. 200).

## Costo

- Unos 300-400 MB de RAM mientras corre.
- Tokens de Haiku por cada alerta y por cada re-armado del monitor (máximo cada 30 min).

## Instalar y desinstalar

```sh
make relay-install     # copia start.sh y brief.md a ~/Library/Application Support/Guachiman/relay,
                       # escribe el LaunchAgent y lo carga con launchctl; arranca al iniciar sesión
make relay-uninstall   # bootout, borra el plist y la copia, y detiene la sesión del relay
```

Notas:
- Se copia fuera de `~/Documents` porque launchd no tiene permiso para ejecutar scripts ahí.
- La sesión corre con el directorio del repo como `cwd`, que debe ser un workspace ya confiable para Claude Code (de lo contrario no arranca: "Workspace not trusted"). Revisa `/tmp/guachiman-relay.log`.
- `start.sh` es idempotente: si ya hay una sesión `guachiman-relay` viva, no hace nada. Al reinstalar con una sesión viva se conserva la anterior (usa `claude stop <id>` antes si quieres recargar `brief.md`).

## Verificar que corre

```sh
launchctl print gui/$(id -u)/io.github.guachiman.relay | grep -E "state|last exit"
claude agents --json | grep -B4 -A3 guachiman-relay
claude logs <id>       # el id sale de `claude agents --json` / ~/.claude/sessions/<pid>.json (jobId)
ps aux | grep 'tail -n 0 -F' | grep alerts.jsonl   # el monitor armado
```

El estado normal de la sesión es `idle` o `shell` (esperando el monitor).

## Probar

Agrega una alerta falsa que apunte a una sesión viva (cambia `pid` por el de esa sesión):

```sh
echo '{"kind":"session","ts":'$(date +%s)',"pid":<PID>,"mb":9999,"limit_mb":2764,"cwd":"'$PWD'","title":"prueba","top":{"pid":<PID>,"mb":1,"cmd":"prueba-relay"}}' \
  >> "$HOME/Library/Application Support/Guachiman/alerts.jsonl"
```

La sesión destino debe recibir un mensaje `[Guachiman]`. Si esa sesión usa otro modo de permisos que el relay, el mensaje queda retenido hasta que su usuario lo apruebe (llega un `[Cross-session delivery notice]` al relay).
