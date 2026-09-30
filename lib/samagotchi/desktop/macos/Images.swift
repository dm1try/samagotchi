// Images for the panel: what a pasteboard (the clipboard, the Service's,
// a drop) carries, as files `chi send --image` can read. Image files are
// passed as they are; image data (a ⌃⇧⌘4 screenshot, Preview, Safari's
// Copy Image) is written to a temp file first, deleted after the send.
import AppKit
import UniformTypeIdentifiers

/// The Bridge's cap on one turn's images.
let maxImages = 20

struct PanelImage: Identifiable, Equatable {
  let id = UUID()
  let url: URL
  /// Written by the helper (image data), so the helper deletes it.
  let temp: Bool
  let thumbnail: NSImage?

  var name: String { url.lastPathComponent }

  init(url: URL, temp: Bool) {
    self.url = url
    self.temp = temp
    thumbnail = NSImage(contentsOf: url)
  }

  static func == (a: PanelImage, b: PanelImage) -> Bool { a.id == b.id }
}

enum ImageIntake {
  /// $TMPDIR when set (launchd sets it; a spec points it elsewhere), else
  /// the user's temp folder.
  static let tempRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 }
    ?? NSTemporaryDirectory(), isDirectory: true)
  static let tempDir = tempRoot.appendingPathComponent("chi-helper", isDirectory: true)

  /// A pasteboard's content for the panel, in this order: image files
  /// (Finder ⌘C, a Service on files) with no text; else its text, as before
  /// (an office app's copy carries a picture of the cells too: the text
  /// wins); else image data (png, then tiff). A non-image file is skipped.
  static func read(_ pb: NSPasteboard) -> (text: String, images: [PanelImage]) {
    let files = imageFiles(pb)
    if !files.isEmpty { return ("", files) }
    if let text = pb.string(forType: .string), !text.isEmpty { return (text, []) }
    return ("", imageData(pb))
  }

  /// A drop adds images only: text dropped on the fields is theirs.
  static func dropped(_ pb: NSPasteboard) -> [PanelImage] {
    let files = imageFiles(pb)
    return files.isEmpty ? imageData(pb) : files
  }

  static func imageFiles(_ pb: NSPasteboard) -> [PanelImage] {
    let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    return urls.filter(isImage).prefix(maxImages).map { PanelImage(url: $0, temp: false) }
  }

  static func isImage(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .image) == true
  }

  static func imageData(_ pb: NSPasteboard) -> [PanelImage] {
    for (type, ext) in [(NSPasteboard.PasteboardType.png, "png"), (.tiff, "tiff")] {
      guard let data = pb.data(forType: type) else { continue }
      // A folder per image, so the name chi shows is "clipboard.png".
      let dir = tempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
      do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("clipboard.\(ext)")
        try data.write(to: url)
        return [PanelImage(url: url, temp: true)]
      } catch {
        return []
      }
    }
    return []
  }

  static func delete(_ images: [PanelImage]) {
    for image in images where image.temp {
      try? FileManager.default.removeItem(at: image.url.deletingLastPathComponent())
    }
  }

  /// Images pasted into kitty windows, kept for the agent to read after
  /// the send: never deleted by it, swept at launch after a week.
  static let sentDir = tempRoot.appendingPathComponent("chi-helper-sent", isDirectory: true)
  static let sentMaxAge: TimeInterval = 7 * 86_400

  /// The paths a kitty paste names: an image the helper wrote is copied to
  /// sentDir first (the send deletes the original), with no spaces in its
  /// name; a file of the user's is named as it is. Call before any send
  /// job starts. An image that can't be copied is left out.
  static func keepForPaste(_ images: [PanelImage]) -> [String] {
    images.compactMap { image in
      guard image.temp else { return image.url.path }
      let ext = image.url.pathExtension.isEmpty ? "png" : image.url.pathExtension
      let copy = sentDir.appendingPathComponent("\(UUID().uuidString).\(ext)")
      do {
        try FileManager.default.createDirectory(at: sentDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: image.url, to: copy)
        return copy.path
      } catch {
        return nil
      }
    }
  }

  /// At launch: what a helper that quit mid-send left, and pasted images
  /// older than a week.
  static func sweep(now: Date = Date()) {
    try? FileManager.default.removeItem(at: tempDir)
    let fm = FileManager.default
    for name in (try? fm.contentsOfDirectory(atPath: sentDir.path)) ?? [] {
      let url = sentDir.appendingPathComponent(name)
      let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? now
      if now.timeIntervalSince(modified) > sentMaxAge { try? fm.removeItem(at: url) }
    }
  }
}

/// The panel's background, taking dropped images anywhere on the panel.
final class DropEffectView: NSVisualEffectView {
  var onDrop: (([PanelImage]) -> Void)?

  override init(frame: NSRect) {
    super.init(frame: frame)
    registerForDraggedTypes([.fileURL, .png, .tiff])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    carriesImages(sender.draggingPasteboard) ? .copy : []
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let images = ImageIntake.dropped(sender.draggingPasteboard)
    guard !images.isEmpty else { return false }
    onDrop?(images)
    return true
  }

  private func carriesImages(_ pb: NSPasteboard) -> Bool {
    let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    return urls.contains(where: ImageIntake.isImage) || pb.availableType(from: [.png, .tiff]) != nil
  }
}
