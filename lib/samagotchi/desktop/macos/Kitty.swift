// Agent CLIs (claude, codex, …) in kitty windows as panel targets, through
// the kitty binary's remote control (`kitty @ --to unix:<socket> …`). The
// settings come from launch.json's "kitty" section (chi desktop bakes it
// from config.yml's kitty:); without it there are no kitty targets.
import Foundation

struct KittySettings: Decodable, Equatable {
  let listenOn: String
  let binary: String
  let agents: [String]

  enum CodingKeys: String, CodingKey {
    case listenOn = "listen_on"
    case binary, agents
  }
}

/// One kitty window running an agent: `<socket>#<id>` keys it.
struct KittyWindow: Identifiable, Equatable {
  let socket: String
  let windowId: Int
  let agent: String
  let title: String
  let cwd: String

  var id: String { key }
  var key: String { "\(socket)#\(windowId)" }
  var shortCwd: String { LiveSession.shorten(cwd) }
  /// "claude · samagotchi": the agent and its folder.
  var label: String {
    let folder = (cwd as NSString).lastPathComponent
    return folder.isEmpty ? agent : "\(agent) · \(folder)"
  }

  /// Parses a key back into its socket and window id.
  static func parse(key: String) -> (socket: String, windowId: Int)? {
    guard let hash = key.lastIndex(of: "#"), let id = Int(key[key.index(after: hash)...]) else { return nil }
    let socket = String(key[..<hash])
    return socket.isEmpty ? nil : (socket, id)
  }
}

enum KittyError: Error, CustomStringConvertible {
  case notUnix(String)
  case windowClosed
  case failed(String)

  var description: String {
    switch self {
    case .notUnix(let value): return "kitty.listen_on \(value): only unix: sockets"
    case .windowClosed: return "window closed"
    case .failed(let message): return message
    }
  }
}

/// The pure parts: which files are sockets of this listen_on, which windows
/// are agents, what text a paste carries. The runner below does the I/O.
enum Kitty {
  /// listen_on's path with `~`, `$VAR` and `${VAR}` expanded from +env+
  /// (unknown variables stay as written: kitty.conf's `${KITTY_PID}` is not
  /// expanded by kitty either). Nil for anything but `unix:`.
  static func socketPath(listenOn: String, env: [String: String]) -> String? {
    guard listenOn.hasPrefix("unix:") else { return nil }
    var path = String(listenOn.dropFirst("unix:".count))
    let home = env["HOME"] ?? NSHomeDirectory()
    if path == "~" || path.hasPrefix("~/") { path = home + path.dropFirst() }
    let pattern = try! NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)"#)
    var result = ""
    var last = path.startIndex
    for match in pattern.matches(in: path, range: NSRange(path.startIndex..., in: path)) {
      let whole = Range(match.range, in: path)!
      let nameRange = Range(match.range(at: 1), in: path) ?? Range(match.range(at: 2), in: path)!
      result += path[last..<whole.lowerBound]
      result += env[String(path[nameRange])] ?? String(path[whole])
      last = whole.upperBound
    }
    return result + path[last...]
  }

  /// Whether +name+ is a socket name kitty makes from +base+: base itself,
  /// base with `-<pid>` appended (kitty.conf's listen_on without
  /// {kitty_pid}), or base with {kitty_pid} filled in.
  static func socketName(_ name: String, matches base: String) -> Bool {
    let parts = base.components(separatedBy: "{kitty_pid}")
    let pattern = parts.map(NSRegularExpression.escapedPattern(for:)).joined(separator: #"\d+"#)
    let full = parts.count > 1 ? "^\(pattern)$" : "^\(pattern)(-\\d+)?$"
    return name.range(of: full, options: .regularExpression) != nil
  }

  /// The windows of one `kitty @ ls` whose foreground programs include an
  /// agent: the basename of a process's cmdline[0] or cmdline[1] (codex and
  /// gemini run as `node …/codex`); `*` takes every window.
  static func windows(ls data: Data, socket: String, agents: [String]) -> [KittyWindow] {
    guard let osWindows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    let all = agents.contains("*")
    var found: [KittyWindow] = []
    for osWindow in osWindows {
      for tab in osWindow["tabs"] as? [[String: Any]] ?? [] {
        for window in tab["windows"] as? [[String: Any]] ?? [] {
          guard let id = window["id"] as? Int else { continue }
          let names = (window["foreground_processes"] as? [[String: Any]] ?? []).flatMap { process -> [String] in
            let cmdline = process["cmdline"] as? [String] ?? []
            return cmdline.prefix(2).map(programName)
          }.filter { !$0.isEmpty }
          guard let agent = names.first(where: agents.contains) ?? (all ? names.last ?? "" : nil) else { continue }
          found.append(KittyWindow(socket: socket, windowId: id, agent: agent,
                                   title: cleanTitle(window["title"] as? String ?? ""),
                                   cwd: window["cwd"] as? String ?? ""))
        }
      }
    }
    return found
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

final class KittyRunner {
  let settings: KittySettings?
  let queue: DispatchQueue
  let env: [String: String]
  let lsTimeout: TimeInterval = 2
  let sendTimeout: TimeInterval = 5

  /// @param queue where completions run (the main queue in the app)
  init(settings: KittySettings?, queue: DispatchQueue = .main,
       env: [String: String] = ProcessInfo.processInfo.environment) {
    self.settings = settings
    self.queue = queue
    self.env = env
  }

  /// From a launch file; no settings when it has no kitty section.
  convenience init(launchPath: String, queue: DispatchQueue = .main) {
    let launch = FileManager.default.contents(atPath: launchPath)
      .flatMap { try? JSONDecoder().decode(LaunchConfig.self, from: $0) }
    self.init(settings: launch?.kitty, queue: queue)
  }

  /// kitty @ runs, and listen_on expands, with the helper's env minus
  /// kitty's own variables (a helper started from a kitty window must not
  /// talk to that one, nor fill in the ${KITTY_PID} kitty keeps literal).
  private var kittyEnv: [String: String] { env.filter { !$0.key.hasPrefix("KITTY_") } }

  /// The sockets listen_on names: the files in its folder whose names match
  /// (a directory listing, not glob(): the path may hold `${ }` literally).
  func sockets() -> Result<[String], KittyError> {
    guard let settings else { return .success([]) }
    guard let path = Kitty.socketPath(listenOn: settings.listenOn, env: kittyEnv) else {
      return .failure(.notUnix(settings.listenOn))
    }
    let dir = (path as NSString).deletingLastPathComponent
    let base = (path as NSString).lastPathComponent
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    return .success(names.filter { Kitty.socketName($0, matches: base) }.sorted()
      .map { (dir as NSString).appendingPathComponent($0) }
      .filter { (try? FileManager.default.attributesOfItem(atPath: $0)[.type] as? FileAttributeType) == .typeSocket })
  }

  /// Agent windows from every live socket; a dead one drops out silently.
  func windows(completion: @escaping (Result<[KittyWindow], KittyError>) -> Void) {
    let sockets: [String]
    switch self.sockets() {
    case .failure(let error): queue.async { completion(.failure(error)) }; return
    case .success(let found): sockets = found
    }
    guard let settings, !sockets.isEmpty else { queue.async { completion(.success([])) }; return }
    let group = DispatchGroup()
    let lock = NSLock()
    var bySocket: [String: [KittyWindow]] = [:]
    for socket in sockets {
      group.enter()
      kitty(socket, ["ls"], timeout: lsTimeout, on: .global()) { result in
        if case .success(let r) = result, r.status == 0, !r.timedOut {
          let found = Kitty.windows(ls: Data(r.stdout.utf8), socket: socket, agents: settings.agents)
          lock.lock(); bySocket[socket] = found; lock.unlock()
        }
        group.leave()
      }
    }
    group.notify(queue: queue) { completion(.success(sockets.flatMap { bySocket[$0] ?? [] })) }
  }

  /// Pastes +text+ into the window as one bracketed paste, then presses
  /// Enter unless +pasteOnly+. send-text reports nothing, even for a gone
  /// window, so `ls --match` checks the window first.
  func send(key: String, text: String, pasteOnly: Bool, completion: @escaping (Result<Void, KittyError>) -> Void) {
    guard let (socket, id) = KittyWindow.parse(key: key) else {
      queue.async { completion(.failure(.failed("not a kitty window: \(key)"))) }; return
    }
    let match = ["--match", "id:\(id)"]
    kitty(socket, ["ls"] + match, timeout: lsTimeout) { result in
      guard case .success(let r) = result, !r.timedOut else {
        completion(.failure(self.failure(result, "kitty ls"))); return
      }
      guard r.status == 0 else { completion(.failure(.windowClosed)); return }
      let paste = Data(("\u{1b}[200~" + text + "\u{1b}[201~").utf8)
      self.kitty(socket, ["send-text"] + match + ["--bracketed-paste=disable", "--stdin"], stdin: paste,
                 timeout: self.sendTimeout) { result in
        guard case .success(let r) = result, r.status == 0, !r.timedOut else {
          completion(.failure(self.failure(result, "kitty send-text"))); return
        }
        if pasteOnly { completion(.success(())); return }
        self.kitty(socket, ["send-key"] + match + ["enter"], timeout: self.sendTimeout) { result in
          guard case .success(let r) = result, r.status == 0, !r.timedOut else {
            completion(.failure(self.failure(result, "kitty send-key"))); return
          }
          completion(.success(()))
        }
      }
    }
  }

  private func failure(_ result: Result<ChiResult, ChiError>, _ what: String) -> KittyError {
    switch result {
    case .failure(let error): return .failed(error.description)
    case .success(let r):
      if r.timedOut { return .failed("\(what) timed out") }
      let detail = (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
      return .failed("\(what) failed (exit \(r.status)): \(detail.prefix(200))")
    }
  }

  private func kitty(_ socket: String, _ args: [String], stdin: Data? = nil, timeout: TimeInterval,
                     on queue: DispatchQueue? = nil, completion: @escaping (Result<ChiResult, ChiError>) -> Void) {
    guard let settings else { return }
    ProcessRunner.run(executable: settings.binary, args: ["@", "--to", "unix:\(socket)"] + args, env: kittyEnv,
                      stdin: stdin, timeout: timeout, queue: queue ?? self.queue, completion: completion)
  }
}

/// `ChiHelper --kitty list|send …`, run directly (specs, a terminal):
///   --kitty list [--launch PATH]                  JSON {"windows": […], "error": …}
///   --kitty send KEY [--paste-only] [--message M] [--image PATH]… [--temp-image PATH]… [--launch PATH]
/// send reads the context from stdin and prints "sent", "pasted" or the
/// error (exit 1). --temp-image is an image the helper wrote (copied first).
func kittyCommand(_ args: [String]) -> Int32 {
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
      if key == nil && !arg.hasPrefix("--") { key = arg } else { return kittyUsage() }
    }
  }
  let queue = DispatchQueue(label: "kitty-command")
  let runner = KittyRunner(launchPath: launchPath, queue: queue)
  let done = DispatchSemaphore(value: 0)
  var status: Int32 = 0
  switch sub {
  case "list":
    runner.windows { result in
      var out: [String: Any] = ["windows": [], "error": NSNull()]
      switch result {
      case .success(let windows):
        out["windows"] = windows.map { ["key": $0.key, "agent": $0.agent, "title": $0.title, "cwd": $0.cwd, "label": $0.label] }
      case .failure(let error): out["error"] = error.description; status = 1
      }
      let data = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
      print(String(decoding: data, as: UTF8.self))
      done.signal()
    }
  case "send":
    guard let key else { return kittyUsage() }
    let context = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    let paths = ImageIntake.keepForPaste(images)
    let text = Kitty.text(context: context, message: message, imagePaths: paths, pasteOnly: pasteOnly)
    runner.send(key: key, text: text, pasteOnly: pasteOnly) { result in
      switch result {
      case .success: print(pasteOnly ? "pasted" : "sent")
      case .failure(let error): print(error.description); status = 1
      }
      done.signal()
    }
  default: return kittyUsage()
  }
  done.wait()
  return status
}

private func kittyUsage() -> Int32 {
  FileHandle.standardError.write("usage: ChiHelper --kitty list|send KEY [--paste-only] [--message M] [--image PATH] [--launch PATH]\n".data(using: .utf8)!)
  return 2
}
