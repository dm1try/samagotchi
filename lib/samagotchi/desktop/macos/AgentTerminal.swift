// Agent CLIs (claude, codex, …) running in a terminal, as panel targets:
// each terminal the launch file has a section for (kitty: Kitty.swift) lists
// its agents and pastes text into one. The panel and `ChiHelper --agents`
// talk to them only through AgentTerminals.
import Foundation

/// One terminal's agents: listed, and pasted into by key. A key belongs to
/// exactly one terminal (`owns`).
protocol AgentTerminal: AnyObject {
  /// "kitty": the panel's divider, the row's tag, the CLI's JSON.
  var name: String { get }
  func owns(key: String) -> Bool
  func list(completion: @escaping (Result<[AgentTarget], AgentTerminalError>) -> Void)
  /// Pastes +text+, then presses Enter unless +pasteOnly+.
  func send(key: String, text: String, pasteOnly: Bool, completion: @escaping (Result<Void, AgentTerminalError>) -> Void)
}

/// One agent in a terminal: its key is what the panel selects and remembers.
struct AgentTarget: Identifiable, Equatable {
  let terminal: String
  let key: String
  let agent: String
  let title: String
  let cwd: String
  /// Where it is, for the help text ("" for a kitty window).
  let place: String
  /// The foreground program names it was matched on.
  let names: [String]

  var id: String { key }
  var shortCwd: String { LiveSession.shorten(cwd) }
  /// "claude · samagotchi": the agent and its folder.
  var label: String {
    let folder = (cwd as NSString).lastPathComponent
    return folder.isEmpty ? agent : "\(agent) · \(folder)"
  }

  /// "a kitty window", for the row's help.
  var whereabouts: String {
    switch terminal {
    case "kitty": return "a kitty window"
    default: return place.isEmpty ? terminal : "\(terminal) (\(place))"
    }
  }
}

enum AgentTerminalError: Error, CustomStringConvertible {
  /// The terminal can't be asked as set up ("only unix: sockets").
  case config(String)
  /// The window or pane is gone.
  case closed(String)
  case failed(String)

  var description: String {
    switch self {
    case .config(let message), .closed(let message), .failed(let message): return message
    }
  }

  /// A failed or timed-out run of +what+ ("kitty send-text"), with its
  /// output's first 200 characters.
  static func from(_ result: Result<ChiResult, ChiError>, _ what: String) -> AgentTerminalError {
    switch result {
    case .failure(let error): return .failed(error.description)
    case .success(let r):
      if r.timedOut { return .failed("\(what) timed out") }
      let detail = (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
      return .failed("\(what) failed (exit \(r.status)): \(detail.prefix(200))")
    }
  }
}

/// The terminal-agnostic parts: which foreground program is an agent, what
/// text a paste carries.
enum AgentText {
  /// The first of +names+ that is an agent; with `*` in +agents+ the last
  /// name (the innermost program); nil when none is.
  static func agent(names: [String], agents: [String]) -> String? {
    names.first(where: agents.contains) ?? (agents.contains("*") ? names.last ?? "" : nil)
  }

  /// "/usr/bin/claude" → "claude", a login shell's "-fish" → "fish".
  static func programName(_ arg: String) -> String {
    var name = (arg as NSString).lastPathComponent
    if name.hasPrefix("-") { name.removeFirst() }
    return name
  }

  /// A title without the status glyph agents put in front ("✳ Claude Code").
  static func cleanTitle(_ title: String) -> String {
    guard let first = title.unicodeScalars.first, first.value > 127, !first.properties.isAlphabetic,
          title.dropFirst().first == " " else { return title }
    return String(title.dropFirst(2))
  }

  /// Context as a quote above the message, then one image path per line:
  /// ContextQuote.block's shape (`> line`, `>` for an empty one, a blank line
  /// after). A paste-only text ends in a newline, so the next paste starts
  /// on its own line. Bracketed-paste markers are taken out of the text:
  /// it is wrapped in them to arrive as one paste.
  static func text(context: String, message: String, imagePaths: [String], pasteOnly: Bool) -> String {
    var text = quote(context) ?? ""
    text += message
    let paths = imagePaths.map(shellQuote)
    if !paths.isEmpty {
      if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
      text += paths.joined(separator: "\n")
    }
    while text.hasSuffix("\n") { text.removeLast() }
    if pasteOnly && !text.isEmpty { text += "\n" }
    return text.replacingOccurrences(of: "\u{1b}[200~", with: "").replacingOccurrences(of: "\u{1b}[201~", with: "")
  }

  static func quote(_ context: String) -> String? {
    var lines = context.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
      .components(separatedBy: "\n")
      .map { line -> String in
        var line = line
        while let last = line.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
          line.unicodeScalars.removeLast()
        }
        return line
      }
    while lines.first?.isEmpty == true { lines.removeFirst() }
    while lines.last?.isEmpty == true { lines.removeLast() }
    guard !lines.isEmpty else { return nil }
    return lines.map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n") + "\n\n"
  }

  /// A path as is when it holds only safe characters, else single-quoted
  /// (claude reads a quoted path with spaces as an image).
  static func shellQuote(_ path: String) -> String {
    if path.range(of: #"^[A-Za-z0-9_./~+@%,:=-]+$"#, options: .regularExpression) != nil { return path }
    return "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
  }
}

/// The terminals switched on in a launch file, in a fixed order. Every
/// runner calls back on this +queue+, so the fan-in needs no lock.
final class AgentTerminals {
  let terminals: [AgentTerminal]
  let queue: DispatchQueue

  init(terminals: [AgentTerminal], queue: DispatchQueue) {
    self.terminals = terminals
    self.queue = queue
  }

  /// One runner per section the launch file has; none without a file.
  convenience init(launchPath: String, queue: DispatchQueue = .main) {
    let launch = FileManager.default.contents(atPath: launchPath)
      .flatMap { try? JSONDecoder().decode(LaunchConfig.self, from: $0) }
    var terminals: [AgentTerminal] = []
    if let kitty = launch?.kitty { terminals.append(KittyRunner(settings: kitty, queue: queue)) }
    self.init(terminals: terminals, queue: queue)
  }

  var names: [String] { terminals.map(\.name) }
  var isEmpty: Bool { terminals.isEmpty }

  func terminal(for key: String) -> AgentTerminal? { terminals.first { $0.owns(key: key) } }

  /// Every terminal's targets in terminal order, and the ones that failed.
  func list(completion: @escaping ([AgentTarget], [(name: String, error: AgentTerminalError)]) -> Void) {
    guard !terminals.isEmpty else { queue.async { completion([], []) }; return }
    var results = [Result<[AgentTarget], AgentTerminalError>?](repeating: nil, count: terminals.count)
    var remaining = terminals.count
    for (index, terminal) in terminals.enumerated() {
      terminal.list { result in
        results[index] = result
        remaining -= 1
        guard remaining == 0 else { return }
        var targets: [AgentTarget] = []
        var errors: [(name: String, error: AgentTerminalError)] = []
        for (terminal, result) in zip(self.terminals, results) {
          switch result {
          case .success(let found): targets += found
          case .failure(let error): errors.append((terminal.name, error))
          case nil: break
          }
        }
        completion(targets, errors)
      }
    }
  }
}

/// `ChiHelper --agents list|send …`, run directly (specs, a terminal):
///   --agents list [--launch PATH]                  JSON {"agents": […], "errors": {terminal: message}}
///   --agents send KEY [--paste-only] [--message M] [--image PATH]… [--temp-image PATH]… [--launch PATH]
/// send reads the context from stdin and prints "sent", "pasted" or the
/// error (exit 1). --temp-image is an image the helper wrote (copied first).
func agentsCommand(_ args: [String]) -> Int32 {
  var args = args
  let sub = args.isEmpty ? "" : args.removeFirst()
  var launchPath = ChiRunner.launchPath, key: String?, message = "", pasteOnly = false
  var images: [PanelImage] = []
  while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--launch" where !args.isEmpty: launchPath = args.removeFirst()
    case "--message" where !args.isEmpty: message = args.removeFirst()
    case "--image" where !args.isEmpty: images.append(PanelImage(url: URL(fileURLWithPath: args.removeFirst()), temp: false))
    case "--temp-image" where !args.isEmpty: images.append(PanelImage(url: URL(fileURLWithPath: args.removeFirst()), temp: true))
    case "--paste-only": pasteOnly = true
    default:
      if key == nil && !arg.hasPrefix("--") { key = arg } else { return agentsUsage() }
    }
  }
  let queue = DispatchQueue(label: "agents-command")
  let terminals = AgentTerminals(launchPath: launchPath, queue: queue)
  let done = DispatchSemaphore(value: 0)
  var status: Int32 = 0
  switch sub {
  case "list":
    terminals.list { targets, errors in
      let out: [String: Any] = [
        "agents": targets.map {
          ["key": $0.key, "terminal": $0.terminal, "agent": $0.agent, "title": $0.title, "cwd": $0.cwd, "label": $0.label]
        },
        "errors": Dictionary(errors.map { ($0.name, $0.error.description) }, uniquingKeysWith: { first, _ in first })
      ]
      if !errors.isEmpty { status = 1 }
      let data = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
      print(String(decoding: data, as: UTF8.self))
      done.signal()
    }
  case "send":
    guard let key else { return agentsUsage() }
    guard let terminal = terminals.terminal(for: key) else {
      print("not an agent: \(key)")
      return 1
    }
    let context = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    let paths = ImageIntake.keepForPaste(images)
    let text = AgentText.text(context: context, message: message, imagePaths: paths, pasteOnly: pasteOnly)
    terminal.send(key: key, text: text, pasteOnly: pasteOnly) { result in
      switch result {
      case .success: print(pasteOnly ? "pasted" : "sent")
      case .failure(let error): print(error.description); status = 1
      }
      done.signal()
    }
  default: return agentsUsage()
  }
  done.wait()
  return status
}

private func agentsUsage() -> Int32 {
  FileHandle.standardError.write("usage: ChiHelper --agents list|send KEY [--paste-only] [--message M] [--image PATH] [--launch PATH]\n".data(using: .utf8)!)
  return 2
}
