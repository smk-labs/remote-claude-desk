// Read and write the Mac pasteboard through NSPasteboard, for desk-clip.
//
// Two reasons this exists rather than pbpaste and pbcopy.
//
// Those two speak text only, so an image on the pasteboard was invisible to the
// bridge and could not cross at all. That is the whole feature.
//
// And they take their encoding from the environment, which is how a Persian
// copy came back as MacRoman and a pbcopy/pbpaste round trip still matched,
// because both ends mangled it the same way (docs/lessons.md, trap 2).
// NSPasteboard has no encoding to get wrong: bytes in, bytes out.
//
//   pbio kind          -> "<changeCount> image|text|none"
//   pbio read text     -> the text, as utf8, on stdout
//   pbio read image    -> the image, as png, on stdout
//   pbio write text    -> stdin becomes the pasteboard text
//   pbio write image   -> stdin (png) becomes the pasteboard image
import AppKit
import Foundation

let pb = NSPasteboard.general
let args = Array(CommandLine.arguments.dropFirst())

func imageData() -> Data? {
    if let png = pb.data(forType: .png) { return png }
    // A screenshot often arrives as TIFF only, so convert rather than miss it.
    guard let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
}

switch args.first {
case "kind":
    let kind = imageData() != nil ? "image" : (pb.string(forType: .string) != nil ? "text" : "none")
    print("\(pb.changeCount) \(kind)")
case "read":
    let data: Data? = args.count > 1 && args[1] == "image"
        ? imageData()
        : pb.string(forType: .string)?.data(using: .utf8)
    guard let d = data else { exit(1) }
    FileHandle.standardOutput.write(d)
case "write":
    let d = FileHandle.standardInput.readDataToEndOfFile()
    guard !d.isEmpty else { exit(1) }
    pb.clearContents()
    if args.count > 1 && args[1] == "image" { pb.setData(d, forType: .png) }
    else { pb.setString(String(decoding: d, as: UTF8.self), forType: .string) }
default:
    FileHandle.standardError.write(Data("usage: pbio kind | read text|image | write text|image\n".utf8))
    exit(2)
}
