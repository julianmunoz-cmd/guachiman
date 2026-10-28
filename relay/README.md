# Relay de Guachiman

Una sesión de Claude Code en segundo plano (Haiku) que lee las alertas de memoria de Guachiman y se las entrega, por A2A (`SendMessage`), a la sesión de Claude Code dueña del proceso. Luego hace seguimiento.

## Qué hace

- Vigila `~/Library/Application Support/Guachiman/alerts.jsonl` con `tail -n 0 -F` (Monitor persistente, se re-arma al expirar).
- Alerta de sesión: si el pid sigue vivo, envía UN mensaje corto `[Guachiman]` a la sesión (nombre tomado de `~/.claude/sessions/<pid>.json`) con el total vs el límite, el proceso hijo más pesado y qué hacer.
- Alerta de huérfano: si sigue vivo, avisa a toda sesión viva cuyo `cwd` sea igual o prefijo del `cwd` del huérfano. Si no hay ninguna, no hace nada (Guachiman ya avisó al usuario).
- Seguimiento: cuando la sesión responde, revisa con `ps`; si el pid sigue vivo y no bajó, insiste una vez más. Nunca más de una insistencia por pid.
- Nunca mata ni modifica procesos, no edita archivos y ignora todo lo que no sea su rol.

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

La sesión destino debe recibir un mensaje `[Guachiman]`. Si esa sesión usa otro modo de permisos, el mensaje queda retenido hasta que su usuario lo apruebe.
