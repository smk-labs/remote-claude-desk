// Cap the pixel size of images on the pasteboard while an RDP client is running.
//
// The bug this exists for. Take a macOS screenshot to the clipboard while
// connected, and the RDP clipboard channel wedges: the image never pastes, text
// stops crossing too, and the connection cannot be re-established until the
// client is fully quit. Microsoft has an open report of it, and it happens
// against real Windows servers as well as xrdp, so it is the client's clipboard
// handling and neither the tunnel nor the far side.
//
// Why size is the trigger. RDP carries images as CF_DIB, which is uncompressed,
// so what goes on the wire is width x height x 4 bytes no matter how small the
// PNG on the pasteboard was. Measured on this Mac:
//
//   fullscreen Retina screenshot, 2560x1600  ->  15.6 MB on the wire   wedges
//   the 68x56 image tested earlier today     ->   0.015 MB            crosses
//
// A thousandfold difference, through a virtual channel that chunks small and
// has to be answered synchronously. So the fix is not to make the transfer
// faster, it is to stop asking it to carry sixteen megabytes.
//
// What this does about it: when an image lands on the pasteboard and its pixel
// count is over the cap, replace it with a scaled copy that fits. Only while an
// RDP client is actually running, so nothing else on the Mac ever notices.
//
//   clipshrink                 watch, and shrink when needed
//   clipshrink --test <file>   resize one file to /tmp and print the result,
//                              which is how the maths is checked without a
//                              pasteboard this process cannot reach anyway
import AppKit

let MAX_PIXELS = Int(ProcessInfo.processInfo.environment["CLIPSHRINK_MAX_PIXELS"] ?? "") ?? 1_000_000
let RDP_BUNDLES = ["com.microsoft.rdc.macos", "com.microsoft.rdc.mac", "com.microsoft.WindowsApp"]
let POLL = 0.25

func log(_ s: String) {
    let t = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(t)] \(s)\n".utf8))
}

// Pixel dimensions, not point dimensions. NSImage.size is in points and lies
// about a Retina grab by a factor of two in each direction, which is four times
// the bytes: exactly the mistake that would make this cap do nothing.
func pixelSize(_ rep: NSImageRep) -> (Int, Int) { (rep.pixelsWide, rep.pixelsHigh) }

func scaled(_ rep: NSBitmapImageRep, to max: Int) -> Data? {
    let (w, h) = pixelSize(rep)
    let factor = (Double(max) / Double(w * h)).squareRoot()
    let nw = Swift.max(1, Int(Double(w) * factor))
    let nh = Swift.max(1, Int(Double(h) * factor))
    guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: nw, pixelsHigh: nh,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    out.size = NSSize(width: nw, height: nh)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    NSGraphicsContext.current?.imageInterpolation = .high
    rep.draw(in: NSRect(x: 0, y: 0, width: nw, height: nh))
    NSGraphicsContext.restoreGraphicsState()
    return out.representation(using: .png, properties: [:])
}

// --- test mode: no pasteboard, just the maths -------------------------------
let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--test" {
    guard args.count > 1, let data = FileManager.default.contents(atPath: args[1]),
          let rep = NSBitmapImageRep(data: data) else {
        FileHandle.standardError.write(Data("usage: clipshrink --test <image file>\n".utf8))
        exit(2)
    }
    let (w, h) = pixelSize(rep)
    print("in:  \(w)x\(h) = \(w*h) pixels, \(String(format: "%.1f", Double(w*h*4)/1048576)) MB as CF_DIB")
    if w * h <= MAX_PIXELS { print("out: unchanged, already within the \(MAX_PIXELS) pixel cap"); exit(0) }
    guard let png = scaled(rep, to: MAX_PIXELS), let outRep = NSBitmapImageRep(data: png) else {
        print("out: FAILED to scale"); exit(1)
    }
    let (ow, oh) = pixelSize(outRep)
    try? png.write(to: URL(fileURLWithPath: "/tmp/clipshrink-test.png"))
    print("out: \(ow)x\(oh) = \(ow*oh) pixels, \(String(format: "%.1f", Double(ow*oh*4)/1048576)) MB as CF_DIB")
    print("     png written to /tmp/clipshrink-test.png (\(png.count) bytes)")
    exit(0)
}

// --- watch mode ---------------------------------------------------------------
let pb = NSPasteboard.general
var seen = pb.changeCount
log("clipshrink watching, cap \(MAX_PIXELS) pixels")

while true {
    if pb.changeCount != seen {
        seen = pb.changeCount
        let running = RDP_BUNDLES.contains {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }
        // The type list, never the contents. Asking for the data on every tick
        // is what made an earlier version of a pasteboard poller in this repo
        // jam the whole machine, and the fix was the same then: pb.types is a
        // list, pb.data is a copy.
        let types = pb.types ?? []
        if running, types.contains(.png) || types.contains(.tiff) {
            if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
               let rep = NSBitmapImageRep(data: data) {
                let (w, h) = pixelSize(rep)
                if w * h > MAX_PIXELS, let png = scaled(rep, to: MAX_PIXELS),
                   let outRep = NSBitmapImageRep(data: png) {
                    pb.clearContents()
                    pb.setData(png, forType: .png)
                    seen = pb.changeCount     // our own write, not a new copy
                    let (ow, oh) = pixelSize(outRep)
                    log("shrank \(w)x\(h) to \(ow)x\(oh), "
                        + "\(String(format: "%.1f", Double(w*h*4)/1048576)) MB "
                        + "-> \(String(format: "%.1f", Double(ow*oh*4)/1048576)) MB on the wire")
                }
            }
        }
    }
    Thread.sleep(forTimeInterval: POLL)
}
