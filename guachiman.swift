// Guachiman — menu bar app que vigila la RAM de las sesiones de Claude Code.
// Solo lectura: nunca mata ni envía señales a procesos.

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
    static let pollActive: TimeInterval = 20     // con >= 1 sesión
    static let pollIdle: TimeInterval = 60       // sin sesiones
    static let sessionExecutable = "claude"
}

// MARK: - Lectura de procesos (libproc / sysctl)

struct Session {
    let pid: pid_t
    let label: String
    let cwd: String
    let bytes: UInt64
}

struct Snapshot {
    let sessions: [Session]   // ordenadas por RAM desc
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

func residentSize(_ pid: pid_t) -> UInt64? {
    var info = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
    return info.pti_resident_size
}

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

    var sessions: [Session] = []
    for root in roots {
        var total: UInt64 = 0
        var stack = [root]
        var seen = Set<pid_t>()
        while let pid = stack.popLast() {
            guard seen.insert(pid).inserted else { continue }
            total += residentSize(pid) ?? 0
            stack.append(contentsOf: children[pid] ?? [])
        }
        let cwd = currentDirectory(root) ?? ""
        let label = cwd.isEmpty ? "?" : (cwd as NSString).lastPathComponent
        sessions.append(Session(pid: root, label: label, cwd: cwd, bytes: total))
    }
    sessions.sort { $0.bytes > $1.bytes }
    return Snapshot(sessions: sessions, freePercent: freeMemoryPercent())
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
    let snap = takeSnapshot()
    let mem = physicalMemory()
    let limit = UInt64(Double(mem) * Config.sessionFraction)
    print("PID\tETIQUETA\tTOTAL_MB\tCWD")
    for s in snap.sessions {
        print("\(s.pid)\t\(s.label)\t\(s.bytes / 1_048_576)\t\(s.cwd)")
    }
    if snap.sessions.isEmpty { print("(sin sesiones de Claude)") }
    print("")
    print("Memoria libre: \(snap.freePercent)%")
    print("RAM física: \(mem / 1_048_576) MB")
    print("Umbral de sesión: \(limit / 1_048_576) MB (\(Int(Config.sessionFraction * 100))% de la RAM, sostenido \(Int(Config.sessionSustained)) s)")
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
        lastAlert = lastAlert.filter { !$0.key.hasPrefix("session:") || livePids.contains(pid_t($0.key.dropFirst(8)) ?? -1) }

        // Memoria del sistema (el "valor" es la presión usada: crece cuando baja la libre).
        let systemLow = snap.freePercent < Config.systemFreeMinPercent
        if systemLow {
            alert(key: "system", value: Double(100 - snap.freePercent),
                  text: "Memoria libre baja: \(snap.freePercent)%", now: now)
        }

        updateUI(snap, alerting: anyOver || systemLow)
        schedule(snap.sessions.isEmpty ? Config.pollIdle : Config.pollActive)
    }

    private func alert(key: String, value: Double, text: String, now: Date) {
        if let last = lastAlert[key] {
            let cooled = now.timeIntervalSince(last.date) >= Config.cooldown
            let grew = value > last.value * Config.regrowthFactor
            guard cooled || grew else { return }
        }
        lastAlert[key] = (now, value)
        notifier.send(text)
    }

    private func updateUI(_ snap: Snapshot, alerting: Bool) {
        if let button = statusItem.button {
            let base = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "Guachiman")
            if alerting {
                let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
                let image = base?.withSymbolConfiguration(config)
                image?.isTemplate = false
                button.image = image
                button.alphaValue = 1
            } else {
                base?.isTemplate = true
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
        if !notifier.isAuthorized {
            let item = NSMenuItem(title: "Activar notificaciones…", action: #selector(openNotificationSettings), keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
