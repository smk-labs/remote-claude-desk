// A menu bar icon that runs one command per machine. Nothing else.
//
// Machines come from ~/.config/desk-bar/machines, one per line:
//
//     mybox = desk
//     other    = DESK_SIZE=1440x900 desk
//
// The dot is filled while an RDP client is running and hollow when none is.
// That is read from the process table, so a session started from a terminal
// shows up here too.
import AppKit

let CONFIG = ("~/.config/desk-bar/machines" as NSString).expandingTildeInPath
let LOG = ("~/.cache/desk-bar.log" as NSString).expandingTildeInPath

func machines() -> [(String, String)] {
    guard let text = try? String(contentsOfFile: CONFIG, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line in
        let raw = line.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, !raw.hasPrefix("#"), let eq = raw.firstIndex(of: "=") else { return nil }
        let name = raw[..<eq].trimmingCharacters(in: .whitespaces)
        let cmd = raw[raw.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        return name.isEmpty || cmd.isEmpty ? nil : (name, cmd)
    }
}

/// True while an RDP client is running. `pgrep` and not a tracked child, so a
/// session someone started in a terminal is not reported as disconnected.
func connected() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-x", "sdl-freerdp"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
    return p.terminationStatus == 0
}

func shell(_ command: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    // -lc so the login shell's PATH is there and `desk` resolves.
    p.arguments = ["-lc", "\(command) >>'\(LOG)' 2>&1"]
    try? p.run()   // deliberately not waited on: the bar must stay responsive
}

class Bar: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var on = false

    func applicationDidFinishLaunching(_ n: Notification) {
        item.menu = NSMenu()
        item.menu?.delegate = self
        paint()
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in self.paint() }
    }

    func paint() {
        let live = connected()
        guard live != on || item.button?.image == nil else { return }
        on = live
        let name = live ? "display" : "display.trianglebadge.exclamationmark"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Remote desktop")
        image?.isTemplate = true
        item.button?.image = image
    }

    @objc func start(_ sender: NSMenuItem) {
        guard let cmd = sender.representedObject as? String else { return }
        shell(cmd)
    }

    @objc func stop() { shell("desk --stop") }

    @objc func edit() {
        let dir = (CONFIG as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: CONFIG) {
            try? "# name = command\nmybox = desk\n".write(toFile: CONFIG, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: CONFIG))
    }

    @objc func quit() { NSApp.terminate(nil) }
}

extension Bar: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let live = connected()
        let head = NSMenuItem(title: live ? "Connected" : "Not connected", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())

        let list = machines()
        if list.isEmpty {
            let none = NSMenuItem(title: "No machines yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for (name, cmd) in list {
            let row = NSMenuItem(title: name, action: #selector(start(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = cmd
            menu.addItem(row)
        }

        menu.addItem(.separator())
        if live {
            let off = NSMenuItem(title: "Disconnect", action: #selector(stop), keyEquivalent: "")
            off.target = self
            menu.addItem(off)
        }
        let ed = NSMenuItem(title: "Edit machines…", action: #selector(edit), keyEquivalent: "")
        ed.target = self
        menu.addItem(ed)
        let q = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
    }
}

let app = NSApplication.shared
let bar = Bar()
app.delegate = bar
app.setActivationPolicy(.accessory)
app.run()
