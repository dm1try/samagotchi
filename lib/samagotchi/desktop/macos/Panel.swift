// The Spotlight-like panel: a message line on top, the images (a screenshot,
// Finder files, drops) as thumbnails, the text (selection or clipboard)
// below as quoted context, then a "New session" row, an "Everyone it
// concerns" row and the targets: live sessions, agents in terminals
// (AgentTerminal.swift: kitty windows, tmux panes), recent sessions. ⏎ sends a message
// (`chi send`, or `chi send --new` on the new row, with `--image` per image;
// pasted with Enter into an agent's terminal), ⌘⏎ a note (`chi note`, text
// only; `chi broadcast` on the Everyone row, Broadcast.swift), ⌥⏎ a paste
// without Enter (agents in terminals only), ⇧⏎ a newline. ⌘M (or a click on
// the new row's model) opens the model chooser for a new session in place of
// the targets (Models.swift). Remotes' sessions (`chi remote ls`) follow in
// a section per remote, "on studio", sent with `chi --remote studio …`.
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
  /// The path the opening text and images took: "clipboard" (the hotkey)
  /// or "selection" (the Service); "" when the panel opened empty.
  @Published var origin = ""
  /// Sent as `--image` with a message; notes are text only.
  @Published var images: [PanelImage] = []
  /// The thumbnail under the pointer (shows its ✕). Kept here, not in a
  /// @State: some Command Line Tools SDKs want the SwiftUIMacros plugin for
  /// @State and don't ship it ("plugin for module 'SwiftUIMacros' not found").
  @Published var hoveredImage: UUID?
  /// This Mac's sessions.
  @Published var sessions: [LiveSession] = []
  /// The remotes' sections, in `chi remote ls` order, each filled in as it
  /// answers; never the previous open's (a stale row could send to a
  /// stopped worker unseen).
  @Published var remoteSections: [RemoteSection] = []
  /// Agents in terminals, and the terminals launch.json switches on
  /// (none: no agent rows and no note).
  @Published var agentTargets: [AgentTarget] = []
  @Published var agentTerminalNames: [String] = []
  /// Set once the listing answered with no rows: "no agents in kitty"
  /// (the terminals that answered).
  @Published var agentNote: String?
  /// Why a terminal can't be asked, with or without rows; " · " between two.
  @Published var agentErrors: String?
  /// Session keys (LiveSession.key: a remote's carry its name) and agent
  /// keys (never alike: UUIDs vs paths).
  @Published var selected: Set<String> = []
  /// The user changed the selection: a late agent listing keeps it.
  var touched = false
  /// The "New session" row; never together with sessions (`--new` takes no ids).
  @Published var newSelected = false
  /// The "Everyone it concerns" row: ⌘⏎ broadcasts (`chi broadcast`);
  /// never together with the new row or picked targets.
  @Published var everyoneSelected = false
  /// The model a new session starts on (`chi self --model`), for the new
  /// row's hint; nil while unknown.
  @Published var newModel: String?
  /// `chi models`' last answer, kept across opens and refreshed on each.
  @Published var modelList: ModelList?
  @Published var modelsLoading = false
  /// Why the last refresh failed (the older list, if any, stays).
  @Published var modelsError: String?
  /// The new session's model; nil: the default (no `--model`).
  @Published var pickedModel: String?
  /// The user picked during this open: a late list doesn't undo it.
  var pickTouched = false
  @Published var recentModels: [String] = UserDefaults.standard.stringArray(forKey: ModelPick.recentKey) ?? []
  /// The chooser replaces the targets while open.
  @Published var pickerOpen = false
  @Published var modelQuery = "" {
    didSet { pickerIndex = modelQuery.trimmingCharacters(in: .whitespaces).isEmpty || chooserRows.count < 2 ? 0 : 1 }
  }
  /// The highlighted chooser row (↑/↓, ⏎ picks it).
  @Published var pickerIndex = 0
  @Published var phase: Phase = .loading
  @Published var message = ""

  static let lastChoiceKey = "lastSessionIds"
  /// The remembered keys in place of UserDefaults' (a headless seam's).
  var lastChoice: [String]?

  var bytes: Int { prompt.utf8.count + text.utf8.count }
  var canSend: Bool {
    phase == .ready || phase == .failed
  }
  var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
  var hasContext: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  /// A note's text (stdin of `chi note`): the message line, then the context.
  var noteText: String { [trimmedPrompt, hasContext ? text : ""].filter { !$0.isEmpty }.joined(separator: "\n\n") }
  var sendEnabled: Bool {
    canSend && (newSelected || everyoneSelected || !selectedSessions.isEmpty || !selectedAgents.isEmpty)
      && (!trimmedPrompt.isEmpty || hasContext)
  }
  var live: [LiveSession] { sessions.filter { !$0.recent } }

  /// This Mac's rows: live sessions (oldest started first: their numbers
  /// stay put), then agents in terminals, then recent sessions; the panel
  /// shows the first nine.
  var localTargets: [Target] { live.map(Target.chi) + agentTargets.map(Target.agent) + recent.map(Target.chi) }

  /// One list for rows, ⌘ numbers and selection: this Mac's nine, then
  /// the remotes' rows, so ⌘1…⌘9 number this Mac's first.
  var targets: [Target] { Array(localTargets.prefix(9)) + remoteSessions.map(Target.chi) }

  /// A remote's section as shown: its rows without a session listed
  /// before (this Mac's, an earlier remote's: one Studio by two addresses,
  /// or a remote that is this Mac), and the ⌘ index of its first row.
  struct RemoteGroup: Identifiable {
    let section: RemoteSection
    let rows: [LiveSession]
    let firstIndex: Int
    var id: String { section.name }
  }

  var remoteGroups: [RemoteGroup] {
    var seen = Set(sessions.map(\.id))
    var index = min(localTargets.count, 9)
    return remoteSections.map { section in
      let rows = section.sessions.filter { seen.insert($0.id).inserted }
      defer { index += rows.count }
      return RemoteGroup(section: section, rows: rows, firstIndex: index)
    }
  }

  var remoteSessions: [LiveSession] { remoteGroups.flatMap(\.rows) }

  /// Up to maxImages; the rest is dropped (and its temp files deleted).
  func add(_ new: [PanelImage]) {
    let room = max(0, maxImages - images.count)
    images += new.prefix(room)
    ImageIntake.delete(Array(new.dropFirst(room)))
    if new.count > room { message = "At most \(maxImages) images" }
  }

  func remove(_ image: PanelImage) {
    images.removeAll { $0 == image }
    if hoveredImage == image.id { hoveredImage = nil }
    ImageIntake.delete([image])
  }
  /// Leaving one thumbnail may come after entering the next.
  func hover(_ image: PanelImage, _ inside: Bool) {
    if inside { hoveredImage = image.id } else if hoveredImage == image.id { hoveredImage = nil }
  }
  var recent: [LiveSession] { sessions.filter(\.recent) }

  /// The model a new session starts on without `--model`.
  var defaultModelName: String? { modelList?.default ?? newModel }

  /// What the new row shows: the pick, else the default as resolved (as
  /// `chi self --model` names it before the list is in: no flip).
  var shownModel: String? { pickedModel ?? defaultModelName }

  /// `--model` for `chi send --new`, verbatim; nil for the default.
  var modelForSend: String? {
    guard let picked = pickedModel else { return nil }
    if let standard = defaultModelName, ModelPick.same(picked, standard) { return nil }
    return picked
  }

  var chooserRows: [ModelRow] {
    ModelPick.chooserRows(list: modelList, fallbackDefault: newModel, recents: recentModels, query: modelQuery)
  }

  /// A failed refresh, or the hosts that failed in the last list.
  var modelsNote: String? {
    if let modelsError { return modelsError }
    let warnings = modelList?.warnings ?? []
    return warnings.isEmpty ? nil : warnings.joined(separator: "; ")
  }

  func isCurrent(_ row: ModelRow) -> Bool {
    row.kind == .standard ? modelForSend == nil : pickedModel.map { ModelPick.same($0, row.name) } ?? false
  }

  /// Opens the chooser on the new row, the current pick highlighted.
  func openPicker() {
    touched = true
    newSelected = true
    everyoneSelected = false
    selected = []
    modelQuery = ""
    pickerIndex = chooserRows.firstIndex(where: isCurrent) ?? 0
    pickerOpen = true
  }

  func closePicker() {
    pickerOpen = false
    modelQuery = ""
  }

  func movePicker(_ delta: Int) {
    let count = chooserRows.count
    guard count > 0 else { return }
    pickerIndex = min(max(pickerIndex + delta, 0), count - 1)
  }

  /// The pick is remembered (global, D2): the last one and five recent.
  func choose(_ row: ModelRow) {
    pickTouched = true
    newSelected = true
    everyoneSelected = false
    selected = []
    if row.kind == .standard {
      pickedModel = nil
      UserDefaults.standard.removeObject(forKey: ModelPick.pickKey)
    } else {
      pickedModel = row.name
      UserDefaults.standard.set(row.name, forKey: ModelPick.pickKey)
      recentModels = ModelPick.pushRecent(recentModels, row.name)
      UserDefaults.standard.set(recentModels, forKey: ModelPick.recentKey)
    }
    closePicker()
  }

  /// The remembered pick against the list as it is now (ModelPick.keep);
  /// one that isn't offered any more is forgotten, with a note.
  func applyStoredPick() {
    guard !pickTouched else { return }
    let kept = ModelPick.keep(UserDefaults.standard.string(forKey: ModelPick.pickKey), in: modelList)
    pickedModel = kept.pick
    if let note = kept.note {
      UserDefaults.standard.removeObject(forKey: ModelPick.pickKey)
      if message.isEmpty { message = note }
    }
  }

  /// The last choice, where still live or listed (a remote's live row
  /// too: the hint names its machine); else this Mac's only live session
  /// (never a remote's); else, with none live here and nothing chosen, the
  /// new row. A recent (stopped) one is never preselected: a message would
  /// wake it.
  func preselect() {
    let last = Set(lastChoice ?? UserDefaults.standard.stringArray(forKey: Self.lastChoiceKey) ?? [])
    let remoteLive = remoteSessions.filter { !$0.recent }
    selected = last.intersection(Set(live.map(\.key) + remoteLive.map(\.key) + agentTargets.map(\.key)))
    if selected.isEmpty, live.count == 1 { selected = [live[0].key] }
    newSelected = live.isEmpty && selected.isEmpty
  }

  func toggle(_ id: String) {
    touched = true
    if selected.contains(id) { selected.remove(id) } else { selected.insert(id); newSelected = false; everyoneSelected = false }
  }

  func toggleNew() {
    touched = true
    newSelected.toggle()
    if newSelected { selected = []; everyoneSelected = false }
  }

  /// The preselected session is dropped: a broadcast picks its own.
  func toggleEveryone() {
    touched = true
    everyoneSelected.toggle()
    if everyoneSelected { selected = []; newSelected = false }
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

  /// This Mac's listing answered: its rows, and the preselection unless
  /// the user already chose (⌘0, ⌘M while it listed).
  func showSessions(_ result: Result<[LiveSession], ChiError>) {
    switch result {
    case .success(let sessions):
      self.sessions = sessions
      if !touched { preselect() }
      phase = .ready
    case .failure(let error):
      sessions = []
      phase = .failed
      message = error.description
    }
  }

  /// `chi remote ls` answered: a section per remote, each asking.
  func startRemotes(_ names: [String]) {
    remoteSections = names.map { RemoteSection(name: $0) }
  }

  /// One remote answered: its rows or its line. It preselects only when
  /// nothing is ticked yet and the panel is ready: a late answer never
  /// changes a selection (the user may be typing to it, and the "→ studio"
  /// hint would come too late), nor one being sent or failed.
  func showRemote(_ name: String, _ result: Result<[LiveSession], ChiError>) {
    guard let index = remoteSections.firstIndex(where: { $0.name == name }) else { return }
    var section = RemoteSection(name: name, loading: false)
    switch result {
    case .success(let sessions): section.sessions = sessions
    case .failure(let error): section.error = error.description
    }
    remoteSections[index] = section
    if phase == .ready, !touched, selected.isEmpty, !newSelected, !everyoneSelected { preselect() }
  }

  /// The ticked sessions, this Mac's then the remotes', in list order;
  /// only UUID-shaped ids.
  var selectedSessions: [LiveSession] {
    (sessions + remoteSessions).filter { selected.contains($0.key) && $0.valid }
  }

  /// The message field's hint while a remote's row is ticked: " → studio"
  /// (both machines likely have the same paths); "" otherwise.
  var machineHint: String {
    var names: [String] = []
    for name in selectedSessions.compactMap(\.remote) where !names.contains(name) { names.append(name) }
    return names.isEmpty ? "" : " → " + names.joined(separator: ", ")
  }

  /// A listing's answer: the rows, "no agents in kitty" when there are
  /// none, and why a terminal can't be asked.
  func showAgents(_ targets: [AgentTarget], errors: [(name: String, error: AgentTerminalError)]) {
    agentTargets = targets
    let answered = agentTerminalNames.filter { name in !errors.contains { $0.name == name } }
    agentNote = targets.isEmpty && !answered.isEmpty ? "no agents in \(answered.joined(separator: " or "))" : nil
    agentErrors = errors.isEmpty ? nil : errors.map(\.error.description).joined(separator: " · ")
  }

  /// ⌥⏎'s refusal: names the terminals switched on.
  var pasteOnlyRefusal: String {
    switch Set(agentTerminalNames) {
    case ["tmux"]: return "Paste only is for tmux panes"
    case ["kitty", "tmux"]: return "Paste only is for agents in kitty or tmux"
    default: return "Paste only is for kitty windows"
    }
  }

  var selectedAgents: [AgentTarget] { agentTargets.filter { selected.contains($0.key) } }

  /// Who the message goes to, for the placeholder: chi, or the one agent
  /// when only terminals running it are chosen.
  var addressee: String {
    if everyoneSelected { return "everyone it concerns" }
    let agents = Set(selectedAgents.map(\.agent))
    return agents.count == 1 && selectedSessions.isEmpty && !newSelected ? agents.first! : "chi"
  }
}

/// A row of the panel: a chi session or an agent in a terminal.
enum Target: Identifiable {
  case chi(LiveSession)
  case agent(AgentTarget)

  var id: String {
    switch self {
    case .chi(let session): return session.key
    case .agent(let target): return target.key
    }
  }
}

/// ⏎ message, ⌘⏎ note, ⌥⏎ paste (agents in terminals only: no Enter).
enum SendKind { case message, note, paste }

struct PanelView: View {
  @ObservedObject var model: PanelModel
  let send: (SendKind) -> Void
  @FocusState private var promptFocused: Bool
  @FocusState private var filterFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      TextField(placeholder, text: $model.prompt, axis: .vertical)
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

  /// The message is required with images, as in the web.
  var placeholder: String {
    if model.everyoneSelected { return "Tell everyone it concerns… (⌘⏎)" }
    return (model.images.isEmpty ? "Ask \(model.addressee)…" : "Say something about the image…") + model.machineHint
  }

  @ViewBuilder var imageStrip: some View {
    if !model.images.isEmpty {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(model.images) { image in
            Thumbnail(image: image, removable: model.phase != .sending, hover: model.hoveredImage == image.id,
                      onHover: { model.hover(image, $0) }) {
              model.remove(image)
            }
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
      if model.pickerOpen {
        newRow
        modelChooser
      } else {
        switch model.phase {
        case .loading:
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Looking for live sessions…").foregroundColor(.secondary)
          }.padding(10)
        default:
          newRow
          everyoneRow
          let live = model.live.count, agents = model.agentTargets.count
          ForEach(Array(model.localTargets.prefix(9).enumerated()), id: \.element.id) { index, target in
            if index == live && agents > 0 { groupHeader(agentHeader, first: index == 0) }
            if index == live + agents && !model.recent.isEmpty {
              agentNoteLines
              groupHeader("recent", first: index == 0)
            }
            switch target {
            case .chi(let session): row(session, index: index)
            case .agent(let agent): agentRow(agent, index: index)
            }
          }
          if model.recent.isEmpty { agentNoteLines }
          ForEach(model.remoteGroups) { group in
            groupHeader("on \(group.section.name)", first: false)
            remoteNoteLine(group)
            ForEach(Array(group.rows.enumerated()), id: \.element.key) { offset, session in
              row(session, index: group.firstIndex + offset)
            }
          }
        }
      }
    }
    .padding(6)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  func groupHeader(_ name: String, first: Bool) -> some View {
    HStack(spacing: 6) {
      Text(name).font(.system(size: 11)).foregroundColor(.secondary)
      Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
    }
    .padding(.horizontal, 8).padding(.top, first ? 2 : 6)
  }

  /// The agent rows' divider: the terminal's name ("kitty").
  var agentHeader: String { model.agentTerminalNames.count == 1 ? model.agentTerminalNames[0] : "agents" }

  /// After the agent rows: "no agents in kitty" where they would be, and
  /// why a terminal can't be asked (beside another's rows too); nothing
  /// without a terminal section.
  @ViewBuilder var agentNoteLines: some View {
    if !model.agentTerminalNames.isEmpty {
      if model.agentTargets.isEmpty, let note = model.agentNote { agentNoteLine(note) }
      if let errors = model.agentErrors { agentNoteLine(errors) }
    }
  }

  func agentNoteLine(_ text: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "terminal").font(.system(size: 11))
      Text(text).font(.system(size: 11)).lineLimit(1)
    }
    .foregroundColor(.secondary.opacity(0.7))
    .padding(.horizontal, 8).padding(.vertical, 4)
  }

  /// Under a remote's divider: asking, why it has no rows, or none.
  @ViewBuilder func remoteNoteLine(_ group: PanelModel.RemoteGroup) -> some View {
    if group.section.loading {
      remoteLine("asking \(group.section.name)…")
    } else if let error = group.section.error {
      remoteLine(error).help(error)
    } else if group.rows.isEmpty {
      // All of them listed above: the same machine by another name.
      remoteLine(group.section.sessions.isEmpty ? "no live or recent sessions" : "its sessions are listed above")
    }
  }

  func remoteLine(_ text: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "network").font(.system(size: 11))
      Text(text).font(.system(size: 11)).lineLimit(1)
    }
    .foregroundColor(.secondary.opacity(0.7))
    .padding(.horizontal, 8).padding(.vertical, 4)
  }

  func agentRow(_ target: AgentTarget, index: Int) -> some View {
    let on = model.selected.contains(target.key)
    return Button(action: { model.toggle(target.key) }) {
      HStack(spacing: 10) {
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 16))
          .foregroundColor(on ? .accentColor : .secondary)
        VStack(alignment: .leading, spacing: 1) {
          Text(target.title.isEmpty ? target.label : "\(target.agent) · \(target.title)")
            .font(.system(size: 13, weight: .medium)).lineLimit(1)
          Text(target.shortCwd).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
        }
        Spacer()
        // Which terminal, when two are on.
        if model.agentTerminalNames.count > 1 {
          Text(target.terminal).font(.system(size: 10)).foregroundColor(.secondary)
        }
        Image(systemName: "terminal").font(.system(size: 12)).foregroundColor(.secondary)
          .help("\(target.agent) in \(target.whereabouts): ⏎ pastes and presses Enter, ⌥⏎ only pastes")
        Text("⌘\(index + 1)").font(.system(size: 11, design: .rounded)).foregroundColor(.secondary)
      }
      .padding(.horizontal, 8).padding(.vertical, 6)
      .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.accentColor.opacity(0.14) : Color.clear))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  var newRow: some View {
    let on = model.newSelected
    return HStack(spacing: 10) {
      Button(action: { model.toggleNew() }) {
        HStack(spacing: 10) {
          Image(systemName: on ? "plus.circle.fill" : "plus.circle")
            .font(.system(size: 16))
            .foregroundColor(on ? .accentColor : .secondary)
          VStack(alignment: .leading, spacing: 1) {
            Text("New session in \(model.newSessionFolder)").font(.system(size: 13, weight: .medium)).lineLimit(1)
            Text(LiveSession.shorten(model.newSessionDir)).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
          }
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("start a session with the message, as the web does (chi send --new); a note needs a session")
      modelLabel
      Text("⌘0").font(.system(size: 11, design: .rounded)).foregroundColor(.secondary)
    }
    .padding(.horizontal, 8).padding(.vertical, 6)
    .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.accentColor.opacity(0.14) : Color.clear))
  }

  /// `chi broadcast` instead of picked sessions (⌘B): ⌘⏎ shares the note
  /// with the sessions chi finds it concerns.
  var everyoneRow: some View {
    let on = model.everyoneSelected
    return Button(action: { model.toggleEveryone() }) {
      HStack(spacing: 10) {
        Image(systemName: "antenna.radiowaves.left.and.right")
          .font(.system(size: 14))
          .foregroundColor(on ? .accentColor : .secondary)
          .frame(width: 18)
        VStack(alignment: .leading, spacing: 1) {
          // chi broadcast runs on this Mac only.
          Text("Everyone it concerns (this Mac)").font(.system(size: 13, weight: .medium)).lineLimit(1)
          Text("a note for the sessions chi finds it concerns: ⌘⏎").font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
        }
        Spacer()
        Text("⌘B").font(.system(size: 11, design: .rounded)).foregroundColor(.secondary)
      }
      .padding(.horizontal, 8).padding(.vertical, 6)
      .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.accentColor.opacity(0.14) : Color.clear))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("chi broadcast: sessions sharing a tag with the note get it, a triage model judges the rest; "
          + "a first line naming a project keeps it there. Details: chi broadcast log")
  }

  /// The new session's model: grey for the default, accent for a pick; a
  /// click (or ⌘M) opens the chooser.
  var modelLabel: some View {
    let picked = model.modelForSend != nil
    return Button(action: { model.pickerOpen ? model.closePicker() : model.openPicker() }) {
      HStack(spacing: 3) {
        Text(model.shownModel ?? "model").font(.system(size: 11))
          .foregroundColor(picked ? .accentColor : .secondary)
          .lineLimit(1).truncationMode(.middle)
        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)).foregroundColor(.secondary)
      }
      .frame(maxWidth: 240, alignment: .trailing)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(picked ? "the new session's model (chi send --new --model); ⌘M to change"
                 : "the model a new session starts on: default.model in config.yml; ⌘M to choose another")
  }

  /// A filter and up to nine rows: ↑/↓ and ⏎, or ⌘1…⌘9, pick; Esc closes.
  @ViewBuilder var modelChooser: some View {
    let rows = model.chooserRows
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundColor(.secondary)
        TextField("Search the models, or type a name…", text: $model.modelQuery)
          .textFieldStyle(.plain)
          .font(.system(size: 13))
          .focused($filterFocused)
        if model.modelsLoading { ProgressView().controlSize(.small) }
      }
      .padding(.horizontal, 8).padding(.vertical, 5)
      .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
      .padding(.horizontal, 4).padding(.vertical, 3)

      ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
        modelRow(row, index: index)
      }
      if model.modelList == nil && model.modelsLoading {
        Text("Loading models…").font(.system(size: 11)).foregroundColor(.secondary)
          .padding(.horizontal, 8).padding(.vertical, 4)
      }
      if let note = model.modelsNote {
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.triangle").font(.system(size: 10))
          Text(note).font(.system(size: 11)).lineLimit(2)
        }
        .foregroundColor(.secondary)
        .help(note)
        .padding(.horizontal, 8).padding(.vertical, 4)
      }
    }
    .onAppear { DispatchQueue.main.async { filterFocused = true } }
    .onDisappear { DispatchQueue.main.async { promptFocused = true } }
  }

  func modelRow(_ row: ModelRow, index: Int) -> some View {
    let current = model.isCurrent(row)
    let highlighted = index == model.pickerIndex
    return Button(action: { model.choose(row) }) {
      HStack(spacing: 10) {
        Image(systemName: current ? "checkmark" : "cpu")
          .font(.system(size: 11))
          .foregroundColor(current ? .accentColor : .secondary.opacity(0.6))
          .frame(width: 16)
        Text(row.label)
          .font(.system(size: 13, weight: row.kind == .standard ? .medium : .regular))
          .foregroundColor(row.kind == .typed ? .secondary : .primary)
          .lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 8)
        Text("⌘\(index + 1)").font(.system(size: 11, design: .rounded)).foregroundColor(.secondary)
      }
      .padding(.horizontal, 8).padding(.vertical, 5)
      .background(RoundedRectangle(cornerRadius: 7).fill(highlighted ? Color.accentColor.opacity(0.14) : Color.clear))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(row.kind == .typed ? "not in any host's list: sent as typed" : row.name)
  }

  /// A session's row; a remote's names its machine (both likely have the
  /// same paths). ⌘ numbers stop at nine.
  func row(_ session: LiveSession, index: Int) -> some View {
    let on = model.selected.contains(session.key)
    return Button(action: { model.toggle(session.key) }) {
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
        if let remote = session.remote {
          Text(remote).font(.system(size: 10)).foregroundColor(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .help("a session on \(remote): sent with chi --remote \(remote)")
        }
        if index < 9 {
          Text("⌘\(index + 1)").font(.system(size: 11, design: .rounded)).foregroundColor(.secondary)
        }
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
      // A broadcast's source is "broadcast": no field, more room for its summary.
      if !model.everyoneSelected {
        HStack(spacing: 4) {
          Image(systemName: "arrow.down.doc").font(.system(size: 11)).foregroundColor(.secondary)
          TextField("source", text: $model.source)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .frame(width: 90)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
      }

      HStack(spacing: 0) {
        if !model.origin.isEmpty {
          Text("from \(model.origin) · ").foregroundColor(.secondary)
            .help(model.origin == "clipboard" ? "opened with the hotkey: the text and images are the clipboard's"
                                              : "opened with Send to chi: the text and images are the selection")
        }
        Text(byteLabel).foregroundColor(model.bytes > noteCap ? .red : .secondary)
      }
      .font(.system(size: 11).monospacedDigit())
      .lineLimit(1)
      .fixedSize()

      Text(model.message)
        .font(.system(size: 11))
        .foregroundColor(model.phase == .failed ? .red : .secondary)
        .lineLimit(3)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)

      // ⏎, ⌘⏎ and ⌥⏎ are handled by the panel (KeyPanel.sendEvent),
      // whatever has the focus; the buttons are for the mouse. Only agents
      // in terminals chosen: Paste instead of Note.
      if !model.selectedAgents.isEmpty && model.selectedSessions.isEmpty && !model.newSelected {
        Button("Paste ⌥⏎") { send(.paste) }
          .disabled(!model.sendEnabled)
          .help("paste it into the agent's input without Enter: add more, then press Enter there")
      } else if model.everyoneSelected {
        Button("Broadcast ⌘⏎") { send(.note) }
          .disabled(!model.sendEnabled)
          .help("share it as a note with every session it concerns (chi broadcast); starts no turn")
      } else {
        Button("Note ⌘⏎") { send(.note) }
          .disabled(!model.sendEnabled || !model.selectedAgents.isEmpty || model.newSelected)
          .help(model.newSelected ? "a note needs a session: pick one, or ⏎ starts a new one with the message"
                                  : "add it as background the model sees on its next turn; starts no turn")
      }
      // Where it goes while a remote's row is ticked: stays when the
      // placeholder's hint is gone under typed text.
      if !model.machineHint.isEmpty {
        Text(model.machineHint.trimmingCharacters(in: .whitespaces))
          .font(.system(size: 11, weight: .medium)).foregroundColor(.accentColor)
          .lineLimit(1).fixedSize()
          .help("sent to that machine's sessions (chi --remote)")
      }
      // A broadcast is a note: no Send.
      if model.everyoneSelected {
        if model.phase == .sending { ProgressView().controlSize(.small) }
      } else {
        Button(action: { send(.message) }) {
          if model.phase == .sending { ProgressView().controlSize(.small) } else { Text("Send ⏎") }
        }
        .disabled(!model.sendEnabled)
        .help("send it as your message: a turn runs")
      }
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
  let hover: Bool
  let onHover: (Bool) -> Void
  let remove: () -> Void

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
    .onHover(perform: onHover)
    .help(image.name)
  }
}

final class KeyPanel: NSPanel {
  var onKey: ((NSEvent) -> Bool)?
  /// Return with these modifiers; true when handled.
  var onReturn: ((NSEvent.ModifierFlags) -> Bool)?
  /// ↑ (-1) or ↓ (+1) without modifiers; true when handled.
  var onArrow: ((Int) -> Bool)?
  /// Esc; true when handled (the panel stays open).
  var onCancel: (() -> Bool)?

  /// Return is taken here, before the text views see it, so ⏎ sends from
  /// either field. An input method composing text keeps its Return.
  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76,
       (firstResponder as? NSTextView)?.hasMarkedText() != true,
       onReturn?(event.modifierFlags.intersection([.shift, .command, .option, .control])) == true {
      return
    }
    // An input method's candidate list keeps its arrows too.
    if event.type == .keyDown, event.keyCode == 125 || event.keyCode == 126,
       event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
       (firstResponder as? NSTextView)?.hasMarkedText() != true,
       onArrow?(event.keyCode == 125 ? 1 : -1) == true {
      return
    }
    // Esc closes an open chooser before a text view sees it (it could take
    // it as completion); otherwise cancelOperation closes the panel.
    if event.type == .keyDown, event.keyCode == 53,
       (firstResponder as? NSTextView)?.hasMarkedText() != true, onCancel?() == true {
      return
    }
    super.sendEvent(event)
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override func cancelOperation(_ sender: Any?) {
    if onCancel?() == true { return }
    close()
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if onKey?(event) == true { return true }
    return super.performKeyEquivalent(with: event)
  }
}

final class PanelController: NSObject, NSWindowDelegate {
  let model = PanelModel()
  let runner = ChiRunner()
  /// This open's agent terminals (launch.json read at each open).
  private var agents: AgentTerminals?
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
    panel.onArrow = { [weak self] delta in
      guard let self, self.model.pickerOpen else { return false }
      self.model.movePicker(delta)
      return true
    }
    panel.onCancel = { [weak self] in
      guard let self, self.model.pickerOpen else { return false }
      self.model.closePicker()
      return true
    }
  }

  /// ⏎ message, ⌘⏎ note, ⌥⏎ paste, ⇧⏎ a newline in the focused field.
  /// With the chooser open, ⏎ picks the highlighted row (other Returns do
  /// nothing: no send from inside the chooser).
  private func handleReturn(_ flags: NSEvent.ModifierFlags) -> Bool {
    if model.pickerOpen {
      let rows = model.chooserRows
      if flags.isEmpty, rows.indices.contains(model.pickerIndex) { model.choose(rows[model.pickerIndex]) }
      return true
    }
    switch flags {
    case []: send(.message)
    case .command: send(.note)
    case .option: send(.paste)
    case .shift:
      (panel.firstResponder as? NSTextView)?.insertNewlineIgnoringFieldEditor(nil)
    default: return false
    }
    return true
  }

  /// ⌘1…⌘9 toggle a target, ⌘0 the new row, ⌘B the Everyone row; ⌘M opens or closes the model
  /// chooser, where ⌘1…⌘9 pick a row.
  private func handleKey(_ event: NSEvent) -> Bool {
    let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
    // By key code: ⌘M in any keyboard layout (a Cyrillic one types "ь").
    if command, event.keyCode == 46 {
      if model.pickerOpen { model.closePicker() } else { model.openPicker() }
      return true
    }
    if model.pickerOpen {
      let rows = model.chooserRows
      guard command, let chars = event.charactersIgnoringModifiers, let n = Int(chars), n >= 1, n <= rows.count else { return false }
      model.choose(rows[n - 1])
      return true
    }
    // By key code, as ⌘M.
    if command, event.keyCode == 11 {
      model.toggleEveryone()
      return true
    }
    let targets = model.targets
    guard command, let chars = event.charactersIgnoringModifiers, let n = Int(chars),
          n <= min(targets.count, 9) else { return false }
    if n == 0 { model.toggleNew() } else { model.toggle(targets[n - 1].id) }
    return true
  }

  /// @param origin "clipboard" or "selection": where text and images came from
  /// @param returnTo the app to give focus back to on close
  func show(text: String, images: [PanelImage] = [], origin: String, source: String, returnTo app: NSRunningApplication?) {
    returnTo = app
    opens += 1
    // A show on an open panel resets it without a close.
    dropImages()
    model.prompt = ""
    model.images = []
    model.add(images)
    model.text = text
    model.origin = text.isEmpty && images.isEmpty ? "" : origin
    model.source = source
    model.message = ""
    model.newSelected = false
    model.everyoneSelected = false
    model.selected = []
    model.touched = false
    model.pickerOpen = false
    model.modelQuery = ""
    model.pickTouched = false
    model.applyStoredPick()
    model.phase = .loading
    placeOnActiveScreen()
    panel.makeKeyAndOrderFront(nil)
    loadSessions()
    loadRemotes()
    loadAgents()
    loadModel()
    loadModels()
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
    runner.sessions { [weak self] result in self?.model.showSessions(result) }
  }

  private var remotesGeneration = 0

  /// The remotes' sections, beside this Mac's listing and never blocking
  /// it: each fills in as it answers (or fails, D5); PanelModel.showRemote
  /// says when one may preselect.
  private func loadRemotes() {
    remotesGeneration += 1
    let generation = remotesGeneration
    model.remoteSections = []
    runner.remotes { [weak self] names in
      guard let self, generation == self.remotesGeneration else { return }
      self.model.startRemotes(names)
      for name in names {
        self.runner.sessions(remote: name) { [weak self] result in
          guard let self, generation == self.remotesGeneration else { return }
          self.model.showRemote(name, result)
        }
      }
    }
  }

  /// Beside the chi listing, never blocking or failing it: a listing that
  /// answers after the sessions preselects again unless the user chose.
  private func loadAgents() {
    let terminals = AgentTerminals(launchPath: runner.launchPath)
    agents = terminals
    model.agentTerminalNames = terminals.names
    model.agentTargets = []
    model.agentNote = nil
    model.agentErrors = nil
    guard !terminals.isEmpty else { return }
    terminals.list { [weak self] targets, errors in
      guard let self, self.agents === terminals else { return }
      self.model.showAgents(targets, errors: errors)
      if self.model.phase != .loading && !self.model.touched { self.model.preselect() }
    }
  }

  /// Kept from the last look while it runs; config rarely changes.
  private func loadModel() {
    runner.defaultModel { [weak self] model in self?.model.newModel = model }
  }

  private var modelsGeneration = 0

  /// The chooser's list, refreshed on each open; the last one serves
  /// meanwhile, and a failed refresh keeps it.
  private func loadModels() {
    modelsGeneration += 1
    let generation = modelsGeneration
    model.modelsLoading = true
    runner.models { [weak self] result in
      guard let self, generation == self.modelsGeneration else { return }
      self.model.modelsLoading = false
      switch result {
      case .success(let list):
        self.model.modelList = list
        self.model.modelsError = nil
      case .failure(let error):
        self.model.modelsError = error.description
      }
      self.model.applyStoredPick()
    }
  }

  /// Fans out: one `chi send` / `chi note` per machine for the chi sessions
  /// (or one for the new row) and one paste per agent, all at once, with
  /// one combined line when all finished. chi's send reads the images and
  /// leaves them; the helper deletes the ones it wrote after every job, so
  /// those are copied for the agents first (their paths are read later).
  func send(_ kind: SendKind) {
    if model.everyoneSelected { broadcast(kind); return }
    let chosen = model.selectedSessions
    let windows = model.selectedAgents
    let new = model.newSelected
    if kind == .note, !windows.isEmpty {
      NSSound.beep()
      model.message = "Notes are for chi sessions"
      return
    }
    if kind == .paste, windows.isEmpty || !chosen.isEmpty || new {
      NSSound.beep()
      model.message = model.pasteOnlyRefusal
      return
    }
    // A note into a session that doesn't exist yet makes no sense.
    if kind == .note, new {
      NSSound.beep()
      model.message = "A note needs a session"
      return
    }
    if kind == .note, !model.images.isEmpty {
      NSSound.beep()
      model.message = "Notes are text only: ⏎ sends the image as a message"
      return
    }
    guard model.sendEnabled, new || !(chosen.isEmpty && windows.isEmpty) else { NSSound.beep(); return }
    model.phase = .sending
    model.message = ""
    if !new {
      let liveKeys = chosen.filter { !$0.recent }.map(\.key)
      UserDefaults.standard.set(liveKeys + windows.map(\.key), forKey: PanelModel.lastChoiceKey)
    }
    let images = kind == .note ? [] : model.images
    inFlight.formUnion(images.map(\.id))
    let agentText = windows.isEmpty ? "" : AgentText.text(context: model.hasContext ? model.text : "", message: model.trimmedPrompt,
                                                     imagePaths: ImageIntake.keepForPaste(images), pasteOnly: kind == .paste)

    let open = opens
    let group = DispatchGroup()
    var chiOutcome: SendOutcome?
    var agentOutcomes: [(AgentTarget, AgentTerminalError?)] = []
    let terminals = agents ?? AgentTerminals(launchPath: runner.launchPath)
    if new || !chosen.isEmpty {
      group.enter()
      sendToChi(kind, sessions: chosen, new: new, images: images) { outcome in chiOutcome = outcome; group.leave() }
    }
    for window in windows {
      guard let terminal = terminals.terminal(for: window.key) else {
        agentOutcomes.append((window, .failed("not an agent: \(window.key)")))
        continue
      }
      group.enter()
      terminal.send(key: window.key, text: agentText, pasteOnly: kind == .paste) { result in
        if case .failure(let error) = result { agentOutcomes.append((window, error)) } else { agentOutcomes.append((window, nil)) }
        group.leave()
      }
    }
    group.notify(queue: .main) { [weak self] in
      guard let self else { return }
      self.inFlight.subtract(images.map(\.id))
      let pasted = windows.filter { w in agentOutcomes.contains { $0.0 == w && $0.1 == nil } }
      let failed = agentOutcomes.compactMap { outcome in outcome.1.map { "\(outcome.0.label): \($0.description)" } }
      let ok = (chiOutcome?.ok ?? true) && failed.isEmpty
      // Sent: the temp files go (and the thumbnails). Else they stay for
      // another try, unless the panel was closed or reopened meanwhile.
      if ok { self.model.images.removeAll { images.contains($0) } }
      ImageIntake.delete(images.filter { !self.model.images.contains($0) })
      // Reopened meanwhile (as for a broadcast): the new open keeps its
      // message and phase, and isn't closed by this send's success.
      guard self.opens == open else { return }
      var parts: [String] = []
      if let chiOutcome { parts.append(chiOutcome.message) }
      if !pasted.isEmpty {
        parts.append("\(kind == .paste ? "pasted into" : "sent to") \(pasted.map(\.label).joined(separator: ", "))")
      }
      parts += failed
      self.model.message = parts.filter { !$0.isEmpty }.joined(separator: " · ")
      if ok {
        self.model.phase = .sent
        DispatchQueue.main.asyncAfter(deadline: .now() + (chiOutcome?.linger ?? 1.0)) { [weak self] in
          if self?.opens == open, self?.model.phase == .sent { self?.panel.close() }
        }
      } else {
        self.model.phase = .failed
      }
    }
  }

  /// Counts the panel's opens: a send or broadcast that ends after a
  /// reopen leaves the new open alone.
  private var opens = 0

  /// The Everyone row: `chi broadcast` with the note (the source field is
  /// not used: a broadcast's source is "broadcast"). It stays open with
  /// the summary line (Esc closes): no auto-close.
  private func broadcast(_ kind: SendKind) {
    if kind != .note {
      NSSound.beep()
      model.message = "A broadcast is a note: ⌘⏎"
      return
    }
    if !model.images.isEmpty {
      NSSound.beep()
      model.message = "A broadcast is text only: remove the images"
      return
    }
    guard model.sendEnabled else { NSSound.beep(); return }
    model.phase = .sending
    model.message = "broadcasting…"
    let open = opens
    runner.broadcast(model.noteText) { [weak self] outcome, _ in
      guard let self, self.opens == open else { return }
      self.model.phase = outcome.ok ? .sent : .failed
      self.model.message = outcome.message
    }
  }

  struct SendOutcome {
    let ok: Bool
    let message: String
    var linger = 1.0
  }

  /// Runs the SendPlan's calls (Sessions.swift: one per machine) at once
  /// and words their outcome as one line, this Mac's first, a remote's
  /// named ("sent · studio: sent").
  private func sendToChi(_ kind: SendKind, sessions: [LiveSession], new: Bool, images: [PanelImage],
                         completion: @escaping (SendOutcome) -> Void) {
    let calls = SendPlan.from(model, kind: kind, sessions: sessions, new: new, images: images).calls
    guard !calls.isEmpty else { completion(SendOutcome(ok: false, message: "No session to send to")); return }
    var outcomes = [SendOutcome?](repeating: nil, count: calls.count)
    let group = DispatchGroup()
    for (index, call) in calls.enumerated() {
      group.enter()
      run(call, kind: kind, new: new) { outcome in outcomes[index] = outcome; group.leave() }
    }
    group.notify(queue: .main) {
      let done = outcomes.compactMap { $0 }
      let parts = zip(calls, done).map { call, outcome in call.remote.map { "\($0): \(outcome.message)" } ?? outcome.message }
      completion(SendOutcome(ok: done.allSatisfy(\.ok), message: parts.joined(separator: " · "),
                             linger: done.map(\.linger).max() ?? 1.0))
    }
  }

  /// One machine's `chi send` / `chi note`, its outcome worded.
  private func run(_ call: SendPlan.Call, kind: SendKind, new: Bool, completion: @escaping (SendOutcome) -> Void) {
    let command = call.command
    let timeout = call.timeout
    runner.run(call.args, stdin: call.stdin, timeout: timeout) { result in
      switch result {
      case .failure(let error):
        completion(SendOutcome(ok: false, message: error.description))
      case .success(let r):
        let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.timedOut {
          let what = kind == .note ? "the note may be partly delivered" : "the message may not have been sent"
          completion(SendOutcome(ok: false, message: "\(command) took over \(Int(timeout)) s and was stopped; \(what). \(out)"))
        } else if r.status == 0 {
          // --new prints "<full id>  started". Long enough to read a
          // "waits for the session's next start" line.
          let linger = out.contains("waits for") || out.contains("started") ? 3.0 : 1.0
          completion(SendOutcome(ok: true, message: out.isEmpty ? "Sent." : new ? "started \(out.prefix(8))…" : out, linger: linger))
        } else {
          completion(SendOutcome(ok: false, message: [out, err].filter { !$0.isEmpty }.joined(separator: "\n")))
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
