// Chi Helper: the "Send to chi" Service opens the panel with the selection
// (text, or images: files in Finder, a picture in Preview), the hotkey with
// the clipboard (a screenshot too). No Dock icon (LSUIElement); it stays
// running after the first launch. `ChiHelper --login on|off|status` (run
// directly by chi desktop) manages the login item and exits;
// `ChiHelper --kitty list|send` is the kitty targets' seam (Kitty.swift),
// `ChiHelper --model-pick` the model chooser's (Models.swift),
// `ChiHelper --broadcast` the Everyone row's (Broadcast.swift).
import AppKit
import ServiceManagement

final class ServiceProvider: NSObject {
  weak var app: AppDelegate?

  // Info.plist NSServices: NSMessage = sendToChi.
  @objc func sendToChi(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
    let (text, images) = ImageIntake.read(pboard)
    guard !text.isEmpty || !images.isEmpty else {
      error.pointee = "No text or image in the selection" as NSString
      return
    }
    app?.open(text: text, images: images, origin: "selection")
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  let panel = PanelController()
  let provider = ServiceProvider()
  private var hotkey: Hotkey?
  /// A Service activates this app before the handler runs, so the app the
  /// text came from is the last other app that was frontmost.
  private var lastOtherApp: NSRunningApplication?

  func applicationDidFinishLaunching(_ notification: Notification) {
    provider.app = self
    ImageIntake.sweep()
    NSApp.servicesProvider = provider
    NSUpdateDynamicServices()
    hotkey = Hotkey { [weak self] in self?.openFromClipboard() }
    hotkey?.register()

    lastOtherApp = otherApp(NSWorkspace.shared.frontmostApplication)
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      if let app = self?.otherApp(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication) {
        self?.lastOtherApp = app
      }
    }
  }

  private func otherApp(_ app: NSRunningApplication?) -> NSRunningApplication? {
    app?.processIdentifier == getpid() ? nil : app
  }

  /// The app the text comes from: frontmost unless that is us.
  var sourceApp: NSRunningApplication? {
    otherApp(NSWorkspace.shared.frontmostApplication) ?? lastOtherApp
  }

  /// The hotkey doesn't activate us, so the frontmost app is the source.
  func openFromClipboard() {
    let (text, images) = ImageIntake.read(NSPasteboard.general)
    open(text: text, images: images, origin: "clipboard")
  }

  /// @param origin "clipboard" (the hotkey) or "selection" (the Service)
  func open(text: String, images: [PanelImage] = [], origin: String) {
    let from = sourceApp
    panel.show(text: text, images: images, origin: origin, source: from?.localizedName?.lowercased() ?? "desktop",
               returnTo: from)
  }
}

/// SMAppService only lets an app register itself, so chi desktop runs the
/// binary with --login. Prints the status name; exit 1 on failure.
func loginCommand(_ arg: String) -> Int32 {
  let service = SMAppService.mainApp
  do {
    switch arg {
    case "on": if service.status != .enabled { try service.register() }
    case "off": if service.status == .enabled || service.status == .requiresApproval { try service.unregister() }
    case "status": break
    default:
      FileHandle.standardError.write("usage: ChiHelper --login on|off|status\n".data(using: .utf8)!)
      return 2
    }
  } catch {
    FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
    return 1
  }
  let names: [SMAppService.Status: String] = [.notRegistered: "notRegistered", .enabled: "enabled",
                                              .requiresApproval: "requiresApproval", .notFound: "notFound"]
  print(names[service.status] ?? "unknown")
  return 0
}

@main
struct ChiHelperMain {
  static func main() {
    let args = CommandLine.arguments
    if args.count >= 2, args[1] == "--login" {
      exit(loginCommand(args.count >= 3 ? args[2] : ""))
    }
    if args.count >= 2, args[1] == "--kitty" {
      exit(kittyCommand(Array(args.dropFirst(2))))
    }
    if args.count >= 2, args[1] == "--model-pick" {
      exit(modelPickCommand(Array(args.dropFirst(2))))
    }
    if args.count >= 2, args[1] == "--broadcast" {
      exit(broadcastCommand(Array(args.dropFirst(2))))
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
  }
}
