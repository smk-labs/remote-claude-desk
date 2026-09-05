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

// What is on the pasteboard, decided from the TYPE LIST alone.
//
// This is asked ten times a second, forever, so it must not touch the contents.
// It used to answer by fetching them: `imageData() != nil` pulled the whole
// picture out of the pasteboard server, and for a screenshot, which arrives as
// TIFF and no PNG, it also decoded that TIFF and re-encoded a PNG, purely to
// throw both away and print the word "image". The caller then skipped the item
// because the changeCount had not moved, so the entire cost bought nothing.
//
// The tell was not CPU on this process, which exits in milliseconds. It was the
// pasteboard server: ten full copies a second out of one shared, single-threaded
// service, which every other app has to queue behind. That is what a beachball
// in Claude Desktop, and an RDP window that stops repainting the moment you
// press Cmd+C, actually looked like from the outside.
//
// `pb.types` is the list, not the data. Same precedence as before: image wins
// over text, because a copy out of a web page carries both.
func pasteboardKind() -> String {
    let types = pb.types ?? []
    if types.contains(.png) || types.contains(.tiff) { return "image" }
    if types.contains(.string) { return "text" }
    return "none"
}

switch args.first {
case "kind":
    print("\(pb.changeCount) \(pasteboardKind())")
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
