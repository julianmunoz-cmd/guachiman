// Guachiman — menu bar app que vigila la RAM y la CPU de todas las apps, además de
// las sesiones de Claude Code y los procesos huérfanos.
// Por defecto es de solo lectura. Solo envía SIGTERM a procesos huérfanos
// (ppid 1: node, vitest, next, playwright) si el usuario activa "Cerrar huérfanos
// automáticamente" en el menú (apagado de fábrica); nunca toca sesiones de Claude.

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
    static let pauseDuration: TimeInterval = 3600
    static let autoCloseKey = "autoCloseOrphans"
    static let agentLabel = "io.github.guachiman"
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

func runSelfTest() {
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
    print("selftest OK")
}

// MARK: - Lectura de procesos (libproc / sysctl)

struct Session {
    let pid: pid_t
    let label: String
    let cwd: String
    let bytes: UInt64
}

struct OrphanProc {
    let pid: pid_t
    let name: String
    let bytes: UInt64
    let tree: [pid_t]   // el huérfano y todos sus descendientes
}

struct AppUsage {
    let key: String
    let name: String
    var bytes: UInt64 = 0
    var cpu = 0.0   // % de un núcleo
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

func residentSize(_ pid: pid_t) -> UInt64? { taskInfo(pid)?.pti_resident_size }

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
        let total = pids.reduce(UInt64(0)) { $0 + (residentSize($1) ?? 0) }
        let cwd = currentDirectory(root) ?? ""
        let label = cwd.isEmpty ? "?" : (cwd as NSString).lastPathComponent
        sessions.append(Session(pid: root, label: label, cwd: cwd, bytes: total))
    }
    sessions.sort { $0.bytes > $1.bytes }

    // Huérfanos: ppid 1, nombre conocido, fuera de (y sin claude dentro de) árboles de sesión.
    var orphans: [OrphanProc] = []
    for (pid, ppid) in parents where ppid == 1 && !claudePids.contains(pid) && !sessionPids.contains(pid) {
        guard let name = Orphan.name(exe: executablePath(pid), argv0: argv0(pid)) else { continue }
        let pids = tree(pid)
        if !sessionPids.isDisjoint(with: pids) { continue }
        orphans.append(OrphanProc(pid: pid, name: name,
                                  bytes: pids.reduce(UInt64(0)) { $0 + (residentSize($1) ?? 0) }, tree: pids))
    }
    orphans.sort { $0.bytes > $1.bytes }

    // Apps: todo lo que no es sesión ni huérfano, agrupado por .app. La primera lectura de un pid da CPU 0.
    let sampledAt = Date()
    let wall = cpuPrevAt.map { sampledAt.timeIntervalSince($0) } ?? 0
    let excluded = sessionPids.union(orphans.flatMap { $0.tree })
    var cpuNow: [pid_t: UInt64] = [:]
    var groups: [String: AppUsage] = [:]
    for pid in parents.keys where !excluded.contains(pid) {
        guard let ti = taskInfo(pid) else { continue }
        let ticks = ti.pti_total_user + ti.pti_total_system
        cpuNow[pid] = ticks
        let path = executablePath(pid)
        let g = appGroup(path: path, argv0: path == nil ? argv0(pid) : nil, pid: pid)
        groups[g.key, default: AppUsage(key: g.key, name: g.name)].bytes += ti.pti_resident_size
        if let prev = cpuPrev[pid] {
            groups[g.key]!.cpu += cpuPercent(prev: prev, cur: ticks, wall: wall, timebase: timebase)
        }
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
    print("PID\tETIQUETA\tTOTAL_MB\tCWD")
    for s in snap.sessions {
        print("\(s.pid)\t\(s.label)\t\(s.bytes / 1_048_576)\t\(s.cwd)")
    }
    if snap.sessions.isEmpty { print("(sin sesiones de Claude)") }
    print("")
    print("Candidatos a huérfano (pid\tnombre\tMB)")
    for o in snap.orphans { print("\(o.pid)\t\(o.name)\t\(o.bytes / 1_048_576)") }
    if snap.orphans.isEmpty { print("(ninguno)") }
    print("")
    print("Apps (nombre\tMB\tCPU %)")
    for a in snap.apps.prefix(10) { print("\(a.name)\t\(a.bytes / 1_048_576)\t\(Int(a.cpu.rounded()))") }
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
    private var lastAlerting = false
    private let agentURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(Config.agentLabel).plist")
    private var autoClose: Bool {
        get { UserDefaults.standard.bool(forKey: Config.autoCloseKey) }
        set { UserDefaults.standard.set(newValue, forKey: Config.autoCloseKey) }
    }
    private var lastAlert: [String: (date: Date, value: Double)] = [:]
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        let limit = UInt64(Double(memory) * Config.sessionFraction)

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
                    let text = "Sesión \(s.label) usa \(formatBytes(s.bytes)) (pid \(s.pid))"
                    alert(key: "session:\(s.pid)", value: Double(s.bytes), text: text, now: now)
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
                alert(key: "orphan:\(o.pid)", value: Double(o.bytes),
                      text: "Huérfano \(o.name) usa \(formatBytes(o.bytes)) (pid \(o.pid))", now: now)
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
        lastAlert = lastAlert.filter { k, _ in
            if k.hasPrefix("session:") { return livePids.contains(pid_t(k.dropFirst(8)) ?? -1) }
            if k.hasPrefix("orphan:") { return orphanPids.contains(pid_t(k.dropFirst(7)) ?? -1) }
            if k.hasPrefix("appram:") || k.hasPrefix("appcpu:") { return appKeys.contains(String(k.dropFirst(7))) }
            return true
        }

        // Memoria del sistema (el "valor" es la presión usada: crece cuando baja la libre).
        let systemLow = snap.freePercent < Config.systemFreeMinPercent
        if systemLow {
            alert(key: "system", value: Double(100 - snap.freePercent),
                  text: "Memoria libre baja: \(snap.freePercent)%", now: now)
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

    private func alert(key: String, value: Double, text: String, now: Date) {
        guard !pauseActive(until: pausedUntil, now: now) else { return }
        if let last = lastAlert[key] {
            let cooled = now.timeIntervalSince(last.date) >= Config.cooldown
            let grew = value > last.value * Config.regrowthFactor
            guard cooled || grew else { return }
        }
        lastAlert[key] = (now, value)
        notifier.send(text)
    }

    @objc private func toggleAutoClose() { autoClose.toggle(); refreshMenu() }

    @objc private func togglePause() {
        pausedUntil = pauseActive(until: pausedUntil, now: Date()) ? nil : Date().addingTimeInterval(Config.pauseDuration)
        refreshMenu()
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
        refreshMenu()
    }

    @objc private func quit() { exit(0) }   // status 0: KeepAlive { SuccessfulExit = false } no relanza

    private func refreshMenu() { if let s = lastSnap { updateUI(s, alerting: lastAlerting) } }

    private func toggle(_ title: String, _ action: Selector, on: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    private func updateUI(_ snap: Snapshot, alerting: Bool) {
        lastSnap = snap
        lastAlerting = alerting
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

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(disabled("Memoria libre: \(snap.freePercent)%"))
        if snap.sessions.isEmpty {
            menu.addItem(disabled("Sin sesiones de Claude"))
        } else {
            for s in snap.sessions {
                menu.addItem(disabled("\(s.label) — \(formatBytes(s.bytes)) (pid \(s.pid))"))
            }
        }
        for o in snap.orphans {
            menu.addItem(disabled("Huérfano \(o.name) — \(formatBytes(o.bytes)) (pid \(o.pid))"))
        }
        menu.addItem(.separator())
        menu.addItem(disabled("Apps que más consumen"))
        for a in snap.apps.prefix(5) {
            menu.addItem(disabled("\(a.name) — \(formatBytes(a.bytes)) · \(Int(a.cpu.rounded())) % CPU"))
        }
        if !notifier.isAuthorized {
            let item = NSMenuItem(title: "Activar notificaciones…", action: #selector(openNotificationSettings), keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let now = Date()
        if pauseActive(until: pausedUntil, now: now), let until = pausedUntil {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            menu.addItem(toggle("Reanudar (pausado hasta \(f.string(from: until)))", #selector(togglePause), on: false))
        } else {
            menu.addItem(toggle("Pausar 1 h", #selector(togglePause), on: false))
        }
        menu.addItem(toggle("Cerrar huérfanos automáticamente", #selector(toggleAutoClose), on: autoClose))
        menu.addItem(toggle("Iniciar al encender", #selector(toggleLaunchAtLogin),
                            on: FileManager.default.fileExists(atPath: agentURL.path)))
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Salir", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
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

// Instancia única: si ya corre otra app con el mismo bundle id, salir sin error.
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id)
       .contains(where: { $0.processIdentifier != getpid() }) {
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
