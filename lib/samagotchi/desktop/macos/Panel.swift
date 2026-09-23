// The Spotlight-like panel: text on top, live sessions below, send with ⌘↵.
import AppKit
import SwiftUI

let noteCap = 16 * 1024

final class PanelModel: ObservableObject {
  enum Phase: Equatable { case loading, ready, sending, sent, failed }

  @Published var text = ""
  @Published var source = ""
  @Published var sessions: [LiveSession] = []
  @Published var selected: Set<String> = []
  @Published var phase: Phase = .loading
  @Published var message = ""

  static let lastChoiceKey = "lastSessionIds"

  var bytes: Int { text.utf8.count }
  var canSend: Bool {
    phase == .ready || phase == .failed
  }
  var sendEnabled: Bool {
    canSend && !selected.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// The last choice, where still live; else the only live session.
  func preselect() {
    let last = Set(UserDefaults.standard.stringArray(forKey: Self.lastChoiceKey) ?? [])
    let live = Set(sessions.map(\.id))
    selected = last.intersection(live)
    if selected.isEmpty, sessions.count == 1 { selected = [sessions[0].id] }
  }

  func toggle(_ id: String) {
    if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
  }

  /// In list order, only ids that are live and UUID-shaped.
  var selectedIds: [String] {
    sessions.filter { selected.contains($0.id) && $0.valid }.map(\.id)
  }
}

struct PanelView: View {
  @ObservedObject var model: PanelModel
  let send: () -> Void
  @FocusState private var textFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      ZStack(alignment: .topLeading) {
        if model.text.isEmpty {
          Text("Text to send to chi…")
            .font(.system(size: 17))
            .foregroundColor(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
        }
        TextEditor(text: $model.text)
          .font(.system(size: 17))
          .scrollContentBackground(.hidden)
          .focused($textFocused)
      }
      .frame(minHeight: 70, maxHeight: 170)
      .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)

      Divider().opacity(0.5)
      sessionList
      Divider().opacity(0.5)
      footer
    }
    .frame(width: 600)
    .onAppear { textFocused = true }
  }

  @ViewBuilder var sessionList: some View {
    VStack(alignment: .leading, spacing: 2) {
      switch model.phase {
      case .loading:
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Looking for live sessions…").foregroundColor(.secondary)
        }.padding(10)
      default:
        if model.sessions.isEmpty {
          Text(model.phase == .failed && !model.message.isEmpty ? "" : "No live sessions. Start one with `chi` in a terminal.")
            .foregroundColor(.secondary).padding(10)
        }
        ForEach(Array(model.sessions.prefix(9).enumerated()), id: \.element.id) { index, session in
          row(session, index: index)
        }
      }
    }
    .padding(6)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  func row(_ session: LiveSession, index: Int) -> some View {
    let on = model.selected.contains(session.id)
    return Button(action: { model.toggle(session.id) }) {
      HStack(spacing: 10) {
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 16))
          .foregroundColor(on ? .accentColor : .secondary)
        VStack(alignment: .leading, spacing: 1) {
          Text(session.desc?.isEmpty == false ? session.desc! : String(session.id.prefix(8)))
            .font(.system(size: 13, weight: .medium)).lineLimit(1)
          Text(session.shortCwd).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
        }
        Spacer()
        if session.busy == true {
          Circle().fill(Color.orange).frame(width: 7, height: 7).help("working on a turn")
        }
        Text("⌘\(index + 1)").font(.system(size: 11, design: .rounded)).foregroundColor(.secondary)
      }
      .padding(.horizontal, 8).padding(.vertical, 6)
      .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.accentColor.opacity(0.14) : Color.clear))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  var footer: some View {
    HStack(spacing: 10) {
      HStack(spacing: 4) {
        Image(systemName: "arrow.down.doc").font(.system(size: 11)).foregroundColor(.secondary)
        TextField("source", text: $model.source)
          .textFieldStyle(.plain)
          .font(.system(size: 12))
          .frame(width: 90)
      }
      .padding(.horizontal, 8).padding(.vertical, 4)
      .background(Capsule().fill(Color.primary.opacity(0.07)))

      Text(byteLabel)
        .font(.system(size: 11).monospacedDigit())
        .foregroundColor(model.bytes > noteCap ? .red : .secondary)

      Text(model.message)
        .font(.system(size: 11))
        .foregroundColor(model.phase == .failed ? .red : .secondary)
        .lineLimit(3)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)

      Button(action: send) {
        if model.phase == .sending { ProgressView().controlSize(.small) } else { Text("Send ⌘↵") }
      }
      .keyboardShortcut(.return, modifiers: .command)
      .disabled(!model.sendEnabled)
    }
    .padding(.horizontal, 14).padding(.vertical, 10)
  }

  var byteLabel: String {
    let kib = Double(model.bytes) / 1024
    return model.bytes < 1024 ? "\(model.bytes) B / 16 KB" : String(format: "%.1f KB / 16 KB", kib)
  }
}

final class KeyPanel: NSPanel {
  var onKey: ((NSEvent) -> Bool)?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override func cancelOperation(_ sender: Any?) { close() }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if onKey?(event) == true { return true }
    return super.performKeyEquivalent(with: event)
  }
}

final class PanelController: NSObject, NSWindowDelegate {
  let model = PanelModel()
  let runner = ChiRunner()
  private var panel: KeyPanel!
  private var returnTo: NSRunningApplication?

  override init() {
    super.init()
    panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 340),
                     styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                     backing: .buffered, defer: true)
    panel.titlebarAppearsTransparent = true
    panel.titleVisibility = .hidden
    [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
    panel.isMovableByWindowBackground = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.backgroundColor = .clear
    panel.delegate = self

    let effect = NSVisualEffectView()
    effect.material = .popover
    effect.blendingMode = .behindWindow
    effect.state = .active
    let hosting = NSHostingView(rootView: PanelView(model: model, send: { [weak self] in self?.send() }))
    hosting.translatesAutoresizingMaskIntoConstraints = false
    effect.addSubview(hosting)
    NSLayoutConstraint.activate([
      hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
      hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
      hosting.topAnchor.constraint(equalTo: effect.topAnchor),
      hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
    ])
    panel.contentView = effect
    panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
  }

  /// ⌘1…⌘9 toggle a session.
  private func handleKey(_ event: NSEvent) -> Bool {
    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
          let chars = event.charactersIgnoringModifiers, let n = Int(chars), (1...9).contains(n),
          n <= model.sessions.count else { return false }
    model.toggle(model.sessions[n - 1].id)
    return true
  }

  /// @param returnTo the app to give focus back to on close
  func show(text: String, source: String, returnTo app: NSRunningApplication?) {
    returnTo = app
    model.text = text
    model.source = source
    model.message = ""
    model.phase = .loading
    placeOnActiveScreen()
    panel.makeKeyAndOrderFront(nil)
    loadSessions()
  }

  private func placeOnActiveScreen() {
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    guard let frame = screen?.visibleFrame else { return }
    panel.layoutIfNeeded()
    let size = panel.frame.size
    panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.62 - size.height / 2))
  }

  private func loadSessions() {
    runner.liveSessions { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let sessions):
        self.model.sessions = sessions
        self.model.preselect()
        self.model.phase = .ready
      case .failure(let error):
        self.model.sessions = []
        self.model.phase = .failed
        self.model.message = error.description
      }
    }
  }

  func send() {
    let ids = model.selectedIds
    guard model.sendEnabled, !ids.isEmpty else { return }
    model.phase = .sending
    model.message = ""
    UserDefaults.standard.set(ids, forKey: PanelModel.lastChoiceKey)
    let source = model.source.trimmingCharacters(in: .whitespacesAndNewlines)
    var args = ["note"]
    if !source.isEmpty { args += ["--source", source] }
    args += ids
    runner.run(args, stdin: Data(model.text.utf8)) { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        self.model.phase = .failed
        self.model.message = error.description
      case .success(let r):
        let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.timedOut {
          self.model.phase = .failed
          self.model.message = "chi note took over \(Int(self.runner.timeout)) s and was stopped; the note may be partly delivered. \(out)"
        } else if r.status == 0 {
          self.model.phase = .sent
          self.model.message = out.isEmpty ? "Sent." : out
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if self?.model.phase == .sent { self?.panel.close() }
          }
        } else {
          self.model.phase = .failed
          self.model.message = [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
        }
      }
    }
  }

  func windowWillClose(_ notification: Notification) {
    returnTo?.activate()
    returnTo = nil
  }
}
