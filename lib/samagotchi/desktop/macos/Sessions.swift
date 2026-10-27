// The panel's chi side without the panel: what a send to chi sessions runs
// (SendPlan, built from the panel's state, run by PanelController), and the
// build spec's seams: `ChiHelper --sessions` prints the session rows the
// panel lists, `ChiHelper --send-plan` the chi calls a send would make.
import Foundation

/// A send to chi sessions as the chi calls it makes: `chi send` (a message,
/// or `--new` on a new row, this Mac's or a remote's) or `chi note`, one per
/// machine. Pure: nothing runs here.
struct SendPlan {
  /// One chi call: its args after the launch file's argv, its stdin, its
  /// name in the panel's lines ("chi send"), the remote it goes to and its
  /// time limit.
  struct Call: Equatable {
    let command: String
    let args: [String]
    let stdin: Data?
    var remote: String?
    var timeout: TimeInterval = 10
  }

  /// A session on a machine: nil is this Mac.
  struct Target: Equatable {
    let remote: String?
    let id: String
  }

  let kind: SendKind
  /// UUID-shaped session ids and their machines, in list order; not used
  /// with +new+.
  let targets: [Target]
  let new: Bool
  /// The remote a new session starts on; nil: this Mac.
  let newRemote: String?
  /// Where a new session starts (PanelModel.newSessionDir, or
  /// newSessionDir(remote:) on a remote); nil: nowhere known, no call.
  let newDir: String?
  /// `--model` for `chi send --new` on this Mac, verbatim; nil for the
  /// default. Never on a remote (D4: the list is this Mac's).
  let model: String?
  /// The message line, trimmed; `-m` of `chi send`.
  let prompt: String
  /// A message's stdin: the quoted context; nil when there is none.
  let context: String?
  /// `chi note`'s stdin: the message line, then the context.
  let note: String
  /// `chi note --source`, trimmed; "" for none.
  let source: String
  /// `--image` paths; a note's are dropped before (text only).
  let images: [String]

  /// The panel's state for this send.
  static func from(_ model: PanelModel, kind: SendKind, sessions: [LiveSession], new: Bool, images: [PanelImage]) -> SendPlan {
    let newRemote = new ? model.newRemote : nil
    let newDir = newRemote.map(model.newSessionDir(remote:)) ?? model.newSessionDir
    return SendPlan(kind: kind, targets: sessions.map { Target(remote: $0.remote, id: $0.id) }, new: new, newRemote: newRemote,
             newDir: newDir, model: newRemote == nil ? model.modelForSend : nil,
             prompt: model.trimmedPrompt, context: model.hasContext ? model.text : nil, note: model.noteText,
             source: model.source.trimmingCharacters(in: .whitespacesAndNewlines), images: images.map(\.url.path))
  }

  /// This Mac's call first, then one per remote in list order. A session
  /// goes once, to the first machine it is under; a remote whose name chi
  /// wouldn't take is left out (the listing never makes one).
  var calls: [Call] {
    if new {
      guard newDir != nil, newRemote.map(Remotes.valid) ?? true else { return [] }
      return [call(ids: [], remote: newRemote)]
    }
    var machines: [String?] = []
    var ids: [String?: [String]] = [:]
    var seen = Set<String>()
    let ordered = targets.filter { $0.remote == nil } + targets.filter { $0.remote != nil }
    for target in ordered where target.remote.map(Remotes.valid) ?? true && seen.insert(target.id).inserted {
      if ids[target.remote] == nil { machines.append(target.remote) }
      ids[target.remote, default: []].append(target.id)
    }
    return machines.map { call(ids: ids[$0] ?? [], remote: $0) }
  }

  /// Reading, converting and a new worker's start take longer than text;
  /// a remote's text, waking a stopped worker there, too.
  private func call(ids: [String], remote: String?) -> Call {
    var args: [String]
    let command: String
    let stdin: Data?
    switch kind {
    case .message, .paste:
      // stdin is the quoted context; without -m, chi takes it as the message.
      command = "chi send"
      args = new ? ["send", "--new", "--dir", newDir ?? ""] : ["send"]
      // The row's name verbatim; none for the default, nor on a remote.
      if new, remote == nil, let model { args += ["--model", model] }
      if !prompt.isEmpty { args += ["-m", prompt] }
      args += images.flatMap { ["--image", $0] }
      stdin = context.map { Data($0.utf8) }
    case .note:
      command = "chi note"
      args = ["note"]
      if !source.isEmpty { args += ["--source", source] }
      stdin = Data(note.utf8)
    }
    if !new { args += ids }
    if let remote { args = ["--remote", remote] + args }
    let timeout: TimeInterval = !images.isEmpty && kind != .note ? 30 : remote == nil ? 10 : 15
    return Call(command: command, args: args, stdin: stdin, remote: remote, timeout: timeout)
  }
}

private func printJSON(_ object: Any) {
  let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  print(String(decoding: data, as: UTF8.self))
}

/// `ChiHelper --sessions [--launch PATH] [--last KEY]... [--order
/// local-first|remotes-first] [--click KEY]...`: the panel's session rows in
/// its order (live, then recent), the new row's folder, a section per remote
/// (rows not listed before, or its line, and its new row's folder) and what
/// the panel preselects with KEYs as the remembered choice (none by default:
/// never the user's) when the answers come in that order (this Mac's first
/// by default), then after the clicks (a row's key, "new", "new:REMOTE" for
/// a remote's new row, "model" for ⌘M), as JSON ({"rows": [{"id", "desc",
/// "cwd", "busy", "recent"}], "new_dir", "remotes": [{"name", "rows" (each
/// with "remote"), "error", "new_dir" (null: no new row)}], "selected",
/// "new_selected", "new_remote", "picker_open", "message", "hint"}); a
/// failed listing of this Mac's is its message on stderr, exit 1.
func sessionsCommand(_ args: [String]) -> Int32 {
  var args = args
  var launchPath = ChiRunner.launchPath
  var last: [String] = []
  var remotesFirst = false
  var clicks: [String] = []
  let usage = "usage: ChiHelper --sessions [--launch PATH] [--last KEY]... [--order local-first|remotes-first] [--click KEY]...\n"
  while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--launch" where !args.isEmpty: launchPath = args.removeFirst()
    case "--last" where !args.isEmpty: last.append(args.removeFirst())
    case "--click" where !args.isEmpty: clicks.append(args.removeFirst())
    case "--order" where !args.isEmpty:
      let order = args.removeFirst()
      guard ["local-first", "remotes-first"].contains(order) else {
        FileHandle.standardError.write(usage.data(using: .utf8)!)
        return 2
      }
      remotesFirst = order == "remotes-first"
    default:
      FileHandle.standardError.write(usage.data(using: .utf8)!)
      return 2
    }
  }
  let runner = ChiRunner(launchPath: launchPath)
  // As the panel: this Mac's lists beside `remote ls`, then each remote's
  // at once. All are awaited, then fed to the panel's model in the order
  // --order says (the panel takes them as they come).
  let queue = DispatchQueue(label: "sessions-command")
  let group = DispatchGroup()
  var local: Result<[LiveSession], ChiError>?
  var names: [String] = []
  var answers: [String: Result<[LiveSession], ChiError>] = [:]
  group.enter()
  runner.sessions(queue: queue) { local = $0; group.leave() }
  group.enter()
  runner.remotes(queue: queue) { found in
    names = found
    for name in found {
      group.enter()
      runner.sessions(remote: name, queue: queue) { answers[name] = $0; group.leave() }
    }
    group.leave()
  }
  group.wait()
  let model = PanelModel()
  model.lastChoice = last
  model.startRemotes(names)
  let showRemotes = { for name in names { model.showRemote(name, answers[name]!) } }
  if remotesFirst { showRemotes() }
  model.showSessions(local!)
  if !remotesFirst { showRemotes() }
  for key in clicks {
    switch key {
    case "new": model.toggleNew()
    case "model": _ = model.pressModel()
    case let key where key.hasPrefix("new:"): model.toggleNew(remote: String(key.dropFirst(4)))
    default: model.toggle(key)
    }
  }
  switch local! {
  case .failure(let error):
    FileHandle.standardError.write("\(error.description)\n".data(using: .utf8)!)
    return 1
  case .success:
    let row = { (s: LiveSession) -> [String: Any] in
      var row: [String: Any] = ["id": s.id, "desc": s.desc ?? NSNull(), "cwd": s.cwd ?? NSNull(), "busy": s.busy ?? NSNull(),
                                "recent": s.recent]
      if let remote = s.remote { row["remote"] = remote }
      return row
    }
    let remotes: [[String: Any]] = model.remoteGroups.map { group in
      ["name": group.section.name, "rows": group.rows.map(row), "error": group.section.error ?? NSNull(),
       "new_dir": model.newSessionDir(remote: group.section.name) ?? NSNull()]
    }
    printJSON(["rows": model.sessions.map(row), "new_dir": model.newSessionDir, "remotes": remotes,
               "selected": model.selected.sorted(), "new_selected": model.newSelected, "new_remote": model.newRemote ?? NSNull(),
               "picker_open": model.pickerOpen, "message": model.message, "hint": model.machineHint])
    return 0
  }
}

/// `ChiHelper --send-plan message|note|paste [--id [REMOTE:]ID]... [--new [REMOTE:]DIR]
/// [--default MODEL] [--model MODEL] [--prompt P] [--source S] [--image PATH]...`:
/// the panel's text on stdin; prints the calls SendPlan makes as JSON
/// ([{"command", "args", "stdin", "timeout"}], stdin null when none). An id
/// as a row's key: "studio:<id>" on a remote. --new is the new row, DIR the
/// folder of its only (live) session; with REMOTE: (DIR absolute), that
/// remote's new row; --default is the configured model, --model the pick.
func sendPlanCommand(_ args: [String]) -> Int32 {
  let usage = "usage: ChiHelper --send-plan message|note|paste [--id [REMOTE:]ID]... [--new [REMOTE:]DIR] [--default MODEL] "
    + "[--model MODEL] "
    + "[--prompt P] [--source S] [--image PATH]...\n"
  var args = args
  let kinds: [String: SendKind] = ["message": .message, "note": .note, "paste": .paste]
  guard let first = args.first, let kind = kinds[first] else {
    FileHandle.standardError.write(usage.data(using: .utf8)!)
    return 2
  }
  args.removeFirst()
  let model = PanelModel()
  var sessions: [LiveSession] = [], newDir: String?, images: [PanelImage] = []
  while !args.isEmpty {
    let arg = args.removeFirst()
    guard !args.isEmpty else { FileHandle.standardError.write(usage.data(using: .utf8)!); return 2 }
    let value = args.removeFirst()
    switch arg {
    case "--id":
      // A UUID has no ":", so the last one splits off the remote.
      let colon = value.lastIndex(of: ":")
      var session = LiveSession(id: colon.map { String(value[value.index(after: $0)...]) } ?? value, desc: nil, cwd: nil,
                                busy: nil, owner: nil, updatedAt: nil)
      session.remote = colon.map { String(value[..<$0]) }
      sessions.append(session)
    case "--new" where value.hasPrefix("/"): newDir = value
    case "--new":
      guard let colon = value.firstIndex(of: ":") else { FileHandle.standardError.write(usage.data(using: .utf8)!); return 2 }
      let name = String(value[..<colon])
      var session = LiveSession(id: UUID().uuidString, desc: nil, cwd: String(value[value.index(after: colon)...]), busy: nil,
                                owner: nil, updatedAt: nil)
      session.remote = name
      model.startRemotes([name])
      model.showRemote(name, .success([session]))
      model.newRemote = name
    case "--default": model.newModel = value
    case "--model": model.pickedModel = value
    case "--prompt": model.prompt = value
    case "--source": model.source = value
    case "--image": images.append(PanelImage(url: URL(fileURLWithPath: value), temp: false))
    default:
      FileHandle.standardError.write(usage.data(using: .utf8)!)
      return 2
    }
  }
  model.text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
  if let newDir {
    model.sessions = [LiveSession(id: UUID().uuidString, desc: nil, cwd: newDir, busy: nil, owner: nil, updatedAt: nil)]
  }
  let plan = SendPlan.from(model, kind: kind, sessions: sessions, new: newDir != nil || model.newRemote != nil, images: images)
  printJSON(plan.calls.map { call -> [String: Any] in
    ["command": call.command, "args": call.args, "timeout": call.timeout,
     "stdin": call.stdin.map { String(decoding: $0, as: UTF8.self) } ?? NSNull()]
  })
  return 0
}
