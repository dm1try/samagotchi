// Agent CLIs (claude, codex, …) in kitty windows as panel targets, through
// the kitty binary's remote control (`kitty @ --to unix:<socket> …`). The
// settings come from launch.json's "kitty" section (chi desktop bakes it
// from config.yml's kitty:); without it there are no kitty targets. One of
// the AgentTerminals (AgentTerminal.swift).
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
  static func windows(ls data: Data, socket: String, agents: [String]) -> [AgentTarget] {
    guard let osWindows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    var found: [AgentTarget] = []
    for osWindow in osWindows {
      for tab in osWindow["tabs"] as? [[String: Any]] ?? [] {
        for window in tab["windows"] as? [[String: Any]] ?? [] {
          guard let id = window["id"] as? Int else { continue }
          let names = (window["foreground_processes"] as? [[String: Any]] ?? []).flatMap { process -> [String] in
            let cmdline = process["cmdline"] as? [String] ?? []
            return cmdline.prefix(2).map(AgentText.programName)
          }.filter { !$0.isEmpty }
          guard let agent = AgentText.agent(names: names, agents: agents) else { continue }
          found.append(AgentTarget(terminal: "kitty", key: "\(socket)#\(id)", agent: agent,
                                   title: AgentText.cleanTitle(window["title"] as? String ?? ""),
                                   cwd: window["cwd"] as? String ?? "", place: "", names: names))
        }
      }
    }
    return found
  }

  /// A `<socket>#<window id>` key back into its parts.
  static func parse(key: String) -> (socket: String, windowId: Int)? {
    guard let hash = key.lastIndex(of: "#"), let id = Int(key[key.index(after: hash)...]) else { return nil }
    let socket = String(key[..<hash])
    return socket.isEmpty ? nil : (socket, id)
  }
}

final class KittyRunner: AgentTerminal {
  let name = "kitty"
  let settings: KittySettings
  let queue: DispatchQueue
  let env: [String: String]
  let lsTimeout: TimeInterval = 2
  let sendTimeout: TimeInterval = 5

  /// @param queue where completions run (the main queue in the app)
  init(settings: KittySettings, queue: DispatchQueue = .main,
       env: [String: String] = ProcessInfo.processInfo.environment) {
    self.settings = settings
    self.queue = queue
    self.env = env
  }

  /// kitty @ runs, and listen_on expands, with the helper's env minus
  /// kitty's own variables (a helper started from a kitty window must not
  /// talk to that one, nor fill in the ${KITTY_PID} kitty keeps literal).
  private var kittyEnv: [String: String] { env.filter { !$0.key.hasPrefix("KITTY_") } }

  /// The sockets listen_on names: the files in its folder whose names match
  /// (a directory listing, not glob(): the path may hold `${ }` literally).
  func sockets() -> Result<[String], AgentTerminalError> {
    guard let path = Kitty.socketPath(listenOn: settings.listenOn, env: kittyEnv) else {
      return .failure(.config("kitty.listen_on \(settings.listenOn): only unix: sockets"))
    }
    let dir = (path as NSString).deletingLastPathComponent
    let base = (path as NSString).lastPathComponent
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    return .success(names.filter { Kitty.socketName($0, matches: base) }.sorted()
      .map { (dir as NSString).appendingPathComponent($0) }
      .filter { (try? FileManager.default.attributesOfItem(atPath: $0)[.type] as? FileAttributeType) == .typeSocket })
  }

  /// Agent windows from every live socket; a dead one drops out silently.
  func owns(key: String) -> Bool { Kitty.parse(key: key) != nil }

  func list(completion: @escaping (Result<[AgentTarget], AgentTerminalError>) -> Void) {
    let sockets: [String]
    switch self.sockets() {
    case .failure(let error): queue.async { completion(.failure(error)) }; return
    case .success(let found): sockets = found
    }
    guard !sockets.isEmpty else { queue.async { completion(.success([])) }; return }
    let group = DispatchGroup()
    let lock = NSLock()
    let agents = settings.agents
    var bySocket: [String: [AgentTarget]] = [:]
    for socket in sockets {
      group.enter()
      kitty(socket, ["ls"], timeout: lsTimeout, on: .global()) { result in
        if case .success(let r) = result, r.status == 0, !r.timedOut {
          let found = Kitty.windows(ls: Data(r.stdout.utf8), socket: socket, agents: agents)
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
  func send(key: String, text: String, pasteOnly: Bool, completion: @escaping (Result<Void, AgentTerminalError>) -> Void) {
    guard let (socket, id) = Kitty.parse(key: key) else {
      queue.async { completion(.failure(.failed("not a kitty window: \(key)"))) }; return
    }
    let match = ["--match", "id:\(id)"]
    kitty(socket, ["ls"] + match, timeout: lsTimeout) { result in
      guard case .success(let r) = result, !r.timedOut else {
        completion(.failure(.from(result, "kitty ls"))); return
      }
      guard r.status == 0 else { completion(.failure(.closed("window closed"))); return }
      let paste = Data(("\u{1b}[200~" + text + "\u{1b}[201~").utf8)
      self.kitty(socket, ["send-text"] + match + ["--bracketed-paste=disable", "--stdin"], stdin: paste,
                 timeout: self.sendTimeout) { result in
        guard case .success(let r) = result, r.status == 0, !r.timedOut else {
          completion(.failure(.from(result, "kitty send-text"))); return
        }
        if pasteOnly { completion(.success(())); return }
        self.kitty(socket, ["send-key"] + match + ["enter"], timeout: self.sendTimeout) { result in
          guard case .success(let r) = result, r.status == 0, !r.timedOut else {
            completion(.failure(.from(result, "kitty send-key"))); return
          }
          completion(.success(()))
        }
      }
    }
  }

  private func kitty(_ socket: String, _ args: [String], stdin: Data? = nil, timeout: TimeInterval,
                     on queue: DispatchQueue? = nil, completion: @escaping (Result<ChiResult, ChiError>) -> Void) {
    ProcessRunner.run(executable: settings.binary, args: ["@", "--to", "unix:\(socket)"] + args, env: kittyEnv,
                      stdin: stdin, timeout: timeout, queue: queue ?? self.queue, completion: completion)
  }
}
