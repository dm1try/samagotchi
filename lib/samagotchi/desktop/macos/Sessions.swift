// The panel's chi side without the panel: what a send to chi sessions runs
// (SendPlan, built from the panel's state, run by PanelController), and the
// build spec's seams: `ChiHelper --sessions` prints the session rows the
// panel lists, `ChiHelper --send-plan` the chi calls a send would make.
import Foundation

/// A send to chi sessions as the chi calls it makes: `chi send` (a message,
/// or `--new` on the new row) or `chi note`. Pure: nothing runs here.
struct SendPlan {
  /// One chi call: its args after the launch file's argv, its stdin, and
  /// its name in the panel's lines ("chi send").
  struct Call: Equatable {
    let command: String
    let args: [String]
    let stdin: Data?
  }

  let kind: SendKind
  /// UUID-shaped session ids, in list order; not used with +new+.
  let ids: [String]
  /// The machine the ids are on; nil: this Mac (no caller sets it yet).
  var remote: String?
  let new: Bool
  /// Where a new session starts (PanelModel.newSessionDir).
  let newDir: String
  /// `--model` for `chi send --new`, verbatim; nil for the default.
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
  static func from(_ model: PanelModel, kind: SendKind, ids: [String], new: Bool, images: [PanelImage]) -> SendPlan {
    SendPlan(kind: kind, ids: ids, new: new, newDir: model.newSessionDir, model: model.modelForSend,
             prompt: model.trimmedPrompt, context: model.hasContext ? model.text : nil, note: model.noteText,
             source: model.source.trimmingCharacters(in: .whitespacesAndNewlines), images: images.map(\.url.path))
  }

  var calls: [Call] {
    var args: [String]
    let command: String
    let stdin: Data?
    switch kind {
    case .message, .paste:
      // stdin is the quoted context; without -m, chi takes it as the message.
      command = "chi send"
      args = new ? ["send", "--new", "--dir", newDir] : ["send"]
      // The row's name verbatim; none for the default.
      if new, let model { args += ["--model", model] }
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
    return [Call(command: command, args: args, stdin: stdin)]
  }
}

/// Waits on a headless seam's own queue for a ChiRunner call to answer.
private func waitFor<T>(_ start: (DispatchQueue, @escaping (T) -> Void) -> Void) -> T {
  let queue = DispatchQueue(label: "sessions-command")
  let done = DispatchSemaphore(value: 0)
  var answer: T?
  start(queue) { value in answer = value; done.signal() }
  done.wait()
  return answer!
}

private func printJSON(_ object: Any) {
  let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  print(String(decoding: data, as: UTF8.self))
}

/// `ChiHelper --sessions [--launch PATH]`: the panel's session rows in its
/// order (live, then recent) and the new row's folder, as JSON
/// ({"rows": [{"id", "desc", "cwd", "busy", "recent"}], "new_dir"}); a
/// failed listing is its message on stderr, exit 1.
func sessionsCommand(_ args: [String]) -> Int32 {
  var args = args
  var launchPath = ChiRunner.launchPath
  while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--launch" where !args.isEmpty: launchPath = args.removeFirst()
    default:
      FileHandle.standardError.write("usage: ChiHelper --sessions [--launch PATH]\n".data(using: .utf8)!)
      return 2
    }
  }
  let runner = ChiRunner(launchPath: launchPath)
  let result = waitFor { queue, done in runner.sessions(queue: queue, completion: done) }
  switch result {
  case .failure(let error):
    FileHandle.standardError.write("\(error.description)\n".data(using: .utf8)!)
    return 1
  case .success(let sessions):
    let model = PanelModel()
    model.sessions = sessions
    let rows: [[String: Any]] = model.sessions.map { s in
      ["id": s.id, "desc": s.desc ?? NSNull(), "cwd": s.cwd ?? NSNull(), "busy": s.busy ?? NSNull(), "recent": s.recent]
    }
    printJSON(["rows": rows, "new_dir": model.newSessionDir])
    return 0
  }
}

/// `ChiHelper --send-plan message|note|paste [--id ID]... [--new DIR]
/// [--default MODEL] [--model MODEL] [--prompt P] [--source S] [--image PATH]...`:
/// the panel's text on stdin; prints the calls SendPlan makes as JSON
/// ([{"command", "args", "stdin"}], stdin null when none). --new is the new
/// row, DIR the folder of its only (live) session; --default is the
/// configured model, --model the pick.
func sendPlanCommand(_ args: [String]) -> Int32 {
  let usage = "usage: ChiHelper --send-plan message|note|paste [--id ID]... [--new DIR] [--default MODEL] [--model MODEL] "
    + "[--prompt P] [--source S] [--image PATH]...\n"
  var args = args
  let kinds: [String: SendKind] = ["message": .message, "note": .note, "paste": .paste]
  guard let first = args.first, let kind = kinds[first] else {
    FileHandle.standardError.write(usage.data(using: .utf8)!)
    return 2
  }
  args.removeFirst()
  let model = PanelModel()
  var ids: [String] = [], newDir: String?, images: [PanelImage] = []
  while !args.isEmpty {
    let arg = args.removeFirst()
    guard !args.isEmpty else { FileHandle.standardError.write(usage.data(using: .utf8)!); return 2 }
    let value = args.removeFirst()
    switch arg {
    case "--id": ids.append(value)
    case "--new": newDir = value
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
  let plan = SendPlan.from(model, kind: kind, ids: ids, new: newDir != nil, images: images)
  printJSON(plan.calls.map { call -> [String: Any] in
    ["command": call.command, "args": call.args,
     "stdin": call.stdin.map { String(decoding: $0, as: UTF8.self) } ?? NSNull()]
  })
  return 0
}
