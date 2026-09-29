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
  static let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("chi-helper", isDirectory: true)

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

  /// At launch: what a helper that quit mid-send left.
  static func sweep() {
    try? FileManager.default.removeItem(at: tempDir)
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
