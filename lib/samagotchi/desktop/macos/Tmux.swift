// Agent CLIs (claude, codex, …) in tmux panes as panel targets, through the
// tmux binary (`tmux -u -S <socket> …`): every server whose socket is in the
// launch file's socket dir (tmux's own `-L` place). The settings come from
// launch.json's "tmux" section (chi desktop bakes it from config.yml's
// tmux:, binary and socket dir resolved then); without it there are no tmux
// targets. One of the AgentTerminals (AgentTerminal.swift).
import Foundation

struct TmuxSettings: Decodable, Equatable {
  let binary: String
  let socketDir: String
  let agents: [String]

  enum CodingKeys: String, CodingKey {
    case socketDir = "socket_dir"
    case binary, agents
  }
}

/// The pure parts: list-panes and ps rows into targets, keys.
enum Tmux {
  /// One pane of `list-panes -a -F listFormat`.
  struct Pane: Equatable {
    let id: String
    let tty: String
    let command: String
    let path: String
    let inMode: Bool
    /// "main:1.0": session, window index, pane index.
    let place: String
    let host: String
    let serverPid: String
    let title: String
  }

  /// Tab-separated, the title last (a tab in a title can't shift the
  /// fields). `#{pid}` is the server's: pane ids restart with a server.
  static let listFormat = ["#{pane_id}", "#{pane_tty}", "#{pane_current_command}", "#{pane_current_path}",
                           "#{pane_dead}", "#{pane_in_mode}", "#{session_name}:#{window_index}.#{pane_index}",
                           "#{host}", "#{pid}", "#{pane_title}"].joined(separator: "\t")

  /// The live panes of one list-panes; dead ones (remain-on-exit) dropped.
  static func panes(listPanes: String) -> [Pane] {
    listPanes.split(separator: "\n").compactMap { line in
      let f = line.split(separator: "\t", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
      guard f.count == 10, f[0].hasPrefix("%"), f[4] != "1" else { return nil }
      return Pane(id: f[0], tty: f[1], command: f[2], path: f[3], inMode: f[5] == "1", place: f[6], host: f[7],
                  serverPid: f[8], title: f[9])
    }
  }

  /// The foreground programs' names per tty ("ttys003", no /dev/), from
  /// `ps -A -o pgid=,tpgid=,tty=,args=`: a process whose group is its
  /// terminal's foreground group; the basenames of its first two words, as
  /// kitty's cmdline[0] and [1] (the native claude sets its title to
  /// "claude"; codex runs as `node …/codex`). Only +ttys+ are kept.
  static func foreground(ps: String, ttys: Set<String>) -> [String: [String]] {
    var found: [String: [String]] = [:]
    for line in ps.split(separator: "\n") {
      let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
      guard f.count == 4, ttys.contains(f[2]), f[0] == f[1] else { continue }
      let names = f[3].split(separator: " ").prefix(2).map { AgentText.programName(String($0)) }.filter { !$0.isEmpty }
      found[f[2], default: []] += names
    }
    return found
  }

  /// "/dev/ttys003" → "ttys003", ps's spelling.
  static func ttyName(_ tty: String) -> String { tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty }

  /// The panes whose foreground program is an agent: matched on ps's names
  /// when ps has the tty, else on pane_current_command (not both: with `*`
  /// the last name wins, and the native claude's current command is its
  /// version, "2.1.296"). A title equal to the host name is tmux's default:
  /// none.
  static func targets(panes: [Pane], foreground: [String: [String]], agents: [String], socket: String) -> [AgentTarget] {
    panes.compactMap { pane in
      let fromPs = foreground[ttyName(pane.tty)] ?? []
      let names = fromPs.isEmpty ? [pane.command].filter { !$0.isEmpty } : fromPs
      guard let agent = AgentText.agent(names: names, agents: agents) else { return nil }
      return AgentTarget(terminal: "tmux", key: "tmux:\(socket)#\(pane.serverPid)#\(pane.id)", agent: agent,
                         title: pane.title == pane.host ? "" : AgentText.cleanTitle(pane.title), cwd: pane.path,
                         place: pane.place, names: names)
    }
  }

  /// A `tmux:<socket>#<server pid>#<pane id>` key back into its parts.
  static func parse(key: String) -> (socket: String, serverPid: String, paneId: String)? {
    guard key.hasPrefix("tmux:") else { return nil }
    let rest = key.dropFirst("tmux:".count)
    guard let paneHash = rest.lastIndex(of: "#") else { return nil }
    let paneId = String(rest[rest.index(after: paneHash)...])
    let head = rest[..<paneHash]
    guard let pidHash = head.lastIndex(of: "#") else { return nil }
    let pid = String(head[head.index(after: pidHash)...])
    let socket = String(head[..<pidHash])
    guard !socket.isEmpty, Int(pid) != nil, paneId.hasPrefix("%"), Int(paneId.dropFirst()) != nil else { return nil }
    return (socket, pid, paneId)
  }
}

final class TmuxRunner: AgentTerminal {
  let name = "tmux"
  let settings: TmuxSettings
  let queue: DispatchQueue
  let env: [String: String]
  let listTimeout: TimeInterval = 2
  let sendTimeout: TimeInterval = 5

  /// @param queue where completions run (the main queue in the app)
  init(settings: TmuxSettings, queue: DispatchQueue = .main,
       env: [String: String] = ProcessInfo.processInfo.environment) {
    self.settings = settings
    self.queue = queue
    self.env = env
  }

  /// The helper's env minus tmux's own variables: a helper started from a
  /// pane must not lean on that pane's server.
  private var tmuxEnv: [String: String] { env.filter { $0.key != "TMUX" && $0.key != "TMUX_PANE" } }

  func owns(key: String) -> Bool { Tmux.parse(key: key) != nil }

  private var binaryError: AgentTerminalError? {
    let binary = settings.binary
    if binary.isEmpty { return .config("tmux not found: set tmux.binary, then chi update") }
    guard FileManager.default.isExecutableFile(atPath: binary) else {
      return .config("tmux not found at \(binary): set tmux.binary, then chi update")
    }
    return nil
  }

  /// The servers' sockets: the socket files in socket_dir (none when it is
  /// missing). A stale one (a killed server's) drops out at list-panes.
  func sockets() -> [String] {
    let dir = settings.socketDir
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    return names.sorted().map { (dir as NSString).appendingPathComponent($0) }
      .filter { (try? FileManager.default.attributesOfItem(atPath: $0)[.type] as? FileAttributeType) == .typeSocket }
  }

  /// Agent panes of every live server; one ps over all of them names the
  /// foreground programs (if it fails, pane_current_command alone).
  func list(completion: @escaping (Result<[AgentTarget], AgentTerminalError>) -> Void) {
    if let error = binaryError { queue.async { completion(.failure(error)) }; return }
    let sockets = self.sockets()
    guard !sockets.isEmpty else { queue.async { completion(.success([])) }; return }
    let group = DispatchGroup()
    let lock = NSLock()
    var bySocket: [String: [Tmux.Pane]] = [:]
    for socket in sockets {
      group.enter()
      tmux(socket, ["list-panes", "-a", "-F", Tmux.listFormat], timeout: listTimeout, on: .global()) { result in
        if case .success(let r) = result, r.status == 0, !r.timedOut {
          let panes = Tmux.panes(listPanes: r.stdout)
          lock.lock(); bySocket[socket] = panes; lock.unlock()
        }
        group.leave()
      }
    }
    group.notify(queue: queue) {
      let all = sockets.flatMap { socket in (bySocket[socket] ?? []).map { (socket, $0) } }
      guard !all.isEmpty else { completion(.success([])); return }
      let ttys = Set(all.map { Tmux.ttyName($0.1.tty) })
      ProcessRunner.run(executable: "/bin/ps", args: ["-A", "-ww", "-o", "pgid=,tpgid=,tty=,args="], env: self.tmuxEnv,
                        timeout: self.listTimeout, queue: self.queue) { result in
        var foreground: [String: [String]] = [:]
        if case .success(let r) = result, r.status == 0, !r.timedOut {
          foreground = Tmux.foreground(ps: r.stdout, ttys: ttys)
        }
        let agents = self.settings.agents
        completion(.success(sockets.flatMap { socket in
          Tmux.targets(panes: bySocket[socket] ?? [], foreground: foreground, agents: agents, socket: socket)
        }))
      }
    }
  }

  /// Checks the pane (same server, alive), leaves copy mode, pastes +text+
  /// through a named buffer (`paste-buffer -p`: bracketed only when the
  /// program asked for it; `-r`: newlines as given), then presses Enter
  /// unless +pasteOnly+. One tmux call: claude and codex submitted reliably
  /// with the Enter right after the paste's end marker, a large paste too.
  func send(key: String, text: String, pasteOnly: Bool, completion: @escaping (Result<Void, AgentTerminalError>) -> Void) {
    guard let (socket, serverPid, pane) = Tmux.parse(key: key) else {
      queue.async { completion(.failure(.failed("not a tmux pane: \(key)"))) }; return
    }
    if let error = binaryError { queue.async { completion(.failure(error)) }; return }
    // A missing pane: exit 0 and no output (not an error), so the id is
    // checked too.
    let probe = ["display-message", "-p", "-t", pane, "#{pid} #{pane_id} #{pane_dead} #{pane_in_mode} #{pane_mode}"]
    tmux(socket, probe, timeout: listTimeout) { result in
      guard case .success(let r) = result, !r.timedOut else {
        completion(.failure(.from(result, "tmux display-message"))); return
      }
      let f = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
      guard r.status == 0, f.count >= 4, f[0] == serverPid, f[1] == pane, f[2] == "0" else {
        completion(.failure(.closed("pane closed"))); return
      }
      let mode = f.count > 4 ? f[4] : ""
      let paste = { self.paste(socket, pane: pane, text: text, pasteOnly: pasteOnly, completion: completion) }
      guard f[3] == "1" else { paste(); return }
      guard mode == "copy-mode" || mode == "view-mode" else {
        completion(.failure(.failed("pane in \(mode.isEmpty ? "a mode" : mode)"))); return
      }
      // Copy mode would eat the Enter: left first (the scroll position goes).
      self.tmux(socket, ["send-keys", "-t", pane, "-X", "cancel"], timeout: self.sendTimeout) { result in
        guard case .success(let r) = result, r.status == 0, !r.timedOut else {
          completion(.failure(.from(result, "tmux send-keys -X cancel"))); return
        }
        paste()
      }
    }
  }

  private func paste(_ socket: String, pane: String, text: String, pasteOnly: Bool,
                     completion: @escaping (Result<Void, AgentTerminalError>) -> Void) {
    let buffer = "chi-helper-\(UUID().uuidString)"
    var args = ["load-buffer", "-b", buffer, "-", ";", "paste-buffer", "-p", "-r", "-d", "-b", buffer, "-t", pane]
    if !pasteOnly { args += [";", "send-keys", "-t", pane, "Enter"] }
    tmux(socket, args, stdin: Data(text.utf8), timeout: sendTimeout) { result in
      guard case .success(let r) = result, r.status == 0, !r.timedOut else {
        // A failed chain stops there and may leave the buffer behind.
        self.tmux(socket, ["delete-buffer", "-b", buffer], timeout: self.sendTimeout) { _ in
          completion(.failure(.from(result, "tmux paste")))
        }
        return
      }
      completion(.success(()))
    }
  }

  /// `-u`: UTF-8 output even with launchd's bare env (no LANG).
  private func tmux(_ socket: String, _ args: [String], stdin: Data? = nil, timeout: TimeInterval,
                    on queue: DispatchQueue? = nil, completion: @escaping (Result<ChiResult, ChiError>) -> Void) {
    ProcessRunner.run(executable: settings.binary, args: ["-u", "-S", socket] + args, env: tmuxEnv,
                      stdin: stdin, timeout: timeout, queue: queue ?? self.queue, completion: completion)
  }
}
