// The global hotkey (⌃⌥⌘N): opens the panel with the clipboard, for apps
// whose Services menu doesn't offer "Send to chi". Carbon hotkeys need no
// Accessibility permission. A clash with a system shortcut isn't reported
// (RegisterEventHotKey only knows other apps' hotkeys).
import Carbon.HIToolbox
import Foundation

final class Hotkey {
  static let label = "⌃⌥⌘N"
  static let statePath = ChiRunner.supportDir + "/hotkey.json"

  private var ref: EventHotKeyRef?
  private let action: () -> Void

  init(action: @escaping () -> Void) {
    self.action = action
  }

  /// Registers the hotkey and writes whether it worked for `chi desktop status`.
  @discardableResult
  func register() -> Bool {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let me = Unmanaged.passUnretained(self).toOpaque()
    InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
      let hotkey = Unmanaged<Hotkey>.fromOpaque(userData!).takeUnretainedValue()
      DispatchQueue.main.async { hotkey.action() }
      return noErr
    }, 1, &spec, me, nil)
    let id = EventHotKeyID(signature: OSType(0x4348_4950), id: 1)  // "CHIP"
    let status = RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey | cmdKey), id,
                                     GetApplicationEventTarget(), 0, &ref)
    writeState(registered: status == noErr, status: status)
    return status == noErr
  }

  private func writeState(registered: Bool, status: OSStatus) {
    let state: [String: Any] = ["keys": Self.label, "registered": registered, "status": Int(status)]
    guard let data = try? JSONSerialization.data(withJSONObject: state) else { return }
    try? FileManager.default.createDirectory(atPath: ChiRunner.supportDir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: Self.statePath, contents: data)
  }
}
