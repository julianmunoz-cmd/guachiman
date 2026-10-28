// Guachiman — menu bar app que vigila la RAM y la CPU de todas las apps, además de
// las sesiones de Claude Code y los procesos huérfanos.
// Solo cierra procesos cuando el usuario lo confirma con el botón de detener de cada fila
// del panel, o con SIGTERM a huérfanos (ppid 1: node, vitest, next, playwright) si activa
// "Cerrar huérfanos automáticamente" (apagado de fábrica).

import AppKit
import Darwin
import UserNotifications

// MARK: - Constantes

enum Config {
    static let sessionFraction = 0.15            // alerta de sesión: > 15% de la RAM física
    static let sessionSustained: TimeInterval = 60   // ... sostenido al menos 60 s
    static let systemFreeMinPercent = 20         // alerta de sistema: libre < 20%
    static let cooldown: TimeInterval = 600      // enfriamiento por clave: 10 min
    static let regrowthFactor = 1.25             // re-alerta antes si el valor creció > 25%
    static let pollActive: TimeInterval = 20     // intervalo de sondeo
    static let appCpuPercent = 80.0              // alerta de app: > 80% de un núcleo
    static let appCpuSustained: TimeInterval = 120   // ... sostenido 120 s
    static let sessionExecutable = "claude"
    static let orphanBytes: UInt64 = 500 * 1_048_576  // huérfano: > 500 MB
    static let orphanAlertAfter: TimeInterval = 60    // ... sostenido 60 s para avisar
    static let orphanCloseAfter: TimeInterval = 600   // ... sostenido 10 min para cerrar
    static let idleCpuPercent = 1.0              // fila inactiva: CPU < 1 %
    static let idleAfter: TimeInterval = 120     // ... de forma continua por 120 s
    static let warnFraction = 0.75               // amarillo: >= 75 % de un umbral
    static let pauseDuration: TimeInterval = 3600
    static let autoCloseKey = "autoCloseOrphans"
    static let aiKey = "aiEnabled"
    static let loginText = "Inicia sesión en Claude Code: abre la terminal y ejecuta `claude`"
    static let agentLabel = "io.github.guachiman"
    static let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Guachiman").path
    static let alertsFile = supportDir + "/alerts.jsonl"
}

// MARK: - Lógica pura (cubierta por --selftest)

enum Orphan {
    static let names: Set<String> = ["node", "vitest", "next", "playwright"]

    /// Nombre coincidente: último componente del ejecutable o del primer token de argv[0];
    /// acepta sufijo con guion (`next-server`) porque las herramientas renombran el título.
    static func name(exe: String?, argv0: String?) -> String? {
        for c in [exe, argv0?.split(separator: " ").first.map(String.init)] {
            guard let c else { continue }
            let n = (c as NSString).lastPathComponent.lowercased()
            if names.contains(n) || names.contains(where: { n.hasPrefix($0 + "-") }) { return n }
        }
        return nil
    }
}

/// Desde cuándo está cada clave (pid, grupo de app...) por encima del umbral.
struct SustainedTracker<Key: Hashable> {
    private var since: [Key: Date] = [:]

    /// Devuelve cuánto lleva sostenido (0 si no está por encima).
    mutating func update(_ key: Key, over: Bool, now: Date) -> TimeInterval {
        guard over else { since[key] = nil; return 0 }
        let start = since[key] ?? now
        since[key] = start
        return now.timeIntervalSince(start)
    }

    mutating func retain(_ live: Set<Key>) { since = since.filter { live.contains($0.key) } }
}

/// Grupo de una app: el `.app` más externo del path; sin `.app`, el proceso es su propio grupo (clave con pid).
func appGroup(path: String?, argv0: String?, pid: pid_t) -> (key: String, name: String) {
    if let path, let r = path.range(of: ".app/") {
        return (String(path[..<r.upperBound]), ((String(path[..<r.lowerBound])) as NSString).lastPathComponent)
    }
    return ("pid:\(pid)", ((path ?? argv0 ?? "?") as NSString).lastPathComponent)
}

/// % de un núcleo a partir de dos lecturas de tiempo de CPU en unidades Mach.
func cpuPercent(prev: UInt64, cur: UInt64, wall: TimeInterval, timebase: (numer: UInt32, denom: UInt32)) -> Double {
    guard wall > 0, cur >= prev, timebase.denom > 0 else { return 0 }
    return Double(cur - prev) * Double(timebase.numer) / Double(timebase.denom) / (wall * 1e9) * 100
}

enum RowColor: String {
    case green = "verde", yellow = "amarillo", red = "rojo", gray = "gris"
}

/// Color de una fila. Gris (inactiva) manda sobre el resto; después rojo (sobre el umbral),
/// amarillo (>= 75 % de algún umbral) y verde. `cpuLimit` nil = sin umbral de CPU (huérfanos).
func rowColor(bytes: UInt64, cpu: Double, ramLimit: UInt64, cpuLimit: Double?, idleFor: TimeInterval) -> RowColor {
    if cpu < Config.idleCpuPercent, idleFor >= Config.idleAfter { return .gray }
    if bytes > ramLimit || (cpuLimit.map { cpu > $0 } ?? false) { return .red }
    if Double(bytes) >= Config.warnFraction * Double(ramLimit)
        || (cpuLimit.map { cpu >= Config.warnFraction * $0 } ?? false) { return .yellow }
    return .green
}

/// Color del anillo de memoria libre con la misma regla que las filas: rojo bajo el mínimo,
/// amarillo si lo usado llega al 75 % del umbral de uso, verde en otro caso.
func freeMemoryColor(freePercent: Int) -> RowColor {
    let usedLimit = Double(100 - Config.systemFreeMinPercent)
    if freePercent < Config.systemFreeMinPercent { return .red }
    if Double(100 - freePercent) >= Config.warnFraction * usedLimit { return .yellow }
    return .green
}

/// % de CPU total de la máquina entre dos lecturas de ticks (ocupado / total).
func cpuLoadPercent(prev: (busy: UInt64, total: UInt64), cur: (busy: UInt64, total: UInt64)) -> Double {
    guard cur.total > prev.total, cur.busy >= prev.busy else { return 0 }
    return min(100, Double(cur.busy - prev.busy) / Double(cur.total - prev.total) * 100)
}

private let hostPort = mach_host_self()

/// Una sola llamada a host_statistics: ticks ocupados (user+system+nice) y totales.
func cpuTicks() -> (busy: UInt64, total: UInt64)? {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &count) }
    }
    guard kr == KERN_SUCCESS else { return nil }
    let t = info.cpu_ticks
    let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)
    return (busy, busy + UInt64(t.2))
}

func pauseActive(until: Date?, now: Date) -> Bool {
    guard let until else { return false }
    return now < until
}

func launchAgentPlist(executable: String) -> [String: Any] {
    ["Label": Config.agentLabel,
     "ProgramArguments": [executable],
     "RunAtLoad": true,
     "KeepAlive": ["SuccessfulExit": false],
     "ProcessType": "Interactive"]
}

/// Hijo más grande (por RSS) de una sesión; el pid raíz nunca cuenta.
struct TopChild: Equatable {
    var pid: pid_t
    var bytes: UInt64
    var cmd = ""
}

func largerChild(_ cur: TopChild?, pid: pid_t, bytes: UInt64, root: pid_t) -> TopChild? {
    guard pid != root, bytes > (cur?.bytes ?? 0) else { return cur }
    return TopChild(pid: pid, bytes: bytes)
}

/// Nombre corto del comando: último componente de argv[0], o del ejecutable; máx. 80.
func commandName(argv0: String?, exe: String?) -> String {
    for c in [argv0, exe] {
        guard let c, !c.isEmpty else { continue }
        let n = (c as NSString).lastPathComponent
        if !n.isEmpty { return String(n.prefix(80)) }
    }
    return "?"
}

func jsonLine(_ d: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

/// Saneo de campos no confiables antes de escribirlos en `alerts.jsonl`: nombres solo [A-Za-z0-9._ +-], máx. 40.
func sanitizeName(_ s: String) -> String {
    String(String.UnicodeScalarView(s.unicodeScalars.filter {
        $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._ +-".unicodeScalars.contains($0))
    }).prefix(40))
}

/// Rutas y títulos: sin caracteres de control, máx. 200.
func sanitizeText(_ s: String) -> String {
    String(String.UnicodeScalarView(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).prefix(200))
}

/// Línea de `alerts.jsonl` para una sesión que superó el umbral.
func sessionAlertLine(ts: Int, pid: pid_t, mb: UInt64, limitMB: UInt64, cwd: String, title: String?, top: TopChild?) -> String {
    var d: [String: Any] = ["kind": "session", "ts": ts, "pid": Int(pid), "mb": mb, "limit_mb": limitMB,
                            "cwd": sanitizeText(cwd), "title": title.map { sanitizeText($0) } ?? NSNull()]
    d["top"] = top.map { ["pid": Int($0.pid), "mb": $0.bytes / 1_048_576, "cmd": sanitizeName($0.cmd)] as [String: Any] } ?? NSNull()
    return jsonLine(d)
}

/// Línea de `alerts.jsonl` para un huérfano.
func orphanAlertLine(ts: Int, pid: pid_t, name: String, mb: UInt64, limitMB: UInt64, cwd: String) -> String {
    jsonLine(["kind": "orphan", "ts": ts, "pid": Int(pid), "name": sanitizeName(name), "mb": mb, "limit_mb": limitMB, "cwd": sanitizeText(cwd)])
}

/// Añade una línea al archivo de eventos; rota a `.1` si pasa de 1 MB (un solo stat), crea el directorio al vuelo,
/// cierra al instante, ignora errores.
func appendAlert(_ line: String, path: String = Config.alertsFile, maxBytes: Int = 1_048_576) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    var st = stat()
    if stat(path, &st) == 0, Int(st.st_size) > maxBytes { rename(path, path + ".1") }
    let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    guard fd >= 0 else { return }
    let bytes = Array((line + "\n").utf8)
    _ = write(fd, bytes, bytes.count)
    close(fd)
}

// MARK: - Relay de IA (sesión de Claude Code en segundo plano; solo se lanzan procesos al activar, arrancar o salir)

/// Ruta del CLI de Claude Code (launchd trae un PATH mínimo, así que se buscan las ubicaciones habituales).
func claudeBinary() -> String? {
    let home = NSHomeDirectory()
    return [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Interpreta la salida de `claude auth status --json`: true solo si `loggedIn` es true.
func parseAuthLoggedIn(_ data: Data) -> Bool {
    ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["loggedIn"] as? Bool ?? false
}

/// `claude auth status --json` (~0.2 s). Error, salida no válida o código distinto de 0 cuentan como "sin sesión".
func claudeLoggedIn(_ claude: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: claude)
    p.arguments = ["auth", "status", "--json"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 && parseAuthLoggedIn(data)
}

/// Ejecuta `start.sh [arg]` del bundle; con `wait` espera a que termine (para detener al salir).
func runRelay(_ arg: String?, wait: Bool) {
    guard let claude = claudeBinary(),
          let script = Bundle.main.resourcePath.map({ $0 + "/relay/start.sh" }),
          FileManager.default.fileExists(atPath: script) else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [script] + (arg.map { [$0] } ?? [])
    // Entorno mínimo: si Guachiman se lanzó desde una sesión de Claude Code heredaría su entorno y el relay no arrancaría limpio.
    let home = NSHomeDirectory()
    let env: [String: String] = ["HOME": home, "USER": NSUserName(), "LOGNAME": NSUserName(), "TMPDIR": NSTemporaryDirectory(),
               "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "CLAUDE_BIN": claude]
        .merging(ProcessInfo.processInfo.environment["RELAY_CWD"].map { ["RELAY_CWD": $0] } ?? [:]) { a, _ in a }
    p.environment = env
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return }
    if wait { p.waitUntilExit() }
}

/// Texto de memoria libre baja con los 2 mayores consumidores (sesiones y apps) por RAM.
func systemLowText(freePercent: Int, consumers: [(name: String, bytes: UInt64)]) -> String {
    var t = "Memoria libre baja: \(freePercent) %"
    let top = consumers.sorted { $0.bytes > $1.bytes }.prefix(2)
    if !top.isEmpty { t += " · mayores: " + top.map { "\($0.name) \(formatBytes($0.bytes))" }.joined(separator: ", ") }
    return t
}

// MARK: - Título de sesión de Claude Code

/// Directorio codificado de proyectos de Claude: cada carácter no alfanumérico del cwd pasa a "-".
func encodedProjectDir(_ cwd: String) -> String {
    String(cwd.unicodeScalars.map { s -> Character in
        (s.isASCII && (CharacterSet.alphanumerics.contains(s))) ? Character(s) : "-"
    })
}

/// Últimos `customTitle` y `aiTitle` de un trozo de JSONL.
func lastTitles(in text: String) -> (custom: String?, ai: String?) {
    var custom: String?, ai: String?
    for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
        let isC = custom == nil && line.contains("\"custom-title\"")
        let isA = ai == nil && line.contains("\"ai-title\"")
        guard isC || isA,
              let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
        if isC, o["type"] as? String == "custom-title", let t = o["customTitle"] as? String, !t.isEmpty { custom = t }
        if isA, o["type"] as? String == "ai-title", let t = o["aiTitle"] as? String, !t.isEmpty { ai = t }
        if custom != nil { break }   // el renombrado manual manda; no hace falta seguir
    }
    return (custom, ai)
}

/// Título de una sesión desde un trozo de JSONL: el último `custom-title` gana sobre el último `ai-title`.
func extractSessionTitle(_ text: String) -> String? {
    let t = lastTitles(in: text)
    return t.custom ?? t.ai
}

func truncatedTitle(_ s: String) -> String { s.count > 50 ? String(s.prefix(49)) + "…" : s }

private struct TitleEntry { var title: String?; var mtime: Date; var checkedAt: Date }
private var titleCache: [pid_t: TitleEntry] = [:]
private var transcriptPathCache: [String: String?] = [:]
private let claudeDir = NSHomeDirectory() + "/.claude"

private func transcriptPath(sessionId: String, cwd: String) -> String? {
    let direct = "\(claudeDir)/projects/\(encodedProjectDir(cwd))/\(sessionId).jsonl"
    if FileManager.default.fileExists(atPath: direct) { return direct }
    if let c = transcriptPathCache[sessionId] { return c }
    let base = "\(claudeDir)/projects"
    var found: String?
    for d in (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? [] {
        let p = "\(base)/\(d)/\(sessionId).jsonl"
        if FileManager.default.fileExists(atPath: p) { found = p; break }
    }
    transcriptPathCache[sessionId] = found
    return found
}

/// Lee todo el archivo en trozos de 1 MB (sin cargarlo entero), conservando el último título de cada tipo.
private func scanWholeFile(_ fh: FileHandle) -> String? {
    var custom: String?, ai: String?
    var carry = Data()
    try? fh.seek(toOffset: 0)
    while true {
        let chunk = (try? fh.read(upToCount: 1 << 20)) ?? Data()
        let eof = chunk.isEmpty
        var buf = carry + chunk
        carry = Data()
        if !eof, let nl = buf.lastIndex(of: 0x0A) {
            carry = buf.suffix(from: nl + 1)
            buf = buf.prefix(through: nl)
        } else if !eof { carry = buf; continue }
        let t = lastTitles(in: String(decoding: buf, as: UTF8.self))
        if let c = t.custom { custom = c }
        if let a = t.ai { ai = a }
        if eof { break }
    }
    return custom ?? ai
}

/// Título de la sesión (lo que muestra la pestaña de la terminal), con caché en memoria. Solo se llama
/// cuando hace falta una etiqueta; refresca a lo sumo cada 5 min y solo si cambió el mtime de la transcripción.
func sessionTitle(pid: pid_t) -> String? {
    let now = Date()
    let old = titleCache[pid]
    if let old, now.timeIntervalSince(old.checkedAt) < 300 { return old.title }
    var entry = TitleEntry(title: nil, mtime: .distantPast, checkedAt: now)
    defer { titleCache[pid] = entry }
    guard let data = FileManager.default.contents(atPath: "\(claudeDir)/sessions/\(pid).json"),
          let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let sid = o["sessionId"] as? String, let cwd = o["cwd"] as? String,
          let path = transcriptPath(sessionId: sid, cwd: cwd),
          let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    else { return nil }
    entry.mtime = mtime
    if let old, old.mtime == mtime { entry.title = old.title; return old.title }
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    let tail: UInt64 = 256 * 1024
    try? fh.seek(toOffset: size > tail ? size - tail : 0)
    let text = String(decoding: (try? fh.readToEnd()) ?? Data(), as: UTF8.self)
    var title = extractSessionTitle(text)
    if title == nil { title = old != nil ? old?.title : (size > tail ? scanWholeFile(fh) : nil) }
    entry.title = title
    return title
}

/// Título ya conocido, sin leer disco.
func cachedSessionTitle(pid: pid_t) -> String? { titleCache[pid]?.title }

func pruneTitleCache(live: Set<pid_t>) { titleCache = titleCache.filter { live.contains($0.key) } }

/// Etiqueta visible: título de Claude Code (máx. 50) o, sin él, la carpeta.
func sessionLabel(_ s: Session) -> String { sessionTitle(pid: s.pid).map(truncatedTitle) ?? s.label }

func runSelfTest() {
    precondition(parseAuthLoggedIn(Data(#"{"loggedIn":true,"authMethod":"claude.ai"}"#.utf8)))
    precondition(!parseAuthLoggedIn(Data(#"{"loggedIn":false}"#.utf8)))
    precondition(!parseAuthLoggedIn(Data("basura".utf8)))
    precondition(!parseAuthLoggedIn(Data(#"{"loggedIn":"true"}"#.utf8)))
    var top: TopChild?
    top = largerChild(top, pid: 10, bytes: 999, root: 10)            // la raíz no cuenta
    precondition(top == nil)
    top = largerChild(top, pid: 11, bytes: 100, root: 10)
    top = largerChild(top, pid: 12, bytes: 300, root: 10)
    top = largerChild(top, pid: 13, bytes: 200, root: 10)
    precondition(top == TopChild(pid: 12, bytes: 300))
    precondition(commandName(argv0: "/usr/bin/node", exe: "/x/y") == "node")
    precondition(commandName(argv0: nil, exe: "/x/vitest") == "vitest")
    precondition(commandName(argv0: nil, exe: nil) == "?")
    precondition(commandName(argv0: String(repeating: "a", count: 200), exe: nil).count == 80)
    let line = sessionAlertLine(ts: 5, pid: 7, mb: 2048, limitMB: 1024, cwd: "/a \"b\"/c", title: "t",
                                top: TopChild(pid: 9, bytes: 3 * 1_048_576, cmd: "vitest"))
    let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    precondition(!line.contains("\n") && obj?["kind"] as? String == "session" && obj?["pid"] as? Int == 7
                 && obj?["limit_mb"] as? Int == 1024 && obj?["title"] as? String == "t")
    precondition(obj?["cwd"] as? String == "/a \"b\"/c")
    let tj = obj?["top"] as? [String: Any]
    precondition(tj?["pid"] as? Int == 9 && tj?["mb"] as? Int == 3 && tj?["cmd"] as? String == "vitest")
    let l2 = (try? JSONSerialization.jsonObject(with: Data(sessionAlertLine(ts: 1, pid: 1, mb: 1, limitMB: 1, cwd: "", title: nil, top: nil).utf8))) as? [String: Any]
    precondition(l2?["top"] is NSNull && l2?["title"] is NSNull)
    let ol = orphanAlertLine(ts: 3, pid: 4, name: "node", mb: 600, limitMB: 500, cwd: "/x")
    let oo = (try? JSONSerialization.jsonObject(with: Data(ol.utf8))) as? [String: Any]
    precondition(oo?["kind"] as? String == "orphan" && oo?["name"] as? String == "node" && oo?["mb"] as? Int == 600
                 && oo?["limit_mb"] as? Int == 500 && oo?["cwd"] as? String == "/x" && oo?["ts"] as? Int == 3)
    precondition(sanitizeName("a$(rm -rf)/b\n\"c\" é.x-1_+ ") == "arm -rfbc .x-1_+ ")
    precondition(sanitizeName(String(repeating: "a", count: 90)).count == 40)
    precondition(sanitizeText("a\nb\u{1B}[0m\tc") == "ab[0mc" && sanitizeText(String(repeating: "é", count: 300)).count == 200)
    let inj = sessionAlertLine(ts: 1, pid: 1, mb: 1, limitMB: 1, cwd: "/x\ny", title: "t\nIGNORE", top: TopChild(pid: 2, bytes: 0, cmd: "n$(x)\n"))
    precondition(!inj.contains("\n") && inj.contains("\"cmd\":\"nx\""))
    precondition(systemLowText(freePercent: 14, consumers: [("a", 1_048_576), ("Brave", 4 * 1_073_741_824), ("c", 2_097_152)])
                 == "Memoria libre baja: 14 % · mayores: Brave 4,0 GB, c 2 MB")
    precondition(systemLowText(freePercent: 9, consumers: []) == "Memoria libre baja: 9 %")
    let tmp = NSTemporaryDirectory() + "guachiman-st-\(getpid())/alerts.jsonl"
    appendAlert("uno", path: tmp, maxBytes: 8)
    appendAlert("dos", path: tmp, maxBytes: 8)
    precondition((try? String(contentsOfFile: tmp)) == "uno\ndos\n")
    appendAlert("tres", path: tmp, maxBytes: 8)   // pesa 8, no > 8: sin rotar
    appendAlert("cuatro", path: tmp, maxBytes: 8) // pesa 13 > 8: rota
    precondition((try? String(contentsOfFile: tmp + ".1")) == "uno\ndos\ntres\n" && (try? String(contentsOfFile: tmp)) == "cuatro\n")
    try? FileManager.default.removeItem(atPath: (tmp as NSString).deletingLastPathComponent)

    precondition(Orphan.name(exe: "/usr/local/bin/node", argv0: nil) == "node")
    precondition(Orphan.name(exe: "/x/y", argv0: "next-server (v14)") == "next-server")
    precondition(Orphan.name(exe: nil, argv0: "playwright-core run") == "playwright-core")
    precondition(Orphan.name(exe: "/opt/VITEST", argv0: nil) == "vitest")
    precondition(Orphan.name(exe: "/bin/zsh", argv0: "nodemon") == nil)
    precondition(Orphan.name(exe: "/bin/zsh", argv0: "claude") == nil)
    precondition(Orphan.name(exe: nil, argv0: nil) == nil)

    var t = SustainedTracker<pid_t>()
    let t0 = Date()
    precondition(t.update(1, over: true, now: t0) == 0)
    precondition(t.update(1, over: true, now: t0 + 61) >= Config.orphanAlertAfter)
    precondition(t.update(1, over: true, now: t0 + 61) < Config.orphanCloseAfter)
    precondition(t.update(1, over: true, now: t0 + 601) >= Config.orphanCloseAfter)
    precondition(t.update(1, over: false, now: t0 + 602) == 0)
    precondition(t.update(1, over: true, now: t0 + 700) == 0)   // reinicia al volver a superar
    _ = t.update(2, over: true, now: t0)
    t.retain([1])
    precondition(t.update(2, over: true, now: t0 + 900) == 0)   // pid muerto olvidado

    var ts = SustainedTracker<String>()
    _ = ts.update("a", over: true, now: t0)
    precondition(ts.update("a", over: true, now: t0 + 5) == 5)
    ts.retain([])
    precondition(ts.update("a", over: true, now: t0 + 9) == 0)

    let chrome = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
    precondition(appGroup(path: chrome, argv0: nil, pid: 5) == ("/Applications/Google Chrome.app/", "Google Chrome"))
    precondition(appGroup(path: "/usr/bin/python3", argv0: nil, pid: 7) == ("pid:7", "python3"))
    precondition(appGroup(path: "/usr/bin/python3", argv0: nil, pid: 8).key != appGroup(path: "/usr/bin/python3", argv0: nil, pid: 7).key)
    precondition(appGroup(path: nil, argv0: "/opt/x/tool", pid: 9) == ("pid:9", "tool"))
    precondition(appGroup(path: nil, argv0: nil, pid: 9).name == "?")
    precondition(cpuPercent(prev: 0, cur: 1_000_000_000, wall: 1, timebase: (1, 1)) == 100)
    precondition(abs(cpuPercent(prev: 10, cur: 24_000_010, wall: 2, timebase: (125, 3)) - 50) < 0.0001)
    precondition(cpuPercent(prev: 5, cur: 9, wall: 0, timebase: (1, 1)) == 0)
    precondition(cpuPercent(prev: 9, cur: 5, wall: 1, timebase: (1, 1)) == 0)

    precondition(rowColor(bytes: 2000, cpu: 0.5, ramLimit: 1000, cpuLimit: 80, idleFor: 120) == .gray)   // gris manda sobre rojo
    precondition(rowColor(bytes: 2000, cpu: 0.5, ramLimit: 1000, cpuLimit: 80, idleFor: 119) == .red)
    precondition(rowColor(bytes: 10, cpu: 0, ramLimit: 1000, cpuLimit: 80, idleFor: 60) == .green)       // < 120 s no es gris
    precondition(rowColor(bytes: 10, cpu: 5, ramLimit: 1000, cpuLimit: 80, idleFor: 500) == .green)      // con CPU >= 1 % no es gris
    precondition(rowColor(bytes: 1000, cpu: 10, ramLimit: 1000, cpuLimit: 80, idleFor: 0) == .yellow)    // igual al umbral no es rojo
    precondition(rowColor(bytes: 10, cpu: 81, ramLimit: 1000, cpuLimit: 80, idleFor: 0) == .red)
    precondition(rowColor(bytes: 750, cpu: 10, ramLimit: 1000, cpuLimit: 80, idleFor: 0) == .yellow)
    precondition(rowColor(bytes: 749, cpu: 10, ramLimit: 1000, cpuLimit: 80, idleFor: 0) == .green)
    precondition(rowColor(bytes: 10, cpu: 60, ramLimit: 1000, cpuLimit: 80, idleFor: 0) == .yellow)
    precondition(rowColor(bytes: 10, cpu: 500, ramLimit: 1000, cpuLimit: nil, idleFor: 0) == .green)    // huérfano: sin umbral de CPU

    precondition(freeMemoryColor(freePercent: 19) == .red && freeMemoryColor(freePercent: 20) == .yellow)
    precondition(freeMemoryColor(freePercent: 40) == .yellow && freeMemoryColor(freePercent: 41) == .green)
    precondition(cpuLoadPercent(prev: (10, 100), cur: (35, 200)) == 25)
    precondition(cpuLoadPercent(prev: (10, 100), cur: (10, 100)) == 0)
    let now = Date()
    precondition(!pauseActive(until: nil, now: now))
    precondition(pauseActive(until: now + 10, now: now))
    precondition(!pauseActive(until: now - 1, now: now))

    let d = launchAgentPlist(executable: "/a/Guachiman")
    precondition(d["Label"] as? String == "io.github.guachiman")
    precondition(d["ProgramArguments"] as? [String] == ["/a/Guachiman"])
    precondition(d["RunAtLoad"] as? Bool == true)
    precondition((d["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false)
    precondition(d["ProcessType"] as? String == "Interactive")
    precondition((try? PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0)) != nil)
    precondition(encodedProjectDir("/Users/xklbr/Documents/projects/guachiman") == "-Users-xklbr-Documents-projects-guachiman")
    precondition(encodedProjectDir("/a b/c.d_e") == "-a-b-c-d-e")
    let jl = "{\"type\":\"ai-title\",\"aiTitle\":\"uno\"}\n{\"type\":\"custom-title\",\"customTitle\":\"mio\"}\n{\"type\":\"ai-title\",\"aiTitle\":\"dos\"}\n"
    precondition(extractSessionTitle(jl) == "mio")
    precondition(extractSessionTitle("{\"type\":\"ai-title\",\"aiTitle\":\"uno\"}\nbasura\n{\"type\":\"ai-title\",\"aiTitle\":\"dos\"}") == "dos")
    precondition(extractSessionTitle("{\"type\":\"user\"}\n") == nil)
    precondition(truncatedTitle(String(repeating: "x", count: 60)).count == 50 && truncatedTitle("hola") == "hola")
    print("selftest OK")
}

// MARK: - Lectura de procesos (libproc / sysctl)

struct Session {
    let pid: pid_t
    let label: String
    let cwd: String
    let bytes: UInt64
    let cpu: Double          // % de un núcleo, suma del árbol
    let tree: [pid_t]
    var top: TopChild? = nil   // solo si supera el umbral
}

struct OrphanProc {
    let pid: pid_t
    let name: String
    let bytes: UInt64
    let cpu: Double
    let tree: [pid_t]   // el huérfano y todos sus descendientes
}

struct AppUsage {
    let key: String
    let name: String
    var bytes: UInt64 = 0
    var cpu = 0.0   // % de un núcleo
    var pids: [pid_t] = []
}

struct Snapshot {
    let sessions: [Session]   // ordenadas por RAM desc
    let orphans: [OrphanProc]
    let apps: [AppUsage]      // resto de procesos agrupados por app, por RAM desc
    let freePercent: Int
}

func physicalMemory() -> UInt64 {
    var value: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    sysctlbyname("hw.memsize", &value, &size, nil, 0)
    return value
}

func freeMemoryPercent() -> Int {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    sysctlbyname("kern.memorystatus_level", &value, &size, nil, 0)
    return Int(value)
}

func allPids() -> [pid_t] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) + 64)
    let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard got > 0 else { return [] }
    return pids.prefix(Int(got)).filter { $0 > 0 }
}

func parentPid(_ pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return pid_t(info.pbi_ppid)
}

/// Buffer reutilizable para KERN_PROCARGS2 (se evita reservar 64 KB en cada llamada).
private var procArgsBuffer = [UInt8](repeating: 0, count: 1 << 16)

/// argv[0] vía sysctl KERN_PROCARGS2. Los binarios de terminal viven en
/// `.../claude/versions/<ver>`, así que ni el path ni p_comm dicen "claude"; argv[0] sí.
func argv0(_ pid: pid_t) -> String? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = procArgsBuffer.count                    // fijo y sobrado: evita carreras entre tamaño y lectura
    guard sysctl(&mib, 3, &procArgsBuffer, &size, nil, 0) == 0, size > 4 else { return nil }
    let buf = procArgsBuffer
    var i = 4                                          // salta argc
    while i < size, buf[i] != 0 { i += 1 }             // exec path
    while i < size, buf[i] == 0 { i += 1 }             // relleno
    let start = i
    while i < size, buf[i] != 0 { i += 1 }
    guard i > start else { return nil }
    return String(decoding: buf[start..<i], as: UTF8.self)
}

func isClaude(_ pid: pid_t) -> Bool {
    if let path = executablePath(pid), (path as NSString).lastPathComponent == Config.sessionExecutable { return true }
    if let arg = argv0(pid), (arg as NSString).lastPathComponent == Config.sessionExecutable { return true }
    return false
}

func taskInfo(_ pid: pid_t) -> proc_taskinfo? {
    var info = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
    return info
}

/// Lecturas previas de CPU (pid → tiempo en unidades Mach) para calcular el delta entre sondeos.
private var cpuPrev: [pid_t: UInt64] = [:]
private var cpuPrevAt: Date?
private let timebase: (numer: UInt32, denom: UInt32) = {
    var t = mach_timebase_info_data_t()
    mach_timebase_info(&t)
    return (t.numer, t.denom)
}()

func executablePath(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard n > 0 else { return nil }
    return String(cString: buffer)
}

func currentDirectory(_ pid: pid_t) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
}

private let sessionLimitBytes = UInt64(Double(physicalMemory()) * Config.sessionFraction)

func takeSnapshot() -> Snapshot {
    var parents: [pid_t: pid_t] = [:]
    var children: [pid_t: [pid_t]] = [:]
    var claudePids = Set<pid_t>()

    for pid in allPids() {
        guard let ppid = parentPid(pid) else { continue }
        parents[pid] = ppid
        children[ppid, default: []].append(pid)
        if isClaude(pid) { claudePids.insert(pid) }
    }

    // Raíces: claude sin ancestro claude.
    let roots = claudePids.filter { pid in
        var current = parents[pid]
        var hops = 0
        while let p = current, p > 1, hops < 256 {
            if claudePids.contains(p) { return false }
            current = parents[p]
            hops += 1
        }
        return true
    }

    // Una sola lectura de taskinfo por pid da RSS y tiempo de CPU; la primera lectura de un pid da CPU 0.
    let sampledAt = Date()
    let wall = cpuPrevAt.map { sampledAt.timeIntervalSince($0) } ?? 0
    var cpuNow: [pid_t: UInt64] = [:]
    func read(_ pid: pid_t, cpu: inout Double) -> UInt64? {
        guard let ti = taskInfo(pid) else { return nil }
        let ticks = ti.pti_total_user + ti.pti_total_system
        cpuNow[pid] = ticks
        if let prev = cpuPrev[pid] { cpu += cpuPercent(prev: prev, cur: ticks, wall: wall, timebase: timebase) }
        return ti.pti_resident_size
    }

    func tree(_ root: pid_t) -> [pid_t] {
        var out: [pid_t] = []
        var stack = [root]
        var seen = Set<pid_t>()
        while let pid = stack.popLast() {
            guard seen.insert(pid).inserted else { continue }
            out.append(pid)
            stack.append(contentsOf: children[pid] ?? [])
        }
        return out
    }

    var sessions: [Session] = []
    var sessionPids = Set<pid_t>()
    for root in roots {
        let pids = tree(root)
        sessionPids.formUnion(pids)
        var total: UInt64 = 0
        var cpu = 0.0
        var best: TopChild?
        for p in pids {
            let r = read(p, cpu: &cpu) ?? 0
            total += r
            best = largerChild(best, pid: p, bytes: r, root: root)
        }
        let cwd = currentDirectory(root) ?? ""
        let label = cwd.isEmpty ? "?" : (cwd as NSString).lastPathComponent
        if total > sessionLimitBytes, var b = best {   // solo sesiones sobre el umbral pagan estas lecturas
            b.cmd = commandName(argv0: argv0(b.pid), exe: executablePath(b.pid))
            best = b
        } else { best = nil }
        sessions.append(Session(pid: root, label: label, cwd: cwd, bytes: total, cpu: cpu, tree: pids, top: best))
    }
    sessions.sort { $0.bytes > $1.bytes }

    // Huérfanos: ppid 1, nombre conocido, fuera de (y sin claude dentro de) árboles de sesión.
    var orphans: [OrphanProc] = []
    for (pid, ppid) in parents where ppid == 1 && !claudePids.contains(pid) && !sessionPids.contains(pid) {
        guard let name = Orphan.name(exe: executablePath(pid), argv0: argv0(pid)) else { continue }
        let pids = tree(pid)
        if !sessionPids.isDisjoint(with: pids) { continue }
        var cpu = 0.0
        var bytes: UInt64 = 0
        for p in pids { bytes += read(p, cpu: &cpu) ?? 0 }
        orphans.append(OrphanProc(pid: pid, name: name, bytes: bytes, cpu: cpu, tree: pids))
    }
    orphans.sort { $0.bytes > $1.bytes }

    // Apps: todo lo que no es sesión ni huérfano, agrupado por .app.
    let excluded = sessionPids.union(orphans.flatMap { $0.tree })
    var groups: [String: AppUsage] = [:]
    for pid in parents.keys where !excluded.contains(pid) {
        var cpu = 0.0
        guard let rss = read(pid, cpu: &cpu) else { continue }
        let path = executablePath(pid)
        let g = appGroup(path: path, argv0: path == nil ? argv0(pid) : nil, pid: pid)
        groups[g.key, default: AppUsage(key: g.key, name: g.name)].bytes += rss
        groups[g.key]!.cpu += cpu
        groups[g.key]!.pids.append(pid)
    }
    cpuPrev = cpuNow
    cpuPrevAt = sampledAt
    let apps = groups.values.sorted { $0.bytes > $1.bytes }
    return Snapshot(sessions: sessions, orphans: orphans, apps: apps, freePercent: freeMemoryPercent())
}

// MARK: - Formato

func formatBytes(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    let es = Locale(identifier: "es")
    if gb >= 1 { return String(format: "%.1f GB", locale: es, gb) }
    return String(format: "%.0f MB", locale: es, Double(bytes) / 1_048_576)
}

// MARK: - Modo --once

func runOnce() {
    _ = takeSnapshot()                      // primera lectura de CPU
    Thread.sleep(forTimeInterval: 1)
    let snap = takeSnapshot()
    let mem = physicalMemory()
    let limit = UInt64(Double(mem) * Config.sessionFraction)
    // Con una sola muestra de 1 s no se puede saber si una fila está inactiva: nunca sale "gris".
    func status(_ bytes: UInt64, _ cpu: Double, _ ramLimit: UInt64, _ cpuLimit: Double?) -> String {
        rowColor(bytes: bytes, cpu: cpu, ramLimit: ramLimit, cpuLimit: cpuLimit, idleFor: 0).rawValue
    }
    print("PID\tETIQUETA\tTITULO\tTOTAL_MB\tESTADO\tCWD")
    for s in snap.sessions {
        print("\(s.pid)\t\(s.label)\t\(sessionTitle(pid: s.pid).map(truncatedTitle) ?? "-")\t\(s.bytes / 1_048_576)\t\(status(s.bytes, s.cpu, limit, Config.appCpuPercent))\t\(s.cwd)")
    }
    if snap.sessions.isEmpty { print("(sin sesiones de Claude)") }
    print("")
    print("Candidatos a huérfano (pid\tnombre\tMB\testado)")
    for o in snap.orphans { print("\(o.pid)\t\(o.name)\t\(o.bytes / 1_048_576)\t\(status(o.bytes, o.cpu, Config.orphanBytes, nil))") }
    if snap.orphans.isEmpty { print("(ninguno)") }
    print("")
    print("Apps (nombre\tMB\tCPU %\testado)")
    for a in snap.apps.prefix(10) {
        print("\(a.name)\t\(a.bytes / 1_048_576)\t\(Int(a.cpu.rounded()))\t\(status(a.bytes, a.cpu, limit, Config.appCpuPercent))")
    }
    print("")
    print("Memoria libre: \(snap.freePercent)%")
    print("RAM física: \(mem / 1_048_576) MB")
    print("Umbral de sesión: \(limit / 1_048_576) MB (\(Int(Config.sessionFraction * 100))% de la RAM, sostenido \(Int(Config.sessionSustained)) s)")
    print("Umbral de app: \(limit / 1_048_576) MB sostenido \(Int(Config.sessionSustained)) s, o \(Int(Config.appCpuPercent)) % de CPU sostenido \(Int(Config.appCpuSustained)) s")
    print("Umbral de sistema: memoria libre < \(Config.systemFreeMinPercent)%")
}

// MARK: - Notificaciones (solo UNUserNotificationCenter)

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private(set) var isAuthorized = false

    /// Pide autorización (si falta) y luego refresca el estado; `completion` corre en main.
    func start(completion: @escaping () -> Void = {}) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            self?.refresh(completion: completion)
        }
    }

    /// Relee el estado real en Ajustes del Sistema; `completion` corre en main.
    func refresh(completion: @escaping () -> Void = {}) {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async {
                self?.isAuthorized = status == .authorized || status == .provisional
                completion()
            }
        }
    }

    // Sin esto macOS no muestra el banner si la app está activa (p. ej. con el menú abierto).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func send(_ text: String) {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Guachiman"
        content.body = text
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }   // si falla, el ícono rojo sigue avisando
    }
}

// MARK: - Aplicación

/// Qué cerrar al pulsar detener en una fila; se captura al construir el menú.
struct KillTarget {
    let name: String
    let bytes: UInt64
    let pids: [pid_t]        // árbol en preorden (la raíz primero)
    let appPath: String?     // grupo de una app (.app): se cierra con NSRunningApplication
    let expandTree: Bool     // proceso suelto: al cerrar se incluyen sus descendientes
}

/// ¿Es seguro enviarle señales? Nunca pid <= 1 ni Guachiman.
func signalable(_ pid: pid_t) -> Bool { pid > 1 && pid != getpid() }
func alive(_ pid: pid_t) -> Bool { signalable(pid) && kill(pid, 0) == 0 }

/// Descendientes de `root` (incluido), en preorden, con una lectura nueva de la tabla de procesos.
func liveTree(_ root: pid_t) -> [pid_t] {
    var children: [pid_t: [pid_t]] = [:]
    for pid in allPids() { if let pp = parentPid(pid) { children[pp, default: []].append(pid) } }
    var out: [pid_t] = []
    var stack = [root]
    var seen = Set<pid_t>()
    while let pid = stack.popLast() {
        guard seen.insert(pid).inserted else { continue }
        out.append(pid)
        stack.append(contentsOf: children[pid] ?? [])
    }
    return out
}

// MARK: - Panel isla (vistas AppKit; solo existen mientras el panel está abierto)

class FlippedView: NSView { override var isFlipped: Bool { true } }

/// Panel sin activar la app: puede ser key para recibir Esc, nunca main.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Paleta del popover (tokens oscuros del diseño).
enum Pal {
    static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
                blue: CGFloat(v & 255) / 255, alpha: 1)
    }
    static let popover = hex(0x161616)
    static let foreground = hex(0xededed)
    static let muted = hex(0x9a9a9a)
    static let accent = hex(0x262626)
    static let primary = hex(0x00d495)
    static let destructive = hex(0xe5484d)
    static let border = hex(0x2a2a2a)
}

func panelLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, mono: Bool = false,
                color: NSColor = Pal.foreground, align: NSTextAlignment = .left, frame: NSRect) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        : NSFont.systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.alignment = align
    l.lineBreakMode = .byTruncatingTail
    l.maximumNumberOfLines = 1
    l.frame = frame
    return l
}

/// Botón sin borde con fondo `accent` al pasar el cursor (IA y ajustes).
final class HoverButton: NSButton {
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) {
        if isEnabled { layer?.backgroundColor = Pal.accent.cgColor }
    }

    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }
}

/// Fila del panel: punto de estado, nombre, memoria y, a la derecha, CPU (o botón de detener al pasar el cursor).
final class PanelRow: FlippedView {
    static let height: CGFloat = 24
    private let cpuLabel: NSTextField
    private var stopButton: NSButton?
    private var area: NSTrackingArea?

    init(width: CGFloat, text: String, memory: String, cpu: String, color: NSColor, stopTag: Int?, stopLabel: String,
         stopTip: String, target: AnyObject, action: Selector) {
        let colW: CGFloat = 30, memW: CGFloat = 64
        let colX = width - 8 - colW
        let memX = colX - 8 - memW
        cpuLabel = panelLabel(cpu, size: 11, mono: true, color: Pal.muted, align: .right,
                              frame: NSRect(x: colX, y: 5, width: colW, height: 14))
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: PanelRow.height))
        wantsLayer = true
        layer?.cornerRadius = 6
        let dot = NSView(frame: NSRect(x: 8, y: 9, width: 6, height: 6))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = 3
        addSubview(dot)
        addSubview(panelLabel(text, size: 12.5, frame: NSRect(x: 22, y: 4, width: memX - 8 - 22, height: 16)))
        addSubview(panelLabel(memory, size: 11, mono: true, color: Pal.muted, align: .right,
                              frame: NSRect(x: memX, y: 5, width: memW, height: 14)))
        addSubview(cpuLabel)
        if let stopTag {
            let b = NSButton(frame: NSRect(x: width - 8 - 18, y: 3, width: 18, height: 18))
            b.image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in
                NSColor.white.setFill()
                NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
                return true
            }
            b.imagePosition = .imageOnly
            b.imageScaling = .scaleNone
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.backgroundColor = Pal.destructive.cgColor
            b.layer?.cornerRadius = 4
            b.toolTip = stopTip
            b.setAccessibilityLabel(stopLabel)
            b.tag = stopTag
            b.target = target
            b.action = action
            b.isHidden = true
            addSubview(b)
            stopButton = b
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = Pal.accent.cgColor
        if let stopButton { cpuLabel.isHidden = true; stopButton.isHidden = false }
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
        if let stopButton { cpuLabel.isHidden = false; stopButton.isHidden = true }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let notifier = Notifier()
    private let memory = physicalMemory()
    private var overSince: [pid_t: Date] = [:]
    private var orphanTracker = SustainedTracker<pid_t>()
    private var appRamTracker = SustainedTracker<String>()
    private var appCpuTracker = SustainedTracker<String>()
    private var closedAttempted = Set<pid_t>()
    private var pausedUntil: Date?
    private var lastSnap: Snapshot?
    private var idleTracker = SustainedTracker<String>()   // desde cuándo cada fila está con CPU < 1 %
    private var lastIdle: [String: TimeInterval] = [:]
    private var rowTargets: [KillTarget] = []
    private var panel: IslandPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var menuOpen = false
    private var cpuTotal: Double?
    private var cpuTicksPrev: (busy: UInt64, total: UInt64)?
    private var debugPanelShown = false
    private let agentURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(Config.agentLabel).plist")
    private var autoClose: Bool {
        get { UserDefaults.standard.bool(forKey: Config.autoCloseKey) }
        set { UserDefaults.standard.set(newValue, forKey: Config.autoCloseKey) }
    }
    private var aiEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Config.aiKey) }
        set { UserDefaults.standard.set(newValue, forKey: Config.aiKey) }
    }
    private var aiLoginFailed = false
    private var termSource: DispatchSourceSignal?
    private var lastAlert: [String: (date: Date, value: Double)] = [:]
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseUp])
        }
        // Limpieza única del directorio `pending/` de versiones anteriores (inofensiva si no existe).
        try? FileManager.default.removeItem(atPath: Config.supportDir + "/pending")
        _ = ensureRelay()
        // SIGTERM (p. ej. `brew services stop`): detiene el relay antes de salir.
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { [weak self] in self?.quit() }
        src.resume()
        termSource = src
        // Otra instancia (p. ej. la copia de ~/Applications abierta desde Spotlight) pide abrir el panel.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(showPanelNotification), object: nil, queue: .main) { [weak self] _ in
            self?.openPanel()
        }
        cpuTicksPrev = cpuTicks()   // base para que el primer sondeo ya muestre CPU total
        let wantsTest = CommandLine.arguments.contains("--notify-test")
        notifier.start { [weak self] in
            guard let self else { return }
            if wantsTest { self.notifier.send("Prueba: Guachiman puede notificarte") }
            self.poll()
        }
    }

    private func schedule(_ interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in self?.poll() }
        t.tolerance = interval * 0.1
        timer = t
    }

    @objc private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func poll() {
        // Releer el permiso en cada sondeo; el resto del ciclo corre con el valor actualizado.
        notifier.refresh { [weak self] in self?.runPoll() }
    }

    private func runPoll() {
        let snap = takeSnapshot()
        let now = Date()
        if let cur = cpuTicks() {
            if let prev = cpuTicksPrev { cpuTotal = cpuLoadPercent(prev: prev, cur: cur) }
            cpuTicksPrev = cur
        }
        let limit = UInt64(Double(memory) * Config.sessionFraction)

        // Inactividad: desde cuándo cada fila lleva con CPU < 1 % (y se olvidan las que desaparecen).
        var idle: [String: TimeInterval] = [:]
        func track(_ key: String, _ cpu: Double) {
            idle[key] = idleTracker.update(key, over: cpu < Config.idleCpuPercent, now: now)
        }
        for s in snap.sessions { track("session:\(s.pid)", s.cpu) }
        for o in snap.orphans { track("orphan:\(o.pid)", o.cpu) }
        for a in snap.apps { track(a.key, a.cpu) }
        idleTracker.retain(Set(idle.keys))
        lastIdle = idle

        // Sesiones por encima del umbral.
        var anyOver = false
        let livePids = Set(snap.sessions.map { $0.pid })
        overSince = overSince.filter { livePids.contains($0.key) }
        for s in snap.sessions {
            if s.bytes > limit {
                anyOver = true
                let since = overSince[s.pid] ?? now
                overSince[s.pid] = since
                if now.timeIntervalSince(since) >= Config.sessionSustained {
                    var text = "Sesión \(sessionLabel(s)) usa \(formatBytes(s.bytes)) (pid \(s.pid))"
                    if let t = s.top { text += " (mayor: \(t.cmd) \(formatBytes(t.bytes)))" }
                    if alert(key: "session:\(s.pid)", value: Double(s.bytes), text: text, now: now), aiEnabled {
                        appendAlert(sessionAlertLine(
                            ts: Int(now.timeIntervalSince1970), pid: s.pid, mb: s.bytes / 1_048_576,
                            limitMB: limit / 1_048_576, cwd: s.cwd, title: cachedSessionTitle(pid: s.pid), top: s.top))
                    }
                }
            } else {
                overSince[s.pid] = nil
            }
        }

        // Huérfanos: aviso a los 60 s, cierre opcional a los 10 min.
        var orphanOver = false
        let orphanPids = Set(snap.orphans.map { $0.pid })
        orphanTracker.retain(orphanPids)
        closedAttempted.formIntersection(orphanPids)
        for o in snap.orphans {
            let dur = orphanTracker.update(o.pid, over: o.bytes > Config.orphanBytes, now: now)
            guard o.bytes > Config.orphanBytes else { continue }
            if dur >= Config.orphanAlertAfter {
                orphanOver = true
                if alert(key: "orphan:\(o.pid)", value: Double(o.bytes),
                         text: "Huérfano \(o.name) usa \(formatBytes(o.bytes)) (pid \(o.pid))", now: now), aiEnabled {
                    appendAlert(orphanAlertLine(
                        ts: Int(now.timeIntervalSince1970), pid: o.pid, name: o.name, mb: o.bytes / 1_048_576,
                        limitMB: Config.orphanBytes / 1_048_576, cwd: currentDirectory(o.pid) ?? ""))
                }
            }
            if dur >= Config.orphanCloseAfter, autoClose, !pauseActive(until: pausedUntil, now: now),
               !closedAttempted.contains(o.pid) {
                closedAttempted.insert(o.pid)
                close(o)
            }
        }

        // Apps: RAM > 15% sostenida 60 s, CPU > 80% de un núcleo sostenida 120 s. Solo avisa, nunca cierra.
        var appOver = false
        let appKeys = Set(snap.apps.map { $0.key })
        appRamTracker.retain(appKeys)
        appCpuTracker.retain(appKeys)
        for a in snap.apps {
            if appRamTracker.update(a.key, over: a.bytes > limit, now: now) >= Config.sessionSustained {
                appOver = true
                alert(key: "appram:\(a.key)", value: Double(a.bytes),
                      text: "\(a.name) usa \(formatBytes(a.bytes)) de RAM", now: now)
            }
            if appCpuTracker.update(a.key, over: a.cpu > Config.appCpuPercent, now: now) >= Config.appCpuSustained {
                appOver = true
                alert(key: "appcpu:\(a.key)", value: a.cpu,
                      text: "\(a.name) usa \(Int(a.cpu.rounded())) % de CPU sostenido", now: now)
            }
        }
        pruneTitleCache(live: livePids)
        lastAlert = lastAlert.filter { k, _ in
            if k.hasPrefix("session:") { return livePids.contains(pid_t(k.dropFirst(8)) ?? -1) }
            if k.hasPrefix("orphan:") { return orphanPids.contains(pid_t(k.dropFirst(7)) ?? -1) }
            if k.hasPrefix("appram:") || k.hasPrefix("appcpu:") { return appKeys.contains(String(k.dropFirst(7))) }
            return true
        }

        // Memoria del sistema (el "valor" es la presión usada: crece cuando baja la libre).
        let systemLow = snap.freePercent < Config.systemFreeMinPercent
        if systemLow {
            let consumers = snap.sessions.prefix(2).map { (name: sessionLabel($0), bytes: $0.bytes) }
                + snap.apps.prefix(2).map { (name: $0.name, bytes: $0.bytes) }
            alert(key: "system", value: Double(100 - snap.freePercent),
                  text: systemLowText(freePercent: snap.freePercent, consumers: consumers), now: now)
        }

        updateUI(snap, alerting: anyOver || systemLow || orphanOver || appOver)
        schedule(Config.pollActive)
    }

    /// SIGTERM al huérfano y sus descendientes (hijos primero), tras reverificar con un snapshot nuevo.
    private func close(_ o: OrphanProc) {
        guard let fresh = takeSnapshot().orphans.first(where: { $0.pid == o.pid }), parentPid(o.pid) == 1 else { return }
        for pid in fresh.tree.reversed() { kill(pid, SIGTERM) }
        notifier.send("Cerrado huérfano \(fresh.name) (\(formatBytes(fresh.bytes)), pid \(fresh.pid))")
    }

    /// Devuelve true si la alerta realmente se disparó (no pausa, no enfriamiento).
    @discardableResult
    private func alert(key: String, value: Double, text: String, now: Date) -> Bool {
        guard !pauseActive(until: pausedUntil, now: now) else { return false }
        if let last = lastAlert[key] {
            let cooled = now.timeIntervalSince(last.date) >= Config.cooldown
            let grew = value > last.value * Config.regrowthFactor
            guard cooled || grew else { return false }
        }
        lastAlert[key] = (now, value)
        notifier.send(text)
        return true
    }

    @objc private func toggleAutoClose() { autoClose.toggle() }

    @objc private func togglePause() {
        pausedUntil = pauseActive(until: pausedUntil, now: Date()) ? nil : Date().addingTimeInterval(Config.pauseDuration)
    }

    @objc private func toggleLaunchAtLogin() {
        if FileManager.default.fileExists(atPath: agentURL.path) {
            try? FileManager.default.removeItem(at: agentURL)
        } else if let exe = Bundle.main.executablePath {
            try? FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(fromPropertyList: launchAgentPlist(executable: exe), format: .xml, options: 0) {
                try? data.write(to: agentURL)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { runRelay("stop", wait: true) }

    @objc private func quit() {
        runRelay("stop", wait: true)
        exit(0)
    }

    /// Con la IA activa y Claude Code con sesión, arranca el relay (idempotente). Devuelve false si falta la sesión.
    private func ensureRelay() -> Bool {
        guard aiEnabled, let claude = claudeBinary() else { return true }
        aiLoginFailed = !claudeLoggedIn(claude)
        if !aiLoginFailed { runRelay(nil, wait: false) }
        return !aiLoginFailed
    }

    @objc private func toggleAI(_ sender: NSButton) {
        aiEnabled.toggle()
        if aiEnabled {
            if !ensureRelay() { notifier.send(Config.loginText) }
        } else {
            aiLoginFailed = false
            runRelay("stop", wait: false)
        }
        if let p = panel { fillPanel(p) }
    }   // status 0: KeepAlive { SuccessfulExit = false } no relanza

    private func toggle(_ title: String, _ action: Selector, on: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    private func updateUI(_ snap: Snapshot, alerting: Bool) {
        lastSnap = snap
        if let p = panel { fillPanel(p) }   // el panel abierto se refresca con cada sondeo
        if CommandLine.arguments.contains("--show-panel"), !debugPanelShown {   // solo para verificar
            debugPanelShown = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.openPanel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self?.closePanel() }
            }
        }
        if let button = statusItem.button {
            // Ícono propio de 18 pt de alto; si no está en el bundle, usa el SF Symbol.
            let base: NSImage?
            if let custom = Bundle.main.image(forResource: "MenuBarIcon") {
                let ratio = custom.size.height > 0 ? custom.size.width / custom.size.height : 1
                custom.size = NSSize(width: 18 * ratio, height: 18)
                base = custom
            } else {
                base = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "Guachiman")
            }
            base?.isTemplate = true
            if alerting {
                // Un bitmap no acepta paletas de SF Symbols: se pinta una copia roja no plantilla.
                let image = base.map { src -> NSImage in
                    let red = NSImage(size: src.size, flipped: false) { rect in
                        src.draw(in: rect)
                        NSColor.systemRed.set()
                        rect.fill(using: .sourceAtop)
                        return true
                    }
                    red.isTemplate = false
                    return red
                }
                button.image = image
                button.alphaValue = 1
            } else {
                button.image = base
                button.alphaValue = snap.sessions.isEmpty ? 0.4 : 1
            }
        }
    }

    // MARK: Panel isla (se crea al abrir, se libera por completo al cerrar)

    private func nsColor(_ c: RowColor) -> NSColor {
        switch c {
        case .green: return Pal.primary
        case .yellow: return .systemYellow
        case .red: return Pal.destructive
        case .gray: return Pal.muted
        }
    }

    @objc private func togglePanel() { panel == nil ? openPanel() : closePanel() }

    private func openPanel() {
        guard panel == nil, statusItem.button?.window != nil else { return }
        let p = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 170),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.appearance = NSAppearance(named: .darkAqua)
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel = p
        if aiEnabled, aiLoginFailed { _ = ensureRelay() }   // reintento solo al abrir el panel
        fillPanel(p)
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] e in
            guard let self, let p = self.panel, !self.menuOpen else { return e }
            if e.type == .keyDown {
                if e.keyCode == 53 { self.closePanel(); return nil }   // Esc
            } else if e.window !== p, e.window !== self.statusItem.button?.window {
                self.closePanel()
            }
            return e
        }
    }

    private func closePanel() {
        guard let p = panel else { return }
        panel = nil
        rowTargets = []
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; p.animator().alphaValue = 0 }, completionHandler: {
            p.orderOut(nil)
            p.contentView = nil
        })
    }

    /// Reconstruye el contenido a partir del último snapshot y recoloca el panel bajo el ícono.
    private func fillPanel(_ p: IslandPanel) {
        let snap = lastSnap ?? Snapshot(sessions: [], orphans: [], apps: [], freePercent: 100)
        let W: CGFloat = 300, pad: CGFloat = 6, iw = W - 2 * pad, rowH = PanelRow.height
        let limit = UInt64(Double(memory) * Config.sessionFraction)
        let sessions = Array(snap.sessions.prefix(8))
        let orphans = Array(snap.orphans.prefix(4))
        let apps = Array(snap.apps.prefix(5))
        let notice = aiEnabled && aiLoginFailed

        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: W, height: 100))
        root.wantsLayer = true
        root.layer?.backgroundColor = Pal.popover.cgColor
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 0.5
        root.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor

        var y = pad

        // Cabecera: dos medidores y los botones IA / ajustes.
        let btnW: CGFloat = 22 * 2 + 2
        let meterW = (iw - 16 - btnW - 24) / 2
        func meter(_ x: CGFloat, _ label: String, _ value: String, _ fraction: Double, _ fill: NSColor, _ a11y: String) {
            root.addSubview(panelLabel(label, size: 11, color: Pal.muted, frame: NSRect(x: x, y: y + 8, width: meterW - 30, height: 14)))
            root.addSubview(panelLabel(value, size: 12, weight: .semibold, mono: true, align: .right,
                                       frame: NSRect(x: x + meterW - 30, y: y + 8, width: 30, height: 14)))
            let track = NSView(frame: NSRect(x: x, y: y + 8 + 14 + 5, width: meterW, height: 4))
            track.wantsLayer = true
            track.layer?.backgroundColor = Pal.accent.cgColor
            track.layer?.cornerRadius = 2
            track.setAccessibilityElement(true)
            track.setAccessibilityRole(.image)
            track.setAccessibilityLabel(a11y)
            let bar = NSView(frame: NSRect(x: 0, y: 0, width: meterW * CGFloat(max(0, min(1, fraction))), height: 4))
            bar.wantsLayer = true
            bar.layer?.backgroundColor = fill.cgColor
            bar.layer?.cornerRadius = 2
            track.addSubview(bar)
            root.addSubview(track)
        }
        meter(pad + 8, "Memoria libre", "\(snap.freePercent)%", Double(snap.freePercent) / 100,
              nsColor(freeMemoryColor(freePercent: snap.freePercent)), "Memoria libre \(snap.freePercent) %")
        meter(pad + 8 + meterW + 12, "CPU", cpuTotal.map { "\(Int($0.rounded()))%" } ?? "—", (cpuTotal ?? 0) / 100,
              Pal.primary, cpuTotal.map { "CPU \(Int($0.rounded())) %" } ?? "CPU no disponible")

        let bx = pad + iw - 8 - btnW
        let by = y + 8 + (23 - 22) / 2
        let ai = HoverButton(frame: NSRect(x: bx, y: by, width: 22, height: 22))
        let hasClaude = claudeBinary() != nil
        let aiColor: NSColor = !hasClaude || !aiEnabled ? Pal.muted.withAlphaComponent(0.5)
            : (aiLoginFailed ? .systemYellow : Pal.foreground)
        ai.attributedTitle = NSAttributedString(string: "IA", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: aiColor])
        ai.isBordered = false
        ai.wantsLayer = true
        ai.layer?.cornerRadius = 5
        ai.isEnabled = hasClaude
        ai.toolTip = !hasClaude ? "Claude Code no está instalado"
            : (notice ? Config.loginText : "IA: avisar a la sesión de Claude dueña (enlace con Haiku)")
        ai.setAccessibilityLabel("IA: avisar a la sesión de Claude dueña (enlace con Haiku)")
        ai.target = self
        ai.action = #selector(toggleAI(_:))
        root.addSubview(ai)
        let gear = HoverButton(frame: NSRect(x: bx + 24, y: by, width: 22, height: 22))
        gear.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        gear.imagePosition = .imageOnly
        gear.isBordered = false
        gear.wantsLayer = true
        gear.layer?.cornerRadius = 5
        gear.contentTintColor = Pal.muted
        gear.toolTip = "Ajustes"
        gear.setAccessibilityLabel("Ajustes")
        gear.target = self
        gear.action = #selector(showSettings(_:))
        root.addSubview(gear)
        y += 8 + 23 + 10 + 2

        if notice {
            let l = NSTextField(wrappingLabelWithString: Config.loginText)
            l.font = NSFont.systemFont(ofSize: 11)
            l.textColor = .systemYellow
            l.frame = NSRect(x: pad + 8, y: y, width: iw - 16, height: 30)
            root.addSubview(l)
            y += 30 + 2
        }

        func divider(topMargin: CGFloat) {
            y += topMargin
            let d = NSView(frame: NSRect(x: pad + 8, y: y, width: iw - 16, height: 0.5))
            d.wantsLayer = true
            d.layer?.backgroundColor = Pal.border.cgColor
            root.addSubview(d)
            y += 0.5 + 2
        }
        func section(_ title: String, total: String? = nil) {
            root.addSubview(panelLabel(title, size: 11, weight: .semibold, color: Pal.muted,
                                       frame: NSRect(x: pad + 8, y: y + 8, width: iw - 16 - 80, height: 14)))
            if let total {
                root.addSubview(panelLabel(total, size: 11, mono: true, color: Pal.muted, align: .right,
                                           frame: NSRect(x: pad + iw - 8 - 80, y: y + 8, width: 80, height: 14)))
            }
            y += 8 + 14 + 4 + 2
        }

        rowTargets = []
        func addRow(_ text: String, _ bytes: UInt64, _ cpu: Double, _ color: RowColor, _ t: KillTarget, tip: String) {
            var tag: Int?
            if !t.pids.isEmpty, !t.pids.contains(getpid()) {   // nunca ofrece cerrar a Guachiman
                rowTargets.append(t)
                tag = rowTargets.count - 1
            }
            let r = PanelRow(width: iw, text: text, memory: formatBytes(bytes), cpu: "\(Int(cpu.rounded()))%",
                             color: nsColor(color), stopTag: tag, stopLabel: "Cerrar \(t.name)", stopTip: tip,
                             target: self, action: #selector(stopClicked(_:)))
            r.frame.origin = NSPoint(x: pad, y: y)
            root.addSubview(r)
            y += rowH
        }

        divider(topMargin: 0)
        section("Sesiones de Claude", total: sessions.isEmpty ? nil : formatBytes(sessions.reduce(0) { $0 + $1.bytes }))
        if sessions.isEmpty {
            root.addSubview(panelLabel("Sin sesiones de Claude", size: 12.5, color: Pal.muted,
                                       frame: NSRect(x: pad + 8, y: y + 4, width: iw - 16, height: 16)))
            y += rowH
        }
        for s in sessions {
            let c = rowColor(bytes: s.bytes, cpu: s.cpu, ramLimit: limit, cpuLimit: Config.appCpuPercent,
                             idleFor: lastIdle["session:\(s.pid)"] ?? 0)
            let title = sessionTitle(pid: s.pid).map(truncatedTitle)
            addRow(title ?? s.label, s.bytes, s.cpu, c,
                   KillTarget(name: title ?? "Claude (\(s.label))", bytes: s.bytes, pids: s.tree, appPath: nil, expandTree: false),
                   tip: "Detener")
        }

        divider(topMargin: 2)
        section("Apps que más consumen")
        for a in apps {
            let c = rowColor(bytes: a.bytes, cpu: a.cpu, ramLimit: limit, cpuLimit: Config.appCpuPercent,
                             idleFor: lastIdle[a.key] ?? 0)
            let single = a.key.hasPrefix("pid:")
            addRow(a.name, a.bytes, a.cpu, c,
                   KillTarget(name: a.name, bytes: a.bytes, pids: a.pids, appPath: single ? nil : a.key, expandTree: single),
                   tip: "Cerrar app")
        }
        if !orphans.isEmpty {
            divider(topMargin: 2)
            section("Huérfanos")
            for o in orphans {
                let c = rowColor(bytes: o.bytes, cpu: o.cpu, ramLimit: Config.orphanBytes, cpuLimit: nil,
                                 idleFor: lastIdle["orphan:\(o.pid)"] ?? 0)
                addRow(o.name, o.bytes, o.cpu, c,
                       KillTarget(name: o.name, bytes: o.bytes, pids: o.tree, appPath: nil, expandTree: false),
                       tip: "Detener")
            }
        }

        let H = y + 4 + pad
        root.frame.size = NSSize(width: W, height: H)
        p.contentView = root
        // Centrado bajo el ícono y recortado a la zona visible de la pantalla.
        if let button = statusItem.button, let win = button.window {
            let r = win.convertToScreen(button.convert(button.bounds, to: nil))
            let vf = (win.screen ?? NSScreen.main)?.visibleFrame ?? r
            let x = max(vf.minX + 8, min(r.midX - W / 2, vf.maxX - W - 8))
            p.setFrame(NSRect(x: x, y: max(vf.minY, r.minY - 6 - H), width: W, height: H), display: true)
            p.invalidateShadow()
        }
    }

    @objc private func showSettings(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if pauseActive(until: pausedUntil, now: Date()), let until = pausedUntil {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            menu.addItem(toggle("Reanudar (pausado hasta \(f.string(from: until)))", #selector(togglePause), on: false))
        } else {
            menu.addItem(toggle("Pausar 1 h", #selector(togglePause), on: false))
        }
        menu.addItem(toggle("Cerrar huérfanos automáticamente", #selector(toggleAutoClose), on: autoClose))
        menu.addItem(toggle("Iniciar al encender", #selector(toggleLaunchAtLogin),
                            on: FileManager.default.fileExists(atPath: agentURL.path)))
        if !notifier.isAuthorized {
            let item = NSMenuItem(title: "Activar notificaciones…", action: #selector(openNotificationSettings), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Salir", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        menuOpen = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        menuOpen = false
    }

    @objc private func stopClicked(_ sender: NSButton) {
        guard rowTargets.indices.contains(sender.tag) else { return }
        let t = rowTargets[sender.tag]
        closePanel()
        DispatchQueue.main.async { [weak self] in self?.confirmClose(t) }
    }

    private func confirmClose(_ t: KillTarget) {
        let live = t.pids.filter(alive)
        guard !live.isEmpty else { return }
        let shown = live.prefix(6).map(String.init).joined(separator: ", ")
        let pidText = (live.count == 1 ? "pid " : "pids ") + shown + (live.count > 6 ? " y \(live.count - 6) más" : "")
        let alert = NSAlert()
        alert.messageText = "¿Cerrar \(t.name)?"
        alert.informativeText = "\(formatBytes(t.bytes)) · \(pidText)"
        alert.addButton(withTitle: "Cerrar")
        alert.addButton(withTitle: "Cancelar")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        terminate(t)
    }

    private func terminate(_ t: KillTarget) {
        var apps: [NSRunningApplication] = []
        if let path = t.appPath {
            let want = path.hasSuffix("/") ? String(path.dropLast()) : path
            apps = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == want }
        }
        let targets: [pid_t]   // en el orden en que se señalan (hijos primero)
        if !apps.isEmpty {
            apps.forEach { $0.terminate() }
            targets = apps.map { $0.processIdentifier }
        } else {
            let tree = t.expandTree ? t.pids.flatMap { liveTree($0) } : t.pids
            targets = t.appPath == nil ? tree.reversed() : tree
            for pid in targets where alive(pid) { kill(pid, SIGTERM) }
        }
        let closing = apps
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            let left = targets.filter(alive)
            guard !left.isEmpty else { return }
            let alert = NSAlert()
            alert.messageText = "\(t.name) sigue abierto. ¿Forzar cierre?"
            alert.addButton(withTitle: "Forzar")
            alert.addButton(withTitle: "Cancelar")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if !closing.isEmpty {
                closing.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
            } else {
                for pid in left where alive(pid) { kill(pid, SIGKILL) }
            }
        }
    }
}

// MARK: - Copia en ~/Applications

let showPanelNotification = "io.github.guachiman.showPanel"

/// Homebrew deja la app en Cellar, que Spotlight/Launchpad no indexan: se copia a ~/Applications.
/// Solo reemplaza un bundle propio (mismo identificador) cuya versión difiere; los errores se ignoran.
func installCopyInApplications() {
    let fm = FileManager.default
    let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    let target = dir.appendingPathComponent("Guachiman.app")
    let src = Bundle.main.bundleURL
    guard src.pathExtension == "app", src.standardizedFileURL.path != target.standardizedFileURL.path else { return }
    func info(_ url: URL) -> [String: Any]? {
        NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
    }
    let mine = Bundle.main.infoDictionary
    if fm.fileExists(atPath: target.path) {
        guard let theirs = info(target),
              theirs["CFBundleIdentifier"] as? String == mine?["CFBundleIdentifier"] as? String else { return }
        if theirs["CFBundleVersion"] as? String == mine?["CFBundleVersion"] as? String { return }
    }
    do {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: src, to: target)
    } catch {
        FileHandle.standardError.write(Data("guachiman: no se pudo copiar a ~/Applications: \(error)\n".utf8))
    }
}

// MARK: - Main

if CommandLine.arguments.contains("--once") {
    runOnce()
    exit(0)
}

if CommandLine.arguments.contains("--selftest") {
    runSelfTest()
    exit(0)
}

// Instancia única: si ya corre otra app con el mismo bundle id, pedirle que abra su panel y salir.
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id)
       .contains(where: { $0.processIdentifier != getpid() }) {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name(showPanelNotification), object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

installCopyInApplications()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
