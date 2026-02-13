import Cocoa

final class BuilderWindowController: NSWindowController {

    private let statusLabel = NSTextField(labelWithString: "Ready.")
    private let percentLabel = NSTextField(labelWithString: "0%")
    private let progress = NSProgressIndicator()
    private let logView = NSTextView()
    private let scroll = NSScrollView()

    private let useCached = NSButton(checkboxWithTitle: "Use cached Caddy", target: nil, action: nil)
    private let forceUpdate = NSButton(checkboxWithTitle: "Force update Caddy", target: nil, action: nil)
    private let noPort = NSButton(checkboxWithTitle: "No port (requires admin password)", target: nil, action: nil)

    private let startBtn = NSButton(title: "Build DevSrv.app", target: nil, action: nil)
    private let revealBtn = NSButton(title: "Reveal in Finder", target: nil, action: nil)

    private var lastArtifactPath: String?
    private var task: Process?

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "DevSrv Builder"
        super.init(window: w)
        w.center()

        let content = NSView(frame: w.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        w.contentView = content

        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        statusLabel.frame = NSRect(x: 18, y: 524, width: 700, height: 18)

        percentLabel.textColor = .secondaryLabelColor
        percentLabel.frame = NSRect(x: 730, y: 524, width: 120, height: 18)
        percentLabel.alignment = .right

        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 100
        progress.doubleValue = 0
        progress.frame = NSRect(x: 18, y: 496, width: 832, height: 14)

        useCached.frame = NSRect(x: 18, y: 460, width: 220, height: 22)
        forceUpdate.frame = NSRect(x: 250, y: 460, width: 220, height: 22)
        noPort.frame = NSRect(x: 482, y: 460, width: 360, height: 22)

        useCached.state = .on
        forceUpdate.state = .off
        revealBtn.isEnabled = false

        useCached.target = self
        useCached.action = #selector(toggleCacheMode)
        forceUpdate.target = self
        forceUpdate.action = #selector(toggleCacheMode)

        startBtn.frame = NSRect(x: 18, y: 422, width: 160, height: 30)
        revealBtn.frame = NSRect(x: 186, y: 422, width: 160, height: 30)

        startBtn.bezelStyle = .rounded
        revealBtn.bezelStyle = .rounded

        startBtn.target = self
        startBtn.action = #selector(startBuild)

        revealBtn.target = self
        revealBtn.action = #selector(revealInFinder)

        logView.isEditable = false
        logView.isSelectable = true
        logView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        scroll.documentView = logView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.frame = NSRect(x: 18, y: 18, width: 832, height: 392)
        scroll.autoresizingMask = [.width, .height]

        for v in [statusLabel, percentLabel, progress, useCached, forceUpdate, noPort, startBtn, revealBtn, scroll] {
            content.addSubview(v)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func toggleCacheMode() {
        // Mutual exclusive:
        if forceUpdate.state == .on { useCached.state = .off }
        if useCached.state == .on { forceUpdate.state = .off }
        if useCached.state == .off && forceUpdate.state == .off {
            useCached.state = .on
        }
    }

    @objc private func startBuild() {
        if task != nil { return }

        revealBtn.isEnabled = false
        lastArtifactPath = nil
        setStatus("Building… 🛠️")
        setPercent(0)
        appendLog("== Build started ==\n")

        guard let scriptPath = Bundle.main.path(forResource: "build", ofType: "sh") else {
            setStatus("Missing build.sh 🔴")
            appendLog("ERROR: build.sh not found in app Resources.\n")
            return
        }
        let script = scriptPath

        var args: [String] = []
        if forceUpdate.state == .on {
            args.append("--force-update-caddy")
        } else {
            args.append("--use-cached-caddy")
        }
        if noPort.state == .on {
            args.append("--no-port")
            appendLog("NOTE: No-port requires admin password (the app will prompt when needed).\n")
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script] + args

        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let data = h.availableData
            if data.isEmpty { return }
            if let s = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async { self.handleOutput(s) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let data = h.availableData
            if data.isEmpty { return }
            if let s = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self.appendLog("[stderr] \(s)")
                }
            }
        }

        do {
            try p.run()
            task = p
            startBtn.isEnabled = false

            p.terminationHandler = { [weak self] _ in
                DispatchQueue.main.async {
                    self?.startBtn.isEnabled = true
                    self?.task = nil
                }
            }
        } catch {
            task = nil
            startBtn.isEnabled = true
            setStatus("Failed to start. 🔴")
            appendLog("Cannot run build script: \(error)\n")
        }
    }

    private func handleOutput(_ chunk: String) {
        // split by lines (keep partial lines OK enough)
        let lines = chunk.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        for line in lines {
            if line.hasPrefix("@@PERCENT ") {
                let v = line.replacingOccurrences(of: "@@PERCENT ", with: "").trimmingCharacters(in: .whitespaces)
                if let d = Double(v) { setPercent(d) }
                continue
            }
            if line.hasPrefix("@@STEP ") {
                // @@STEP ok "Name"
                if line.contains(" ok ") {
                    setStatus("✅ \(extractQuoted(line) ?? "Step")")
                } else if line.contains(" err ") {
                    setStatus("🔴 \(extractQuoted(line) ?? "Error")")
                } else {
                    setStatus(line)
                }
                continue
            }
            if line.hasPrefix("@@LOG ") {
                appendLog(line.replacingOccurrences(of: "@@LOG ", with: "") + "\n")
                continue
            }
            if line.hasPrefix("@@ARTIFACT_PATH ") {
                lastArtifactPath = line.replacingOccurrences(of: "@@ARTIFACT_PATH ", with: "").trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("@@DONE") {
                setStatus("Done ✅")
                appendLog("== Build finished ==\n")
                revealBtn.isEnabled = (lastArtifactPath != nil)
                continue
            }

            // default
            if !line.isEmpty {
                appendLog(line + "\n")
            }
        }
    }

    private func extractQuoted(_ s: String) -> String? {
        guard let a = s.firstIndex(of: "\""), let b = s.lastIndex(of: "\""), a < b else { return nil }
        return String(s[s.index(after: a)..<b])
    }

    private func setStatus(_ s: String) {
        statusLabel.stringValue = s
    }

    private func setPercent(_ p: Double) {
        let clamped = max(0, min(100, p))
        progress.doubleValue = clamped
        percentLabel.stringValue = "\(Int(clamped))%"
    }

    private func appendLog(_ s: String) {
        logView.string += s
        logView.scrollToEndOfDocument(nil)
    }

    @objc private func revealInFinder() {
        guard let path = lastArtifactPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var win: BuilderWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        win = BuilderWindowController()
        win?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()