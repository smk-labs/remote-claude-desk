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

/// The local ports that currently have an RDP client on them.
///
/// Ports, not a yes/no, because one machine per bar stopped being true. Each
/// machine tunnels to its own loopback port, so the port is what tells two live
/// sessions apart, and a bare "connected" reduced both of them to one lamp and
/// one Disconnect that could only ever reach whichever config happened to be
/// the default.
///
/// Read from the process table rather than from children we spawned, so a
/// session started in a terminal counts too.
func livePorts() -> Set<String> {
    // `ps`, not `pgrep -f -a`.
    //
    // `-a` is a GNU extension. BSD pgrep, which is what macOS ships, has no such
    // flag and prints bare pids whatever you pass it, so scanning its output for
    // "/v:127.0.0.1:" found nothing, always. Every session read as down: no tick
    // on any row and a Disconnect that was permanently greyed out, on the very
    // machine you were looking at through a live window. It fails silently and
    // identically to "nothing is connected", which is the failure it was written
    // to fix. Measured on macOS 2026-09-01: `pgrep -f -a sdl-freerdp` printed
    // two pids and not one argument.
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-Ao", "command="]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    try? p.run()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()

    var ports = Set<String>()
    for line in out.split(separator: "\n") {
        // The client's own name has to be on the line, or a shell that merely
        // mentions the pattern counts as a session.
        guard line.contains("sdl-freerdp /v:127.0.0.1:") else { continue }
        guard let r = line.range(of: "/v:127.0.0.1:") else { continue }
        let tail = line[r.upperBound...]
        let port = tail.prefix { $0.isNumber }
        if !port.isEmpty { ports.insert(String(port)) }
    }
    return ports
}

/// The port `desk` falls back to when a config names none.
///
/// Duplicated from `DESK_LOCAL_PORT:=33890` in lib/common.sh, because a menu bar
/// is not a shell and cannot ask. A check in test/run holds the two together, so
/// this cannot drift into the bar quietly watching a port nothing listens on.
let DEFAULT_LOCAL_PORT = "33890"

/// Which loopback port a machine's row uses.
///
/// The row is a shell command, and the only thing in it that decides the port
/// is DESK_CONFIG. So: find that assignment, fall back to the default config,
/// and read DESK_LOCAL_PORT out of the file. Parsing a config file from a menu
/// bar is not elegant, but the alternative is running `desk` once per row on
/// every menu open, and this menu should open instantly.
func port(forCommand cmd: String) -> String? {
    var path = "~/.config/remote-claude-desk/config.sh"
    if let r = cmd.range(of: "DESK_CONFIG=") {
        let tail = cmd[r.upperBound...]
        let value = tail.prefix { !$0.isWhitespace }
        if !value.isEmpty { path = String(value) }
    }
    path = (path as NSString).expandingTildeInPath
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("DESK_LOCAL_PORT=") else { continue }
        let raw = t.dropFirst("DESK_LOCAL_PORT=".count)
                   .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        if !raw.isEmpty, raw.allSatisfy(\.isNumber) { return raw }

        // The shipped example writes DESK_LOCAL_PORT="${DESK_LOCAL_PORT:-33890}",
        // a shell default that this is not a shell to expand. Take the number out
        // of it rather than giving up, because giving up returns nil, and nil is
        // what removes the tick and the Disconnect. A config copied straight from
        // config.example.sh would have hit the exact failure this function exists
        // to fix, which is the button vanishing while the session is up.
        if let r = raw.range(of: ":-") {
            let n = raw[r.upperBound...].prefix { $0.isNumber }
            if !n.isEmpty { return String(n) }
        }
        return DEFAULT_LOCAL_PORT
    }

    // No line at all is not "unknown". desk_load_config fills in the same
    // default, so the machine is on that port and the bar should say so.
    return DEFAULT_LOCAL_PORT
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
        let live = !livePorts().isEmpty
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

    /// Disconnect ONE machine, by running that row's own command with --stop.
    /// The old version ran a bare `desk --stop`, which loads the default config
    /// and therefore could only ever reach the default machine: with a second
    /// machine added, Disconnect silently did nothing for it.
    @objc func stop(_ sender: NSMenuItem) {
        guard let cmd = sender.representedObject as? String else { return }
        shell("\(cmd) --stop")
    }

    @objc func stopAll() {
        for (_, cmd) in machines() { shell("\(cmd) --stop") }
    }

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
        let ports = livePorts()
        let list = machines()
        let liveNames = list.filter { if let p = port(forCommand: $0.1) { return ports.contains(p) }
                                      return false }
        let head = NSMenuItem(
            title: liveNames.isEmpty ? "Not connected"
                 : liveNames.count == 1 ? "Connected to \(liveNames[0].0)"
                 : "Connected to \(liveNames.count) machines",
            action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())

        // The list is labelled, because a bare machine name under a status line
        // reads as part of the status rather than as something to click. With
        // one machine that was merely unclear; with two it is a menu with no
        // idea what its middle section is for.
        let label = NSMenuItem(title: "Connections", action: nil, keyEquivalent: "")
        label.isEnabled = false
        menu.addItem(label)

        if list.isEmpty {
            let none = NSMenuItem(title: "No machines yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for (name, cmd) in list {
            let row = NSMenuItem(title: name, action: #selector(start(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = cmd
            // A tick beside the machine that is actually up. With two rows and
            // one status line there was no way to tell which one you were
            // looking at.
            if let p = port(forCommand: cmd), ports.contains(p) { row.state = .on }
            menu.addItem(row)
        }

        menu.addItem(.separator())

        // Disconnect is ALWAYS here, greyed out when there is nothing to
        // disconnect. Hiding it meant the control vanished at exactly the
        // moment you went looking for it, which reads as the app losing a
        // feature rather than as the session being down.
        if liveNames.isEmpty {
            let off = NSMenuItem(title: "Disconnect", action: nil, keyEquivalent: "")
            off.isEnabled = false
            menu.addItem(off)
        } else {
            for (name, cmd) in liveNames {
                let off = NSMenuItem(title: liveNames.count == 1 ? "Disconnect" : "Disconnect \(name)",
                                     action: #selector(stop(_:)), keyEquivalent: "")
                off.target = self
                off.representedObject = cmd
                menu.addItem(off)
            }
            if liveNames.count > 1 {
                let all = NSMenuItem(title: "Disconnect all", action: #selector(stopAll), keyEquivalent: "")
                all.target = self
                menu.addItem(all)
            }
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
