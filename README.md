# Guachiman

App nativa de la barra de menú de macOS (Swift + AppKit, macOS 13+) que vigila la RAM y la CPU de todas tus apps, además de tus sesiones de Claude Code y los procesos huérfanos, y te avisa con notificaciones. Sin ícono en el Dock, sin ventana, sin dependencias.

## Qué hace

- Detecta sesiones de Claude Code (terminal y Claude Desktop): procesos cuyo ejecutable o `argv[0]` se llama exactamente `claude` (las instalaciones de terminal viven en `~/.local/share/claude/versions/<ver>`, así que solo `argv[0]` dice `claude`).
- Suma la RAM (RSS) de cada sesión y de todos sus procesos hijos, y la etiqueta con el nombre de la carpeta de trabajo.
- Cada sesión se rotula con su título de Claude Code (el de la pestaña de la terminal; `/rename` manda sobre el automático), leído de forma perezosa solo al abrir el menú, al avisar o en `--once`; sin título muestra la carpeta.
- Muestra en el menú la memoria libre del sistema y las sesiones ordenadas por consumo. Cada fila (sesiones, huérfanos y las 5 apps) lleva un círculo de color y un botón para detenerla (ver "Colores y detener").
- Vigila todas las demás apps: agrupa los procesos por app (el `.app` más externo de la ruta del ejecutable, p. ej. los helpers de Google Chrome cuentan como "Google Chrome"; un proceso fuera de un `.app` es su propio grupo) y suma su RAM y su CPU (% de un núcleo, calculado entre dos sondeos). Los procesos de sesiones de Claude y de huérfanos no se repiten ahí. El menú lista las 5 apps que más RAM usan.
- Te notifica cuando una sesión, una app o el sistema superan los umbrales. Las apps solo se cierran si tú lo pides con el botón de detener.
- Lee los procesos con `libproc` y `sysctl`; no lanza `ps`.

## Notificaciones

Son solo nativas (`UNUserNotificationCenter`); la app nunca usa `osascript`, así que ningún aviso aparece atribuido a "Script Editor". Si las notificaciones no están autorizadas, el menú muestra "Activar notificaciones…", que abre Ajustes del Sistema > Notificaciones. El estado se vuelve a revisar en cada sondeo, así que el ítem desaparece cuando las activas. Mientras no estén autorizadas, el ícono rojo sigue indicando la alerta.

Para comprobar que funcionan, ejecuta `make notify-test`: abre la app con `--notify-test` y, al resolverse la autorización, envía "Prueba: Guachiman puede notificarte".

## Huérfanos

Un candidato a huérfano es un proceso con `ppid == 1` cuyo nombre (del ejecutable o de `argv[0]`, también con sufijo tras guion, como `next-server`) es `node`, `vitest`, `next` o `playwright`, y que no pertenece a ninguna sesión de Claude. Su RAM suma la del proceso y la de todos sus descendientes. Se avisa cuando supera 500 MB de forma sostenida por 60 s, con el mismo enfriamiento que el resto de alertas. `--once` también los lista.

## Colores y detener

Cada fila del menú (sesiones de Claude, huérfanos y las 5 apps que más consumen) empieza con un círculo de color. La CPU de sesiones y huérfanos es la suma de su árbol de procesos, como en las apps. Los valores son instantáneos, salvo el gris:

- **Gris**: inactivo; CPU por debajo de 1 % de forma continua durante los últimos 120 s. Una fila vista hace menos de 120 s no es gris. El gris manda sobre los demás colores, también si usa mucha RAM.
- **Rojo**: supera un umbral (RAM sobre el 15% de la RAM física, o CPU sobre 80% de un núcleo; en huérfanos, RAM sobre 500 MB).
- **Amarillo**: al menos el 75 % de alguno de esos umbrales.
- **Verde**: el resto.

Al borde derecho de cada fila hay un ícono de detener (no aparece en Guachiman). Al pulsarlo se abre una confirmación con el nombre, la RAM y los pids: "¿Cerrar …?". Si confirmas:

- Una app (`.app`) se cierra como con Cmd-Q (`terminate()`); si no se encuentra la app en ejecución, se envía SIGTERM a sus procesos.
- Sesiones de Claude, huérfanos y procesos sueltos reciben SIGTERM en todo su árbol, hijos primero.
- A los 5 s, si algo sigue vivo, se pregunta "¿Forzar cierre?": `forceTerminate()` para apps y SIGKILL para el resto.

Nunca se señalan los pids 0 y 1 ni el propio Guachiman. El menú se construye al abrirlo, a partir del último sondeo, y no se reconstruye en cada sondeo.

## Menú

- **Cerrar huérfanos automáticamente** (apagado por defecto, se recuerda entre ejecuciones): si lo activas, un huérfano de más de 500 MB sostenido por 10 min recibe SIGTERM junto con sus descendientes, tras reverificar que sigue siendo huérfano. No se escala a SIGKILL y se te notifica qué se cerró.
- **Pausar 1 h**: durante una hora no hay notificaciones ni cierres automáticos; el menú y el ícono siguen actualizándose. Mientras dura aparece "Reanudar (pausado hasta HH:mm)", que cancela la pausa.
- **Iniciar al encender**: crea o borra `~/Library/LaunchAgents/io.github.guachiman.plist` (surte efecto en el próximo inicio de sesión). "Salir" termina con estado 0, así que no se relanza.
- Solo se ejecuta una instancia a la vez.

## Avisos a la sesión de Claude

Cuando salta una alerta de sesión (y no estás en pausa), Guachiman añade una línea JSON a `~/Library/Application Support/Guachiman/pending/<pid de la sesión>.jsonl` con la RAM de la sesión, el umbral, el directorio y el proceso hijo más grande (`top`: pid, MB y comando). La notificación también nombra a ese hijo ("mayor: vitest 1,8 GB"). Si la sesión termina, su archivo se borra.

El hook `~/.claude/hooks/guachiman-alerts.sh` (PostToolUse) busca el archivo de la sesión que lo ejecuta, lo consume y entrega a Claude un aviso corto como contexto adicional, para que cierre el proceso que sobra o acote las pruebas y te cuente qué hizo.

Para instalarlo, copia el script a `~/.claude/hooks/`, hazlo ejecutable y añade esto en `hooks.PostToolUse` de `~/.claude/settings.json`:

```json
{
  "matcher": "Bash",
  "hooks": [
    { "type": "command", "command": "$HOME/.claude/hooks/guachiman-alerts.sh", "timeout": 5 }
  ]
}
```

Diseño eficiente: Guachiman no suma timers, hilos ni watchers; el hijo mayor sale de las lecturas que ya hace en cada sondeo y solo se resuelve su nombre en sesiones sobre el umbral, y el archivo se escribe únicamente cuando la alerta se dispara. El hook, sin avisos pendientes, termina con un glob de bash y sin lanzar ningún proceso.

## Qué no hace

Solo cierra lo que tú confirmas con el botón de detener de cada fila, o los huérfanos si activas "Cerrar huérfanos automáticamente" (apagado por defecto). Nunca cierra nada por su cuenta salvo esa opción, ni cierra sesiones de Claude sin tu confirmación.

## Compilar y correr

```sh
make          # compila build/Guachiman.app y la firma ad-hoc
make run      # compila y abre la app
make check    # ejecuta --once
make test     # ejecuta --selftest
make notify-test  # compila, abre la app y envía una notificación de prueba
make release VERSION=x.y.z  # publica una versión (ver "Publicar una versión")
make icon     # regenera icon/AppIcon.icns y los PNG de la barra desde icon/*.svg
make clean
```

Necesitas las herramientas de línea de comandos de Xcode (`swiftc`).

## Verificación: `--once`

```sh
build/Guachiman.app/Contents/MacOS/Guachiman --once
```

Imprime una tabla con pid, etiqueta, MB totales, estado (verde, amarillo o rojo; el gris no se puede saber con una sola muestra) y cwd de cada sesión, los huérfanos, las 10 apps que más RAM usan (con su CPU medida en ~1 s), la memoria libre y los umbrales calculados, y termina sin abrir la interfaz. Sirve como `doctor`.

## Umbrales

Se calculan a partir de la RAM física (`hw.memsize`). Las constantes están al inicio de `guachiman.swift`.

- Sesión: más del 15% de la RAM física, sostenido por al menos 60 s.
- App: más del 15% de la RAM física sostenido por 60 s, o más de 80% de un núcleo de CPU sostenido por 120 s.
- Sistema: memoria libre menor a 20% (`kern.memorystatus_level`).
- Enfriamiento de 10 min por alerta; avisa antes solo si el valor creció más de 25% desde el último aviso.
- Sondeo cada 20 s.

El ícono se atenúa sin sesiones y se pone rojo mientras haya una alerta activa.

## Instalación con Homebrew

1. Confía en el tap (desde Homebrew 7 los taps de terceros lo requieren antes de instalar):

   ```sh
   brew trust xklbr/tap
   ```

2. Instala:

   ```sh
   brew install xklbr/tap/guachiman
   ```

3. Inícialo ahora y en cada inicio de sesión:

   ```sh
   brew services start guachiman
   ```

Para detenerlo usa `brew services stop guachiman`; para desinstalarlo, `brew uninstall guachiman`.

Se compila desde el código fuente, así que necesitas las Command Line Tools (`xcode-select --install`). No hace falta Xcode completo.

Desde la terminal puedes ejecutar `guachiman --once` para ver un diagnóstico.

Para actualizar a la última versión:

```sh
brew update && brew upgrade guachiman
```

Si tenías abierta una copia desde `build/`, ciérrala antes: la app es de instancia única y la segunda no arranca.

## Publicar una versión

Para quien mantiene el proyecto. No hay cuenta ni registro en Homebrew: el tap es simplemente el repositorio público [xklbr/homebrew-tap](https://github.com/xklbr/homebrew-tap), cuya fórmula `Formula/guachiman.rb` apunta al tarball del tag `vX.Y.Z` de este repo y a su `sha256`.

Requisitos:

- Permiso de `git push` (y `gh` autenticado, si lo usas) en `xklbr/guachiman` y `xklbr/homebrew-tap`.
- El tap clonado como carpeta hermana: `../homebrew-tap` (o define `TAP_DIR`).
- Command Line Tools.
- Ambos repos limpios, en `main` y al día con `origin`.

Primero ensaya y luego publica:

```sh
DRY_RUN=1 make release VERSION=x.y.z   # valida e imprime los comandos, sin cambiar nada
make release VERSION=x.y.z
```

`scripts/release.sh` hace, en orden:

1. Valida la versión (`x.y.z`), que el tag no exista (local ni en origin), que ambos repos estén limpios, en `main` y al día.
2. Pone `CFBundleShortVersionString` en la versión y suma 1 a `CFBundleVersion` en `Info.plist`.
3. Ejecuta `make test`.
4. Hace commit `chore: versión x.y.z`, crea el tag anotado `vx.y.z` y sube `main` y el tag.
5. Descarga el tarball del tag (con reintentos) y calcula su `sha256`.
6. Actualiza `url` y `sha256` de la fórmula, hace commit `feat: guachiman x.y.z` en el tap y lo sube.

### A mano

Si el script falla a medias o prefieres hacerlo manualmente:

```sh
# En guachiman: edita Info.plist (versión y CFBundleVersion), luego
make test
git commit -am "chore: versión x.y.z"
git tag -a vx.y.z -m "Guachiman x.y.z"
git push origin main vx.y.z

# Calcula el sha256 del tarball
curl -fsSL https://github.com/xklbr/guachiman/archive/refs/tags/vx.y.z.tar.gz | shasum -a 256

# En homebrew-tap: actualiza url y sha256 en Formula/guachiman.rb
git commit -am "feat: guachiman x.y.z"
git push origin main
```

### Verificar

```sh
brew update
brew upgrade guachiman
brew test xklbr/tap/guachiman
brew audit --strict --formula xklbr/tap/guachiman
```

### ¿Y homebrew-core o homebrew-cask?

- **homebrew-core** exige que el proyecto sea notable (alrededor de 75 estrellas, o 30 forks/watchers) y no acepta apps con interfaz gráfica.
- **homebrew-cask** exige firma de Apple y notarización (Apple Developer Program, USD 99 al año).

Por eso se eligió el tap propio.

## Licencia

MIT.
