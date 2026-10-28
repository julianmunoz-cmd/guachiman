# Guachiman

App nativa de la barra de menú de macOS (Swift + AppKit, macOS 13+) que vigila la RAM que usan tus sesiones de Claude Code y te avisa con notificaciones. Sin ícono en el Dock, sin ventana, sin dependencias.

## Qué hace

- Detecta sesiones de Claude Code (terminal y Claude Desktop): procesos cuyo ejecutable o `argv[0]` se llama exactamente `claude` (las instalaciones de terminal viven en `~/.local/share/claude/versions/<ver>`, así que solo `argv[0]` dice `claude`).
- Suma la RAM (RSS) de cada sesión y de todos sus procesos hijos, y la etiqueta con el nombre de la carpeta de trabajo.
- Muestra en el menú la memoria libre del sistema y las sesiones ordenadas por consumo.
- Te notifica cuando una sesión o el sistema superan los umbrales.
- Lee los procesos con `libproc` y `sysctl`; no lanza `ps`.

## Notificaciones

Son solo nativas (`UNUserNotificationCenter`); la app nunca usa `osascript`, así que ningún aviso aparece atribuido a "Script Editor". Si las notificaciones no están autorizadas, el menú muestra "Activar notificaciones…", que abre Ajustes del Sistema > Notificaciones. El estado se vuelve a revisar en cada sondeo, así que el ítem desaparece cuando las activas. Mientras no estén autorizadas, el ícono rojo sigue indicando la alerta.

Para comprobar que funcionan, ejecuta `make notify-test`: abre la app con `--notify-test` y, al resolverse la autorización, envía "Prueba: Guachiman puede notificarte".

## Huérfanos

Un candidato a huérfano es un proceso con `ppid == 1` cuyo nombre (del ejecutable o de `argv[0]`, también con sufijo tras guion, como `next-server`) es `node`, `vitest`, `next` o `playwright`, y que no pertenece a ninguna sesión de Claude. Su RAM suma la del proceso y la de todos sus descendientes. Se avisa cuando supera 500 MB de forma sostenida por 60 s, con el mismo enfriamiento que el resto de alertas. `--once` también los lista.

## Menú

- **Cerrar huérfanos automáticamente** (apagado por defecto, se recuerda entre ejecuciones): si lo activas, un huérfano de más de 500 MB sostenido por 10 min recibe SIGTERM junto con sus descendientes, tras reverificar que sigue siendo huérfano. No se escala a SIGKILL y se te notifica qué se cerró.
- **Pausar 1 h**: durante una hora no hay notificaciones ni cierres automáticos; el menú y el ícono siguen actualizándose. Mientras dura aparece "Reanudar (pausado hasta HH:mm)", que cancela la pausa.
- **Iniciar al encender**: crea o borra `~/Library/LaunchAgents/io.github.guachiman.plist` (surte efecto en el próximo inicio de sesión). "Salir" termina con estado 0, así que no se relanza.
- Solo se ejecuta una instancia a la vez.

## Qué no hace

Por defecto es de solo lectura: no envía señales a ningún proceso. Solo cierra huérfanos si tú activas "Cerrar huérfanos automáticamente", y nunca toca sesiones de Claude.

## Compilar y correr

```sh
make          # compila build/Guachiman.app y la firma ad-hoc
make run      # compila y abre la app
make check    # ejecuta --once
make test     # ejecuta --selftest
make notify-test  # compila, abre la app y envía una notificación de prueba
make icon     # regenera icon/AppIcon.icns y los PNG de la barra desde icon/*.svg
make clean
```

Necesitas las herramientas de línea de comandos de Xcode (`swiftc`).

## Verificación: `--once`

```sh
build/Guachiman.app/Contents/MacOS/Guachiman --once
```

Imprime una tabla con pid, etiqueta, MB totales y cwd de cada sesión, la memoria libre y los umbrales calculados, y termina sin abrir la interfaz. Sirve como `doctor`.

## Umbrales

Se calculan a partir de la RAM física (`hw.memsize`). Las constantes están al inicio de `guachiman.swift`.

- Sesión: más del 15% de la RAM física, sostenido por al menos 60 s.
- Sistema: memoria libre menor a 20% (`kern.memorystatus_level`).
- Enfriamiento de 10 min por alerta; avisa antes solo si el valor creció más de 25% desde el último aviso.
- Sondeo cada 20 s con sesiones activas, cada 60 s sin ellas.

El ícono se atenúa sin sesiones y se pone rojo mientras haya una alerta activa.

## Instalación con Homebrew

Próximamente.

## Licencia

MIT.
