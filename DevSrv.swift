import Cocoa

// =======================================================
// DevSrv.swift — menubar Dev server manager (localhost only)
// - Embedded Caddy (Contents/Resources/caddy)
// - Per-site "Use without port" toggle:
//     OFF => https://localhost:8443   (no admin)
//     ON  => https://localhost        (requires admin; LaunchDaemon)
// - Single active site at a time (served=true) to avoid localhost conflicts
// =======================================================


// MARK: - Models

enum SiteMode: String, Codable {
    case localhost
    case domain
}

struct Site: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var shortcutLabel: String
    var folder: String

    var mode: SiteMode          // NEW
    var domain: String          // NEW (np. familiada.test)
    var port: Int?              // NEW (np. 5173)

    var served: Bool
    var shortcut: Bool

    mutating func normalize() {
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        shortcutLabel = shortcutLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        folder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        domain = domain.trimmingCharacters(in: .whitespacesAndNewlines)

        if shortcutLabel.isEmpty { shortcutLabel = name }
        if name.isEmpty { name = shortcutLabel.isEmpty ? "Site" : shortcutLabel }

        if mode == .localhost, port == nil {
            port = 3000
        }
        if mode == .domain {
            port = nil
        }
    }

    func urlString() -> String {
        switch mode {
        case .localhost:
            return "https://localhost:\(port ?? 3000)"
        case .domain:
            return "https://\(domain)"
        }
    }
}

enum SiteStatus: String { case off = "Off", on = "On", error = "Error", unknown = "Unknown" }
enum CaddyState: String { case running = "Running", stopped = "Stopped", unknown = "Unknown" }

struct CmdResult {
    let code: Int32
    let out: String
    let err: String
}


// MARK: - Paths

enum Paths {

    static func appSupportDir() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("DevSrv", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func sitesJson() -> URL { appSupportDir().appendingPathComponent("sites.json") }
    static func caddyfileGenerated() -> URL { appSupportDir().appendingPathComponent("Caddyfile.generated") }

    static func accessLog() -> URL { appSupportDir().appendingPathComponent("caddy-access.log") }
    static func errLog() -> URL { appSupportDir().appendingPathComponent("caddy-error.log") }

    // User-mode PID file for background Caddy (port 8443)
    static func userPidFile() -> URL { appSupportDir().appendingPathComponent("caddy-user.pid") }

    // LaunchDaemon identifiers / paths (root-mode, port 443)
    static func daemonLabel() -> String { "devsrv.caddy" }
    static func daemonPlistPath() -> String { "/Library/LaunchDaemons/devsrv.caddy.plist" }

    static func embeddedCaddyPath() -> String? {
        // expects Contents/Resources/caddy
        guard let res = Bundle.main.resourceURL else { return nil }
        let p = res.appendingPathComponent("caddy").path
        return p
    }
}


// MARK: - Shell

enum Shell {
    static func run(_ bin: String, _ args: [String], timeoutSec: Double = 8) -> CmdResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        do { try p.run() }
        catch { return CmdResult(code: 127, out: "", err: "Cannot run \(bin): \(error)") }

        let deadline = Date().addingTimeInterval(timeoutSec)
        while p.isRunning && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()

        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CmdResult(code: p.terminationStatus, out: out, err: err)
    }

    static func runAsAdmin(_ script: String) -> CmdResult {
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let osa = "do shell script \"\(escaped)\" with administrator privileges"
        return run("/usr/bin/osascript", ["-e", osa], timeoutSec: 60)
    }
}


// MARK: - Window center helper

@inline(__always)
func centerWindow(_ w: NSWindow) {
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
        let f = screen.visibleFrame
        let size = w.frame.size
        let x = f.origin.x + (f.size.width - size.width) / 2
        let y = f.origin.y + (f.size.height - size.height) / 2
        w.setFrameOrigin(NSPoint(x: x, y: y))
    } else {
        w.center()
    }
}


// MARK: - Store

final class Store {
    private(set) var sites: [Site] = []
    private let fm = FileManager.default

    var lastError: String? = nil
    var lastInfo: String? = nil

    init() { loadSites() }

    func loadSites() {
        lastError = nil
        lastInfo = nil

        let url = Paths.sitesJson()
        guard fm.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            sites = []
            return
        }

        // New format
        if let decoded = try? JSONDecoder().decode([Site].self, from: data) {
            sites = decoded.map { var s = $0; s.normalize(); return s }
            saveSites()
            return
        }

        // Recovery from older schemas (your previous Site had domain/tld/prefix etc.)
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            sites = []
            lastError = "Cannot decode sites.json (unknown format)"
            return
        }

        var recovered: [Site] = []
        for obj in arr {
            let id = (obj["id"] as? String) ?? UUID().uuidString
            let name = (obj["name"] as? String) ?? ""
            let folder = (obj["folder"] as? String) ?? ""
            let served = (obj["served"] as? Bool) ?? (obj["enabled"] as? Bool) ?? false
            let shortcut = (obj["shortcut"] as? Bool) ?? false
            let shortcutLabel = (obj["shortcutLabel"] as? String) ?? (obj["label"] as? String) ?? name

            // If older schema had something like "port"/"withoutPort" keep it, else false
            let withoutPort = (obj["withoutPort"] as? Bool) ?? false

            var s = Site(
                id: id,
                name: name,
                shortcutLabel: shortcutLabel,
                folder: folder,
                served: served,
                shortcut: shortcut,
                withoutPort: withoutPort
            )
            s.normalize()
            recovered.append(s)
        }

        sites = recovered.sorted { $0.name.lowercased() < $1.name.lowercased() }
        saveSites()
        lastInfo = "Recovered sites.json schema"
    }

    func saveSites() {
        let url = Paths.sitesJson()
        do {
            let data = try JSONEncoder().encode(sites)
            try data.write(to: url, options: .atomic)
        } catch {
            lastError = "Cannot save sites.json: \(error)"
        }
    }

    func upsert(_ site: Site) {
        var s = site
        s.normalize()

        if let idx = sites.firstIndex(where: { $0.id == s.id }) {
            sites[idx] = s
        } else {
            sites.append(s)
        }
        sites.sort { $0.name.lowercased() < $1.name.lowercased() }
        saveSites()
        lastInfo = "Saved"
    }

    func remove(id: String) {
        sites.removeAll { $0.id == id }
        saveSites()
        lastInfo = "Removed"
    }

    func indexHtmlExists(for site: Site) -> Bool {
        let p = URL(fileURLWithPath: site.folder).appendingPathComponent("index.html").path
        return fm.fileExists(atPath: p)
    }

    func servedSites() -> [Site] {
        sites.filter { $0.served }
    }

    func generateCaddyfile() {
        lastError = nil
    
        var lines: [String] = [
            "{",
            "  admin 127.0.0.1:2019",
            "}",
            "",
            "# GENERATED — do not edit",
            ""
        ]
    
        let access = Paths.accessLog().path.replacingOccurrences(of: "\"", with: "\\\"")
    
        let active = servedSites()
        if active.isEmpty {
            lines.append("localhost:8443 { respond \"DevSrv: no active sites\" 200 }")
        }
    
        for s in active {
            let root = s.folder.replacingOccurrences(of: "\"", with: "\\\"")
    
            let host: String
            switch s.mode {
            case .localhost:
                host = "localhost:\(s.port ?? 3000)"
            case .domain:
                host = s.domain
            }
    
            lines += [
                "\(host) {",
                "  tls internal",
                "  root * \"\(root)\"",
                "  file_server",
                "  log {",
                "    output file \"\(access)\"",
                "  }",
                "}",
                ""
            ]
        }
    
        do {
            try lines.joined(separator: "\n")
                .data(using: .utf8)!
                .write(to: Paths.caddyfileGenerated(), options: .atomic)
            lastInfo = "Caddyfile generated"
        } catch {
            lastError = "Cannot write Caddyfile: \(error)"
        }
    }
}


// MARK: - Caddy Service

final class CaddyService {
    private let store: Store

    init(store: Store) { self.store = store }

    private func caddyPathOrError() -> String? {
        guard let p = Paths.embeddedCaddyPath() else { return nil }
        if FileManager.default.fileExists(atPath: p) { return p }
        return nil
    }

    func caddyVersion() -> String {
        guard let caddy = caddyPathOrError() else { return "(embedded caddy missing)" }
        let r = Shell.run(caddy, ["version"], timeoutSec: 3)
        let s = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? r.err.trimmingCharacters(in: .whitespacesAndNewlines) : s
    }

    func adminAlive() -> Bool {
        let r = Shell.run("/usr/bin/curl", ["-s", "http://127.0.0.1:2019/config/", "--max-time", "1"], timeoutSec: 2)
        return r.code == 0
    }

    func state() -> CaddyState {
            if adminAlive() { return .running }
    
            // Check LaunchDaemon (root mode)
            let r = Shell.run("/bin/launchctl", ["print", "system/\(Paths.daemonLabel())"], timeoutSec: 2)
            if r.code == 0, r.out.contains("state = running") { return .running }
    
            // Check user pid file (best-effort)
            if FileManager.default.fileExists(atPath: Paths.userPidFile().path) {
                return .unknown
            }
            return .stopped
        }
        
        func syncHosts() -> CmdResult {
        let domains = store.servedSites()
            .filter { $0.mode == .domain }
            .map { $0.domain }
    
        let block = domains.map { "127.0.0.1 \($0)" }.joined(separator: "\n")
    
        let script = """
    sed -i '' '/# DEVSRV-BEGIN/,/# DEVSRV-END/d' /etc/hosts
    echo "# DEVSRV-BEGIN" >> /etc/hosts
    echo "\(block)" >> /etc/hosts
    echo "# DEVSRV-END" >> /etc/hosts
    """
    
        if domains.isEmpty {
            return Shell.runAsAdmin("sed -i '' '/# DEVSRV-BEGIN/,/# DEVSRV-END/d' /etc/hosts")
        }
    
        return Shell.runAsAdmin(script)
    }

    func siteStatus(for site: Site) -> SiteStatus {
        if !site.served { return .off }
        if state() != .running { return .error }

        let url = site.withoutPort ? "https://localhost" : "https://localhost:8443"
        let r = Shell.run("/usr/bin/curl", ["-skI", url, "--max-time", "2"], timeoutSec: 3)
        if r.code == 0 && (r.out.contains("200") || r.out.contains("301") || r.out.contains("302")) { return .on }
        return .error
    }

    func readLogs() -> String {
        let access = Shell.run("/usr/bin/tail", ["-n", "300", Paths.accessLog().path], timeoutSec: 2)
        let err = Shell.run("/usr/bin/tail", ["-n", "300", Paths.errLog().path], timeoutSec: 2)

        var s = ""
        s += "=== ACCESS (\(Paths.accessLog().path)) ===\n"
        if access.code == 0 {
            let t = access.out.trimmingCharacters(in: .whitespacesAndNewlines)
            s += t.isEmpty ? "(empty — open the site once, then press Logs again)\n\n" : (access.out + "\n")
        } else {
            s += "(cannot read) \(access.err)\n\n"
        }

        s += "=== ERROR (\(Paths.errLog().path)) ===\n"
        if err.code == 0 {
            let t = err.out.trimmingCharacters(in: .whitespacesAndNewlines)
            s += t.isEmpty ? "(empty)\n" : (err.out + "\n")
        } else {
            s += "(cannot read) \(err.err)\n"
        }

        return s
    }

    // ---------- Root (without port) LaunchDaemon ----------

    private func writeDaemonPlist(caddyPath: String) -> String {
        let caddyfile = Paths.caddyfileGenerated().path
        let home = "/var/root"
        let xdg = "\(home)/Library/Application Support"

        // Ensure paths are absolute and safe in plist
        let plist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>\(Paths.daemonLabel())</string>

  <key>ProgramArguments</key>
  <array>
    <string>\(caddyPath)</string>
    <string>run</string>
    <string>--config</string>
    <string>\(caddyfile)</string>
    <string>--adapter</string>
    <string>caddyfile</string>
  </array>

  <key>WorkingDirectory</key>
  <string>\(home)</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>\(home)</string>
    <key>XDG_DATA_HOME</key><string>\(xdg)</string>
    <key>XDG_CONFIG_HOME</key><string>\(xdg)</string>
    <key>PATH</key><string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>

  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>

  <key>StandardOutPath</key>
  <string>\(Paths.errLog().path)</string>
  <key>StandardErrorPath</key>
  <string>\(Paths.errLog().path)</string>
</dict>
</plist>
"""
        return plist
    }

    private func installOrRepairDaemon() -> CmdResult {
        store.generateCaddyfile()

        guard let caddyPath = caddyPathOrError() else {
            return CmdResult(code: 2, out: "", err: "Embedded caddy missing in app bundle (Resources/caddy).")
        }

        let plistText = writeDaemonPlist(caddyPath: caddyPath)
        let tmp = Paths.appSupportDir().appendingPathComponent("devsrv.caddy.plist.tmp")

        do { try plistText.data(using: .utf8)!.write(to: tmp, options: .atomic) }
        catch { return CmdResult(code: 2, out: "", err: "Cannot write tmp plist: \(error)") }

        let cmd = """
/bin/mkdir -p /Library/LaunchDaemons && \
/bin/mkdir -p "\(Paths.appSupportDir().path)" && \
/usr/bin/touch "\(Paths.accessLog().path)" "\(Paths.errLog().path)" && \
/bin/chmod 644 "\(Paths.accessLog().path)" "\(Paths.errLog().path)" && \
/bin/cp "\(tmp.path)" "\(Paths.daemonPlistPath())" && \
/usr/sbin/chown root:wheel "\(Paths.daemonPlistPath())" && \
/bin/chmod 644 "\(Paths.daemonPlistPath())" && \
/bin/launchctl bootout system "\(Paths.daemonPlistPath())" 2>/dev/null || true; \
/bin/launchctl bootstrap system "\(Paths.daemonPlistPath())" && \
/bin/launchctl enable system/\(Paths.daemonLabel()) && \
/bin/launchctl kickstart -k system/\(Paths.daemonLabel())
"""
        return Shell.runAsAdmin(cmd)
    }

    private func stopDaemon() -> CmdResult {
        return Shell.runAsAdmin("/bin/launchctl bootout system \"\(Paths.daemonPlistPath())\" 2>/dev/null || true")
    }

    // ---------- User (with port) background process ----------

    private func stopUserCaddyIfRunning() {
        let pidFile = Paths.userPidFile()
        guard let pidStr = try? String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int(pidStr), pid > 1 else {
            try? FileManager.default.removeItem(at: pidFile)
            return
        }
        _ = Shell.run("/bin/kill", ["-TERM", "\(pid)"], timeoutSec: 2)
        try? FileManager.default.removeItem(at: pidFile)
    }

    private func startUserCaddy() -> CmdResult {
        store.generateCaddyfile()
        guard let caddy = caddyPathOrError() else {
            return CmdResult(code: 2, out: "", err: "Embedded caddy missing in app bundle (Resources/caddy).")
        }

        // Ensure logs exist
        _ = Shell.run("/usr/bin/touch", [Paths.accessLog().path], timeoutSec: 2)
        _ = Shell.run("/usr/bin/touch", [Paths.errLog().path], timeoutSec: 2)

        // Stop any previous user process
        stopUserCaddyIfRunning()

        let cfg = Paths.caddyfileGenerated().path.replacingOccurrences(of: "\"", with: "\\\"")
        let errLog = Paths.errLog().path.replacingOccurrences(of: "\"", with: "\\\"")
        let pidFile = Paths.userPidFile().path.replacingOccurrences(of: "\"", with: "\\\"")

        // Start in background + write PID
        let cmd = """
/bin/sh -lc '\(caddy) run --config "\(cfg)" --adapter caddyfile >> "\(errLog)" 2>&1 & echo $! > "\(pidFile)"'
"""
        // run as normal user
        return Shell.run("/bin/sh", ["-lc", cmd], timeoutSec: 6)
    }

    // ---------- Public entrypoints used by UI ----------

    /// Apply current config & ensure correct mode:
    /// - if active served site uses withoutPort => install/repair daemon (admin)
    /// - else => start user caddy on :8443
    func apply() -> CmdResult {
        store.generateCaddyfile()
    
        let needsAdmin = store.servedSites().contains { $0.mode == .domain }
        if needsAdmin {
            let r = syncHosts()
            if r.code != 0 { return r }
        }
    
        return startUserCaddy()
    }
    
        func stopAll() -> CmdResult {
            stopUserCaddyIfRunning()
            _ = stopDaemon()
            return CmdResult(code: 0, out: "Stopped.", err: "")
        }
    }

// MARK: - UI: Log Window

final class LogWindowController: NSWindowController {
    private let textView = NSTextView()
    private let scroll = NSScrollView()

    init(title: String) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 560),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = title
        super.init(window: w)
        centerWindow(w)

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.frame = w.contentView!.bounds
        scroll.autoresizingMask = [.width, .height]

        w.contentView = scroll
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setText(_ s: String) {
        textView.string = s
        textView.scrollToEndOfDocument(nil)
    }
}


// MARK: - UI: Site Editor (Label / Folder / Without port)

final class SiteEditorWindowController: NSWindowController {

    private let store: Store

    private let labelField = NSTextField()
    private let folderField = NSTextField()
    private let chooseBtn = NSButton(title: "Choose…", target: nil, action: nil)

    private let servedCheck = NSButton(checkboxWithTitle: "Serve this site", target: nil, action: nil)
    private let shortcutCheck = NSButton(checkboxWithTitle: "Show shortcut in topbar", target: nil, action: nil)

    private let withoutPortCheck = NSButton(checkboxWithTitle: "Use without port (https://localhost)", target: nil, action: nil)
    private let withoutPortHint = NSTextField(labelWithString: "Requires admin password (binds to port 443).")

    private let previewLabel = NSTextField(labelWithString: "")
    private let warningLabel = NSTextField(labelWithString: "")

    private let saveBtn = NSButton(title: "Save", target: nil, action: nil)
    private let cancelBtn = NSButton(title: "Cancel", target: nil, action: nil)

    private var onSave: ((Site) -> Void)?
    private var siteId: String
    private var initialSite: Site?

    init(store: Store, title: String, initial: Site?, onSave: @escaping (Site) -> Void) {
        self.store = store
        self.onSave = onSave
        self.siteId = initial?.id ?? UUID().uuidString
        self.initialSite = initial

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 360),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = title
        super.init(window: w)
        centerWindow(w)

        let content = NSView(frame: w.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        w.contentView = content

        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            return l
        }

        let pad: CGFloat = 18

        let labelL = label("Label (topbar)")
        let folderL = label("Folder")

        labelField.placeholderString = "e.g. Familiada"
        folderField.placeholderString = "/Users/.../project"

        warningLabel.textColor = .systemRed
        previewLabel.textColor = .secondaryLabelColor
        withoutPortHint.textColor = .secondaryLabelColor
        withoutPortHint.font = NSFont.systemFont(ofSize: 11)

        for b in [chooseBtn, saveBtn, cancelBtn] { b.bezelStyle = .rounded }

        chooseBtn.target = self
        chooseBtn.action = #selector(chooseFolder)

        saveBtn.target = self
        saveBtn.action = #selector(saveTapped)

        cancelBtn.target = self
        cancelBtn.action = #selector(cancelTapped)

        // Load initial
        if let s0 = initial {
            var s = s0
            s.normalize()
            labelField.stringValue = s.shortcutLabel
            folderField.stringValue = s.folder
            servedCheck.state = s.served ? .on : .off
            shortcutCheck.state = s.shortcut ? .on : .off
            withoutPortCheck.state = s.withoutPort ? .on : .off
        } else {
            servedCheck.state = .off
            shortcutCheck.state = .on
            withoutPortCheck.state = .off
        }

        // Layout
        labelL.frame = NSRect(x: pad, y: 310, width: 300, height: 18)
        labelField.frame = NSRect(x: pad, y: 284, width: 724, height: 24)

        folderL.frame = NSRect(x: pad, y: 250, width: 300, height: 18)
        folderField.frame = NSRect(x: pad, y: 224, width: 594, height: 24)
        chooseBtn.frame = NSRect(x: pad + 624, y: 222, width: 100, height: 28)

        servedCheck.frame = NSRect(x: pad, y: 186, width: 220, height: 22)
        shortcutCheck.frame = NSRect(x: pad + 240, y: 186, width: 260, height: 22)

        withoutPortCheck.frame = NSRect(x: pad, y: 150, width: 330, height: 22)
        withoutPortHint.frame = NSRect(x: pad + 24, y: 130, width: 700, height: 18)

        previewLabel.frame = NSRect(x: pad, y: 96, width: 724, height: 18)
        warningLabel.frame = NSRect(x: pad, y: 76, width: 724, height: 18)

        cancelBtn.frame = NSRect(x: 760 - pad - 210, y: 18, width: 100, height: 28)
        saveBtn.frame = NSRect(x: 760 - pad - 105, y: 18, width: 100, height: 28)

        // resizing
        folderField.autoresizingMask = [.width]
        previewLabel.autoresizingMask = [.width]
        warningLabel.autoresizingMask = [.width]
        withoutPortHint.autoresizingMask = [.width]

        for v in [
            labelL, labelField,
            folderL, folderField, chooseBtn,
            servedCheck, shortcutCheck,
            withoutPortCheck, withoutPortHint,
            previewLabel, warningLabel,
            cancelBtn, saveBtn
        ] {
            content.addSubview(v)
        }

        for f in [labelField, folderField] {
            f.target = self
            f.action = #selector(fieldsChanged)
        }
        for cb in [servedCheck, shortcutCheck, withoutPortCheck] {
            cb.target = self
            cb.action = #selector(fieldsChanged)
        }

        updatePreviewAndValidation()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fieldsChanged() { updatePreviewAndValidation() }

    private func updatePreviewAndValidation() {
        let label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = folderField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPort = (withoutPortCheck.state == .on)

        let url = withoutPort ? "https://localhost" : "https://localhost:8443"
        previewLabel.stringValue = "Preview: \(url)  →  \(folder)"

        var warn = ""
        var ok = true

        if label.isEmpty { ok = false; warn = "Label is required." }
        else if folder.isEmpty { ok = false; warn = "Folder is required." }
        else if !FileManager.default.fileExists(atPath: folder) { ok = false; warn = "Folder does not exist." }
        else {
            let tmp = Site(
                id: siteId,
                name: initialSite?.name ?? label,
                shortcutLabel: label,
                folder: folder,
                served: servedCheck.state == .on,
                shortcut: shortcutCheck.state == .on,
                withoutPort: withoutPort
            )
            if !store.indexHtmlExists(for: tmp) {
                warn = "Warning: index.html not found in folder."
            }
        }

        warningLabel.stringValue = warn
        saveBtn.isEnabled = ok
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            folderField.stringValue = url.path
            updatePreviewAndValidation()
        }
    }

    @objc private func saveTapped() {
        let label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = folderField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        var s = Site(
            id: siteId,
            name: (initialSite?.name ?? label),
            shortcutLabel: label,
            folder: folder,
            served: servedCheck.state == .on,
            shortcut: shortcutCheck.state == .on,
            withoutPort: withoutPortCheck.state == .on
        )
        s.normalize()
        onSave?(s)
        close()
    }

    @objc private func cancelTapped() { close() }
}


// MARK: - UI: Manager Window

final class ManagerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    private let store: Store
    private let caddy: CaddyService
    private let onShortcutsChanged: () -> Void

    private let statusLabel = NSTextField(labelWithString: "")
    private let infoLabel = NSTextField(labelWithString: "")
    private let warnLabel = NSTextField(labelWithString: "")

    private let table = NSTableView()
    private let scroll = NSScrollView()

    private let addBtn = NSButton(title: "Add…", target: nil, action: nil)
    private let editBtn = NSButton(title: "Edit…", target: nil, action: nil)
    private let removeBtn = NSButton(title: "Remove", target: nil, action: nil)

    private let startStopBtn = NSButton(title: "Start", target: nil, action: nil)
    private let openBtn = NSButton(title: "Open", target: nil, action: nil)

    private let applyBtn = NSButton(title: "Apply", target: nil, action: nil)
    private let stopAllBtn = NSButton(title: "Stop All", target: nil, action: nil)
    private let logsBtn = NSButton(title: "Logs…", target: nil, action: nil)

    private var logWin: LogWindowController?
    private var editorWin: SiteEditorWindowController?

    init(store: Store, caddy: CaddyService, onShortcutsChanged: @escaping () -> Void) {
        self.store = store
        self.caddy = caddy
        self.onShortcutsChanged = onShortcutsChanged

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "DevSrv Manager"
        super.init(window: w)
        centerWindow(w)

        let content = NSView(frame: w.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        w.contentView = content

        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        infoLabel.textColor = .secondaryLabelColor
        warnLabel.textColor = .systemRed

        statusLabel.frame = NSRect(x: 18, y: 608, width: 944, height: 18)
        infoLabel.frame = NSRect(x: 18, y: 588, width: 944, height: 18)
        warnLabel.frame = NSRect(x: 18, y: 568, width: 944, height: 18)

        // Table
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self

        func addCol(_ id: String, _ title: String, _ min: CGFloat, _ max: CGFloat? = nil) {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.minWidth = min
            if let max = max { c.maxWidth = max }
            table.addTableColumn(c)
        }

        addCol("label", "Label", 140)
        addCol("url", "URL", 220)
        addCol("domain", "Domain", 180)
        addCol("port", "Port", 80)
        addCol("folder", "Folder", 320)
        addCol("status", "Status", 90, 110)
        addCol("shortcut", "Shortcut", 90, 110)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.frame = NSRect(x: 18, y: 250, width: 944, height: 300)
        scroll.autoresizingMask = [.width, .height]

        // Buttons
        addBtn.frame = NSRect(x: 18, y: 212, width: 90, height: 28)
        editBtn.frame = NSRect(x: 114, y: 212, width: 90, height: 28)
        removeBtn.frame = NSRect(x: 210, y: 212, width: 90, height: 28)

        startStopBtn.frame = NSRect(x: 320, y: 212, width: 110, height: 28)
        openBtn.frame = NSRect(x: 438, y: 212, width: 90, height: 28)

        applyBtn.frame = NSRect(x: 18, y: 166, width: 90, height: 28)
        stopAllBtn.frame = NSRect(x: 114, y: 166, width: 90, height: 28)
        logsBtn.frame = NSRect(x: 210, y: 166, width: 90, height: 28)

        for b in [addBtn, editBtn, removeBtn, startStopBtn, openBtn, applyBtn, stopAllBtn, logsBtn] {
            b.bezelStyle = .rounded
        }

        addBtn.target = self; addBtn.action = #selector(addSite)
        editBtn.target = self; editBtn.action = #selector(editSite)
        removeBtn.target = self; removeBtn.action = #selector(removeSite)

        startStopBtn.target = self; startStopBtn.action = #selector(startStopSelected)
        openBtn.target = self; openBtn.action = #selector(openSelected)

        applyBtn.target = self; applyBtn.action = #selector(applyConfig)
        stopAllBtn.target = self; stopAllBtn.action = #selector(stopAll)
        logsBtn.target = self; logsBtn.action = #selector(showLogs)

        for v in [
            statusLabel, infoLabel, warnLabel,
            scroll,
            addBtn, editBtn, removeBtn, startStopBtn, openBtn,
            applyBtn, stopAllBtn, logsBtn
        ] {
            content.addSubview(v)
        }

        refreshAll()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func numberOfRows(in tableView: NSTableView) -> Int { store.sites.count }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let s = store.sites[row]
        let key = tableColumn?.identifier.rawValue ?? ""

        if key == "shortcut" {
            let id = NSUserInterfaceItemIdentifier("shortcutCheck")
            let cb: NSButton
            if let existing = tableView.makeView(withIdentifier: id, owner: self) as? NSButton {
                cb = existing
            } else {
                cb = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleShortcut(_:)))
                cb.identifier = id
            }
            cb.state = s.shortcut ? .on : .off
            cb.tag = row
            return cb
        }

        let id = NSUserInterfaceItemIdentifier("cell.\(key)")
        let tf: NSTextField
        if let existing = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField {
            tf = existing
        } else {
            tf = NSTextField(labelWithString: "")
            tf.identifier = id
            tf.lineBreakMode = .byTruncatingMiddle
        }

        switch key {
        case "label":
            tf.stringValue = s.shortcutLabel
        case "url":
            tf.stringValue = s.urlString()
        case "folder":
            tf.stringValue = s.folder
        case "status":
            let st = caddy.siteStatus(for: s)
            tf.stringValue = (st == .on ? "🟢 On" : (st == .off ? "⚪ Off" : "🔴 Err"))
        default:
            tf.stringValue = ""
        }
        return tf
    }

    private func selectedSite() -> Site? {
        let r = table.selectedRow
        guard r >= 0, r < store.sites.count else { return nil }
        return store.sites[r]
    }

    func selectSite(id: String) {
        if let idx = store.sites.firstIndex(where: { $0.id == id }) {
            table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            table.scrollRowToVisible(idx)
            updateButtons()
        }
    }

    private func updateButtons() {
        let hasSel = (selectedSite() != nil)
        editBtn.isEnabled = hasSel
        removeBtn.isEnabled = hasSel
        startStopBtn.isEnabled = hasSel
        openBtn.isEnabled = hasSel

        if let s = selectedSite() {
            startStopBtn.title = s.served ? "Stop" : "Start"
        } else {
            startStopBtn.title = "Start"
        }
    }

    @objc private func toggleShortcut(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < store.sites.count else { return }
        var s = store.sites[row]
        s.shortcut = (sender.state == .on)
        store.upsert(s)
        onShortcutsChanged()
        refreshAll(keepSelection: s.id)
    }

    @objc private func addSite() {
        editorWin = SiteEditorWindowController(store: store, title: "Add Site", initial: nil) { [weak self] site in
            self?.store.upsert(site)
            self?.onShortcutsChanged()
            self?.refreshAll(keepSelection: site.id)
            self?.editorWin = nil
        }
        editorWin?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func editSite() {
        guard let s = selectedSite() else { warnLabel.stringValue = "Select a site first."; return }
        editorWin = SiteEditorWindowController(store: store, title: "Edit Site", initial: s) { [weak self] site in
            self?.store.upsert(site)
            self?.onShortcutsChanged()
            self?.refreshAll(keepSelection: site.id)
            self?.editorWin = nil
        }
        editorWin?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func removeSite() {
        guard let s = selectedSite() else { warnLabel.stringValue = "Select a site first."; return }

        let alert = NSAlert()
        alert.messageText = "Remove site '\(s.name)'?"
        alert.informativeText = "This only removes it from DevSrv configuration."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            store.remove(id: s.id)
            onShortcutsChanged()
            refreshAll()
        }
    }

    @objc private func startStopSelected() {
        guard let s0 = selectedSite() else { warnLabel.stringValue = "Select a site first."; return }

        // Toggle, but enforce single served site
        let newServed = !s0.served
        store.setOnlyServed(id: s0.id, served: newServed)
        store.loadSites()

        // Apply immediately
        infoLabel.stringValue = (newServed ? "Starting…" : "Stopping…")
        let r = caddy.apply()
        if r.code != 0 {
            warnLabel.stringValue = (r.err.isEmpty ? r.out : r.err)
        } else {
            warnLabel.stringValue = ""
        }

        refreshAll(keepSelection: s0.id)
    }

    @objc private func openSelected() {
        guard let s = selectedSite() else { warnLabel.stringValue = "Select a site first."; return }
        _ = Shell.run("/usr/bin/open", [s.urlString()], timeoutSec: 2)
    }

    @objc private func applyConfig() {
        warnLabel.stringValue = ""
        infoLabel.stringValue = "Applying…"
        let r = caddy.apply()
        if r.code != 0 {
            warnLabel.stringValue = (r.err.isEmpty ? r.out : r.err)
        }
        refreshAll(keepSelection: selectedSite()?.id)
    }

    @objc private func stopAll() {
        warnLabel.stringValue = ""
        infoLabel.stringValue = "Stopping…"
        _ = caddy.stopAll()

        // Clear served flags
        for i in store.sites.indices { store.sites[i].served = false }
        store.saveSites()

        refreshAll(keepSelection: selectedSite()?.id)
    }

    @objc private func showLogs() {
        let lw = logWin ?? LogWindowController(title: "DevSrv Logs")
        lw.showWindow(nil)
        lw.setText(caddy.readLogs())
        logWin = lw
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshAll(keepSelection: String? = nil) {
        store.loadSites()
        store.generateCaddyfile()
        table.reloadData()

        table.sizeToFit()

        let st = caddy.state()
        let ver = caddy.caddyVersion()
        statusLabel.stringValue = "Caddy: \(st.rawValue)   |   \(ver.isEmpty ? "(version unknown)" : ver)"

        warnLabel.stringValue = store.lastError ?? warnLabel.stringValue
        infoLabel.stringValue = store.lastInfo ?? infoLabel.stringValue

        // Warn if served site missing index.html
        if let active = store.activeServedSite(), !store.indexHtmlExists(for: active) {
            warnLabel.stringValue = "Warning: served site missing index.html: \(active.name)"
        }

        // If active site is withoutPort, show admin hint
        if let active = store.activeServedSite(), active.withoutPort {
            if infoLabel.stringValue.isEmpty {
                infoLabel.stringValue = "Without port enabled → admin password will be requested."
            }
        }

        if let id = keepSelection { selectSite(id: id) }
        updateButtons()
    }
}


// MARK: - UI: Quick Actions (topbar shortcuts)

final class QuickActionWindowController: NSWindowController {
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

    private let startStopBtn = NSButton(title: "Start", target: nil, action: nil)
    private let openBtn = NSButton(title: "Open", target: nil, action: nil)
    private let editBtn = NSButton(title: "Edit", target: nil, action: nil)
    private let closeBtn = NSButton(title: "Close", target: nil, action: nil)

    private var site: Site
    private let store: Store
    private let caddy: CaddyService
    private let openManager: () -> Void
    private let selectInManager: (String) -> Void
    private let onShortcutsChanged: () -> Void

    init(site: Site,
         store: Store,
         caddy: CaddyService,
         openManager: @escaping () -> Void,
         selectInManager: @escaping (String) -> Void,
         onShortcutsChanged: @escaping () -> Void) {
        self.site = site
        self.store = store
        self.caddy = caddy
        self.openManager = openManager
        self.selectInManager = selectInManager
        self.onShortcutsChanged = onShortcutsChanged

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 180),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Site"
        super.init(window: w)
        centerWindow(w)

        let content = NSView(frame: w.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        w.contentView = content

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.frame = NSRect(x: 18, y: 142, width: 480, height: 18)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 18, y: 120, width: 480, height: 18)

        startStopBtn.frame = NSRect(x: 18, y: 58, width: 110, height: 28)
        openBtn.frame = NSRect(x: 138, y: 58, width: 90, height: 28)
        editBtn.frame = NSRect(x: 236, y: 58, width: 90, height: 28)
        closeBtn.frame = NSRect(x: 334, y: 58, width: 110, height: 28)

        for b in [startStopBtn, openBtn, editBtn, closeBtn] { b.bezelStyle = .rounded }

        startStopBtn.target = self; startStopBtn.action = #selector(toggleServing)
        openBtn.target = self; openBtn.action = #selector(openSite)
        editBtn.target = self; editBtn.action = #selector(editSite)
        closeBtn.target = self; closeBtn.action = #selector(closeWin)

        for v in [titleLabel, statusLabel, startStopBtn, openBtn, editBtn, closeBtn] {
            content.addSubview(v)
        }

        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSite(_ s: Site) {
        site = s
        refresh()
    }

    private func refresh() {
        let display = site.shortcutLabel.isEmpty ? site.name : site.shortcutLabel
        titleLabel.stringValue = "\(display) — \(site.urlString())"
        let st = caddy.siteStatus(for: site)
        statusLabel.stringValue = "Status: \(st.rawValue)   (served=\(site.served ? "yes" : "no"))"
        startStopBtn.title = site.served ? "Stop" : "Start"
    }

    @objc private func toggleServing() {
        // enforce single served site
        store.setOnlyServed(id: site.id, served: !site.served)
        store.loadSites()
        if let latest = store.sites.first(where: { $0.id == site.id }) { site = latest }

        _ = caddy.apply()
        refresh()
        onShortcutsChanged()
    }

    @objc private func openSite() {
        _ = Shell.run("/usr/bin/open", [site.urlString()], timeoutSec: 2)
    }

    @objc private func editSite() {
        openManager()
        selectInManager(site.id)
        close()
    }

    @objc private func closeWin() { close() }
}


// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var manager: ManagerWindowController?
    private var quickWin: QuickActionWindowController?

    private let store = Store()
    private lazy var caddy = CaddyService(store: store)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🟢 DevSrv"
        rebuildTopbarMenu()
    }

    private func rebuildTopbarMenu() {
        store.loadSites()

        let menu = NSMenu()

        let openManager = NSMenuItem(title: "Open Manager…", action: #selector(openManagerWindow), keyEquivalent: "m")
        openManager.target = self
        menu.addItem(openManager)

        menu.addItem(NSMenuItem.separator())

        let shortcuts = store.sites
            .filter { $0.shortcut }
            .sorted { ($0.shortcutLabel.lowercased()) < ($1.shortcutLabel.lowercased()) }

        if shortcuts.isEmpty {
            let empty = NSMenuItem(title: "(no shortcuts)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for s in shortcuts {
                let title = s.shortcutLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? s.name : s.shortcutLabel
                let item = NSMenuItem(title: "🌐 \(title)", action: #selector(openQuickAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = s.id
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        let apply = NSMenuItem(title: "Apply", action: #selector(applyFromMenu), keyEquivalent: "a")
        apply.target = self
        menu.addItem(apply)

        let stop = NSMenuItem(title: "Stop All", action: #selector(stopAllFromMenu), keyEquivalent: "s")
        stop.target = self
        menu.addItem(stop)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func openManagerWindow() {
        if manager == nil {
            manager = ManagerWindowController(
                store: store,
                caddy: caddy,
                onShortcutsChanged: { [weak self] in
                    self?.rebuildTopbarMenu()
                }
            )
        }
        manager?.showWindow(nil)
        manager?.refreshAll()
        NSApp.activate(ignoringOtherApps: true)
        rebuildTopbarMenu()
    }

    @objc private func openQuickAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }

        store.loadSites()
        guard let s = store.sites.first(where: { $0.id == id }) else { return }

        let win = quickWin ?? QuickActionWindowController(
            site: s,
            store: store,
            caddy: caddy,
            openManager: { [weak self] in self?.openManagerWindow() },
            selectInManager: { [weak self] siteId in self?.manager?.selectSite(id: siteId) },
            onShortcutsChanged: { [weak self] in self?.rebuildTopbarMenu() }
        )
        win.setSite(s)
        win.showWindow(nil)
        quickWin = win

        NSApp.activate(ignoringOtherApps: true)
        rebuildTopbarMenu()
    }

    @objc private func applyFromMenu() {
        _ = caddy.apply()
        manager?.refreshAll()
        rebuildTopbarMenu()
    }

    @objc private func stopAllFromMenu() {
        _ = caddy.stopAll()
        // clear served flags
        store.loadSites()
        for i in store.sites.indices { store.sites[i].served = false }
        store.saveSites()

        manager?.refreshAll()
        rebuildTopbarMenu()
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
}


// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()