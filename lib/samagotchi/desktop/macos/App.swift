// Chi Helper: the "Send to chi" Service opens the panel with the selection.
// No Dock icon (LSUIElement); it stays running after the first launch.
import AppKit

final class ServiceProvider: NSObject {
  weak var app: AppDelegate?

  // Info.plist NSServices: NSMessage = sendToChi.
  @objc func sendToChi(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
    guard let text = pboard.string(forType: .string) else {
      error.pointee = "No text in the selection" as NSString
      return
    }
    app?.open(text: text)
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  let panel = PanelController()
  let provider = ServiceProvider()
  /// A Service activates this app before the handler runs, so the app the
  /// text came from is the last other app that was frontmost.
  private var lastOtherApp: NSRunningApplication?

  func applicationDidFinishLaunching(_ notification: Notification) {
    provider.app = self
    NSApp.servicesProvider = provider
    NSUpdateDynamicServices()

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

  func open(text: String) {
    let from = sourceApp
    panel.show(text: text, source: from?.localizedName?.lowercased() ?? "desktop", returnTo: from)
  }
}

@main
struct ChiHelperMain {
  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
  }
}
