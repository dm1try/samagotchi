// The Spotlight-like panel: a message line on top, the images (a screenshot,
// Finder files, drops) as thumbnails, the text (selection or clipboard)
// below as quoted context, then a "New session" row and the sessions. ⏎
// sends a message (`chi send`, or `chi send --new` on the new row, with
// `--image` per image), ⌘⏎ a note (`chi note`, text only), ⇧⏎ a newline.
import AppKit
import SwiftUI

let noteCap = 16 * 1024

final class PanelModel: ObservableObject {
  enum Phase: Equatable { case loading, ready, sending, sent, failed }

  /// The message line; `-m` of `chi send`.
  @Published var prompt = ""
  /// The selection or clipboard: the quoted context of a message, or a note.
  @Published var text = ""
  @Published var source = ""
  /// Sent as `--image` with a message; notes are text only.
  @Published var images: [PanelImage] = []
  @Published var sessions: [LiveSession] = []
  @Published var selected: Set<String> = []
  /// The "New session" row; never together with sessions (`--new` takes no ids).
  @Published var newSelected = false
  @Published var phase: Phase = .loading
  @Published var message = ""

  static let lastChoiceKey = "lastSessionIds"

  var bytes: Int { prompt.utf8.count + text.utf8.count }
  var canSend: Bool {
    phase == .ready || phase == .failed
  }
  var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
  var hasContext: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  var sendEnabled: Bool {
    canSend && (newSelected || !selected.isEmpty) && (!trimmedPrompt.isEmpty || hasContext)
  }
  var live: [LiveSession] { sessions.filter { !$0.recent } }

  /// Up to maxImages; the rest is dropped (and its temp files deleted).
  func add(_ new: [PanelImage]) {
    let room = max(0, maxImages - images.count)
    images += new.prefix(room)
    ImageIntake.delete(Array(new.dropFirst(room)))
    if new.count > room { message = "At most \(maxImages) images" }
  }

  func remove(_ image: PanelImage) {
    images.removeAll { $0 == image }
    ImageIntake.delete([image])
  }
  var recent: [LiveSession] { sessions.filter(\.recent) }

  /// The last choice, where still live; else the only live session; else,
  /// with none live, the new row. A recent (stopped) one is never
  /// preselected: a message would wake it.
  func preselect() {
    let last = Set(UserDefaults.standard.stringArray(forKey: Self.lastChoiceKey) ?? [])
    selected = last.intersection(Set(live.map(\.id)))
    if selected.isEmpty, live.count == 1 { selected = [live[0].id] }
    newSelected = live.isEmpty
  }

  func toggle(_ id: String) {
    if selected.contains(id) { selected.remove(id) } else { selected.insert(id); newSelected = false }
  }

  func toggleNew() {
    newSelected.toggle()
    if newSelected { selected = [] }
  }

  /// Where a new session starts: the helper runs in $HOME, which is in no
  /// project, so the folder of the most recently updated live session, else
  /// of the newest recent one, else home.
  var newSessionDir: String {
    let exists = { (s: LiveSession) -> Bool in
      var dir: ObjCBool = false
      return s.cwd.map { FileManager.default.fileExists(atPath: $0, isDirectory: &dir) && dir.boolValue } ?? false
    }
    let newest = { (list: [LiveSession]) in list.filter(exists).max { ($0.updated ?? .distantPast) < ($1.updated ?? .distantPast) } }
    return (newest(live) ?? newest(recent))?.cwd ?? NSHomeDirectory()
  }

  var newSessionFolder: String {
    let dir = newSessionDir
    return dir == NSHomeDirectory() ? "~" : (dir as NSString).lastPathComponent
  }

  /// In list order, only ids that are live and UUID-shaped.
  var selectedIds: [String] {
    sessions.filter { selected.contains($0.id) && $0.valid }.map(\.id)
  }
}

enum SendKind { case message, note }

struct PanelView: View {
  @ObservedObject var model: PanelModel
  let send: (SendKind) -> Void
  @FocusState private var promptFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      // The message is required with images, as in the web.
      TextField(model.images.isEmpty ? "Ask chi…" : "Say something about the image…", text: $model.prompt, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.system(size: 17))
        .lineLimit(1...4)
        .focused($promptFocused)
        .padding(.horizontal, 19).padding(.top, 14).padding(.bottom, 8)

      imageStrip

      ZStack(alignment: .topLeading) {
        if model.text.isEmpty {
          Text("Context, quoted above the message (or the note)…")
            .font(.system(size: 13))
            .foregroundColor(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
        }
        TextEditor(text: $model.text)
          .font(.system(size: 13))
          .foregroundColor(.secondary)
          .scrollContentBackground(.hidden)
      }
      .frame(minHeight: 44, maxHeight: 150)
      .padding(.leading, 14).padding(.trailing, 14).padding(.bottom, 8)
      .overlay(alignment: .leading) {
        Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 2).padding(.leading, 12).padding(.bottom, 8)
      }

      Divider().opacity(0.5)
      sessionList
      Divider().opacity(0.5)
      footer
    }
    .frame(width: 600)
    .onAppear { promptFocused = true }
  }

  @ViewBuilder var imageStrip: some View {
    if !model.images.isEmpty {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(model.images) { image in
            Thumbnail(image: image, removable: model.phase != .sending) { model.remove(image) }
          }
        }
        .padding(.horizontal, 19).padding(.vertical, 2)
      }
      .frame(height: 52)
      .padding(.bottom, 8)
    }
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
        newRow
        ForEach(Array(model.sessions.prefix(9).enumerated()), id: \.element.id) { index, session in
          if session.recent && index == model.live.count {
            HStack(spacing: 6) {
              Text("recent").font(.system(size: 11)).foregroundColor(.secondary)
              Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
            }
            .padding(.horizontal, 8).padding(.top, index == 0 ? 2 : 6)
          }
          row(session, index: index)
        }
      }
    }
    .padding(6)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  var newRow: some View {
    let on = model.newSelected
    return Button(action: { model.toggleNew() }) {
      HStack(spacing: 10) {
        Image(systemName: on ? "plus.circle.fill" : "plus.circle")
          .font(.system(size: 16))
          .foregroundColor(on ? .accentColor : .secondary)
        VStack(alignment: .leading, spacing: 1) {
          Text("New session in \(model.newSessionFolder)").font(.system(size: 13, weight: .medium)).lineLimit(1)
          Text(LiveSession.shorten(model.newSessionDir)).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
        }
        Spacer()
        Text("⌘0").font(.system(size: 11, design: .rounded)).foregroundColor(.secondary)
      }
      .padding(.horizontal, 8).padding(.vertical, 6)
      .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.accentColor.opacity(0.14) : Color.clear))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("start a session with the message, as the web does (chi send --new); a note needs a session")
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
        if session.recent {
          Text(session.age()).font(.system(size: 11)).foregroundColor(.secondary)
            .help("stopped: a message starts its worker; a note waits for its next start")
        }
        if session.busy == true {
          Circle().fill(Color.orange).frame(width: 7, height: 7).help("working on a turn")
        }
        Text("⌘\(index + 1)").font(.system(size: 11, design: .rounded)).foregroundColor(.secondary)
      }
      .padding(.horizontal, 8).padding(.vertical, 6)
      .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.accentColor.opacity(0.14) : Color.clear))
      .contentShape(Rectangle())
      .opacity(session.recent ? 0.6 : 1)
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

      // ⏎ and ⌘⏎ are handled by the panel (KeyPanel.sendEvent), whatever
      // has the focus; the buttons are for the mouse.
      Button("Note ⌘⏎") { send(.note) }
        .disabled(!model.sendEnabled)
        .help("add it as background the model sees on its next turn; starts no turn")
      Button(action: { send(.message) }) {
        if model.phase == .sending { ProgressView().controlSize(.small) } else { Text("Send ⏎") }
      }
      .disabled(!model.sendEnabled)
      .help("send it as your message: a turn runs")
    }
    .padding(.horizontal, 14).padding(.vertical, 10)
  }

  var byteLabel: String {
    let kib = Double(model.bytes) / 1024
    return model.bytes < 1024 ? "\(model.bytes) B / 16 KB" : String(format: "%.1f KB / 16 KB", kib)
  }
}

/// One image in the strip: 48 px high, its name as a tooltip, ✕ on hover.
struct Thumbnail: View {
  let image: PanelImage
  let removable: Bool
  let remove: () -> Void
  @State private var hover = false

  var body: some View {
    Group {
      if let thumb = image.thumbnail {
        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
      } else {
        Image(systemName: "photo").font(.system(size: 20)).foregroundColor(.secondary).frame(width: 48)
      }
    }
    .frame(height: 48)
    .frame(maxWidth: 120)
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
    .overlay(alignment: .topTrailing) {
      if hover && removable {
        Button(action: remove) {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 14))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, Color.black.opacity(0.55))
        }
        .buttonStyle(.plain)
        .padding(3)
        .help("remove")
      }
    }
    .onHover { hover = $0 }
    .help(image.name)
  }
}

final class KeyPanel: NSPanel {
  var onKey: ((NSEvent) -> Bool)?
  /// Return with these modifiers; true when handled.
  var onReturn: ((NSEvent.ModifierFlags) -> Bool)?

  /// Return is taken here, before the text views see it, so ⏎ sends from
  /// either field. An input method composing text keeps its Return.
  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76,
       (firstResponder as? NSTextView)?.hasMarkedText() != true,
       onReturn?(event.modifierFlags.intersection([.shift, .command, .option, .control])) == true {
      return
    }
    super.sendEvent(event)
  }

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
  /// Images a running `chi send` still reads: not deleted on close.
  private var inFlight: Set<UUID> = []

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

    let effect = DropEffectView()
    effect.material = .popover
    effect.blendingMode = .behindWindow
    effect.state = .active
    let hosting = NSHostingView(rootView: PanelView(model: model, send: { [weak self] kind in self?.send(kind) }))
    hosting.translatesAutoresizingMaskIntoConstraints = false
    effect.addSubview(hosting)
    NSLayoutConstraint.activate([
      hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
      hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
      hosting.topAnchor.constraint(equalTo: effect.topAnchor),
      hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
    ])
    effect.onDrop = { [weak self] images in self?.model.add(images) }
    panel.contentView = effect
    panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
    panel.onReturn = { [weak self] flags in self?.handleReturn(flags) ?? false }
  }

  /// ⏎ message, ⌘⏎ note, ⇧⏎ a newline in the focused field.
  private func handleReturn(_ flags: NSEvent.ModifierFlags) -> Bool {
    switch flags {
    case []: send(.message)
    case .command: send(.note)
    case .shift:
      (panel.firstResponder as? NSTextView)?.insertNewlineIgnoringFieldEditor(nil)
    default: return false
    }
    return true
  }

  /// ⌘1…⌘9 toggle a session, ⌘0 the new row.
  private func handleKey(_ event: NSEvent) -> Bool {
    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
          let chars = event.charactersIgnoringModifiers, let n = Int(chars),
          n <= model.sessions.count else { return false }
    if n == 0 { model.toggleNew() } else { model.toggle(model.sessions[n - 1].id) }
    return true
  }

  /// @param returnTo the app to give focus back to on close
  func show(text: String, images: [PanelImage] = [], source: String, returnTo app: NSRunningApplication?) {
    returnTo = app
    // A show on an open panel resets it without a close.
    dropImages()
    model.prompt = ""
    model.images = []
    model.add(images)
    model.text = text
    model.source = source
    model.message = ""
    model.newSelected = false
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
    runner.sessions { [weak self] result in
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

  func send(_ kind: SendKind) {
    let ids = model.selectedIds
    let new = model.newSelected
    if kind == .note, !model.images.isEmpty {
      NSSound.beep()
      model.message = "Notes are text only: ⏎ sends the image as a message"
      return
    }
    // A note into a session that doesn't exist yet makes no sense.
    guard model.sendEnabled, new ? kind == .message : !ids.isEmpty else { NSSound.beep(); return }
    model.phase = .sending
    model.message = ""
    if !new {
      UserDefaults.standard.set(ids.filter { id in model.live.contains { $0.id == id } }, forKey: PanelModel.lastChoiceKey)
    }
    let prompt = model.trimmedPrompt
    let command: String
    var args: [String]
    let stdin: Data?
    switch kind {
    case .message:
      // stdin is the quoted context; without -m, chi takes it as the message.
      command = "chi send"
      args = new ? ["send", "--new", "--dir", model.newSessionDir] : ["send"]
      if !prompt.isEmpty { args += ["-m", prompt] }
      args += model.images.flatMap { ["--image", $0.url.path] }
      stdin = model.hasContext ? Data(model.text.utf8) : nil
    case .note:
      command = "chi note"
      args = ["note"]
      let source = model.source.trimmingCharacters(in: .whitespacesAndNewlines)
      if !source.isEmpty { args += ["--source", source] }
      let parts = [prompt, model.hasContext ? model.text : ""].filter { !$0.isEmpty }
      stdin = Data(parts.joined(separator: "\n\n").utf8)
    }
    if !new { args += ids }
    let images = kind == .message ? model.images : []
    inFlight.formUnion(images.map(\.id))
    // Reading, converting and a new worker's start take longer than text.
    let timeout = images.isEmpty ? runner.timeout : 30
    runner.run(args, stdin: stdin, timeout: timeout) { [weak self] result in
      guard let self else { return }
      self.inFlight.subtract(images.map(\.id))
      // Sent: the temp files go (and the thumbnails). Else they stay for
      // another try, unless the panel was closed or reopened meanwhile.
      var sent = false
      if case .success(let r) = result { sent = r.status == 0 && !r.timedOut }
      if sent { self.model.images.removeAll { images.contains($0) } }
      ImageIntake.delete(images.filter { !self.model.images.contains($0) })
      switch result {
      case .failure(let error):
        self.model.phase = .failed
        self.model.message = error.description
      case .success(let r):
        let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.timedOut {
          self.model.phase = .failed
          let what = kind == .note ? "the note may be partly delivered" : "the message may not have been sent"
          self.model.message = "\(command) took over \(Int(timeout)) s and was stopped; \(what). \(out)"
        } else if r.status == 0 {
          self.model.phase = .sent
          // --new prints "<full id>  started".
          self.model.message = out.isEmpty ? "Sent." : new ? "started \(out.prefix(8))…" : out
          // Long enough to read a "waits for the session's next start" line.
          let linger = out.contains("waits for") || out.contains("started") ? 3.0 : 1.0
          DispatchQueue.main.asyncAfter(deadline: .now() + linger) { [weak self] in
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
    dropImages()
    returnTo?.activate()
    returnTo = nil
  }

  /// The panel's images leave it; their temp files go unless a send still
  /// reads them (its completion deletes them).
  private func dropImages() {
    ImageIntake.delete(model.images.filter { !inFlight.contains($0.id) })
    model.images = []
  }
}
