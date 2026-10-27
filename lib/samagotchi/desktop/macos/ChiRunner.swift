// Runs chi the way `chi desktop install` wrote down in launch.json: an
// absolute ruby + bin/chi and a few env vars, since an app started by
// launchd has none of the shell's setup. Talks to chi only through its CLI.
import Foundation

struct LaunchConfig: Decodable {
  let version: String?
  let argv: [String]
  let env: [String: String]?
  /// Agents in kitty windows (Kitty.swift); nil = none. AgentTerminals
  /// makes one runner per terminal section.
  let kitty: KittySettings?
  /// Agents in tmux panes (Tmux.swift); nil = none.
  let tmux: TmuxSettings?
  /// Seconds `chi broadcast` may take (Broadcast.swift); nil = the default.
  let broadcastTimeout: Double?

  enum CodingKeys: String, CodingKey {
    case version, argv, env, kitty, tmux
    case broadcastTimeout = "broadcast_timeout"
  }
}

enum ChiError: Error, CustomStringConvertible {
  case noLaunchFile(String)
  case missing(String)
  case failed(String)

  var description: String {
    switch self {
    case .noLaunchFile(let path): return "No launch file at \(path). Run `chi desktop upgrade` in a terminal."
    case .missing(let path): return "chi not found at \(path). Run `chi desktop upgrade` in a terminal."
    case .failed(let message): return message
    }
  }
}

/// One session from `chi sessions list --format json`: a live one, or a
/// recent stopped one (listed below the live ones; a message wakes it), on
/// this Mac or on a remote (`chi --remote NAME sessions list`).
struct LiveSession: Decodable, Identifiable, Equatable {
  let id: String
  let desc: String?
  let cwd: String?
  let busy: Bool?
  let owner: String?
  let updatedAt: String?
  var recent = false
  /// The remote it was listed on (set by the helper, never decoded); nil:
  /// this Mac.
  var remote: String?

  enum CodingKeys: String, CodingKey {
    case id, desc, cwd, busy, owner
    case updatedAt = "updated_at"
  }

  /// Only UUID-shaped ids go into chi's argv, so nothing can turn into a flag.
  var valid: Bool { UUID(uuidString: id) != nil }

  /// The row's key in the selection, ⌘ numbers and the remembered choice:
  /// "studio:<id>" on a remote, the plain id on this Mac (so a choice
  /// remembered before remotes still counts).
  var key: String { remote.map { "\($0):\(id)" } ?? id }

  /// A remote's home may differ from this Mac's: its path stays whole.
  var shortCwd: String { remote == nil ? cwd.map(Self.shorten) ?? "" : cwd ?? "" }

  /// A path with the home folder as "~".
  static func shorten(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }

  var updated: Date? {
    guard let updatedAt else { return nil }
    let precise = ISO8601DateFormatter()
    precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return precise.date(from: updatedAt) ?? ISO8601DateFormatter().date(from: updatedAt)
  }

  /// "just now", "5m ago", "2h ago", "yesterday", "3d ago", or "".
  func age(now: Date = Date()) -> String {
    guard let date = updated else { return "" }
    let seconds = max(0, now.timeIntervalSince(date))
    switch seconds {
    case ..<60: return "just now"
    case ..<3600: return "\(Int(seconds / 60))m ago"
    case ..<86_400: return "\(Int(seconds / 3600))h ago"
    case ..<172_800: return "yesterday"
    default: return "\(Int(seconds / 86_400))d ago"
    }
  }
}

/// The remotes `chi remote ls` keeps (`chi remote add`): a name goes into
/// argv only when it came from that answer and passes chi's own rule.
enum Remotes {
  /// One row of `chi remote ls --format json`; the token itself never
  /// leaves chi, only whether there is one.
  struct Entry: Decodable {
    let name: String
    let token: Bool?
  }

  /// chi's `Remotes::NAME`: no leading "-", so never a flag.
  static func valid(_ name: String) -> Bool {
    name.range(of: "\\A[A-Za-z0-9][A-Za-z0-9_-]{0,39}\\z", options: .regularExpression) != nil
  }

  /// The names with a token (one without can't reach that chi web), in
  /// chi's order.
  static func names(_ entries: [Entry]) -> [String] {
    var seen = Set<String>()
    return entries.filter { $0.token == true && valid($0.name) && seen.insert($0.name).inserted }.map(\.name)
  }
}

/// A remote's part of the panel: its rows, or why there are none.
struct RemoteSection: Equatable {
  let name: String
  var sessions: [LiveSession] = []
  /// "studio: no answer within 4 s", or the first line of chi's stderr.
  var error: String?
  var loading = true
}

final class ChiRunner {
  /// A remote's two lists together: chi's own open timeout is 5 s, so a
  /// down host is stopped here before chi says anything.
  static let remoteBudget: TimeInterval = 4

  static let supportDir = NSString(string: "~/Library/Application Support/Chi Helper").expandingTildeInPath
  static let launchPath = supportDir + "/launch.json"

  let timeout: TimeInterval
  let launchPath: String

  /// @param launchPath another launch file (a test harness's), not the app's
  init(timeout: TimeInterval = 10, launchPath: String = ChiRunner.launchPath) {
    self.timeout = timeout
    self.launchPath = launchPath
  }

  func loadLaunch() throws -> LaunchConfig {
    guard let data = FileManager.default.contents(atPath: launchPath) else {
      throw ChiError.noLaunchFile(launchPath)
    }
    let config: LaunchConfig
    do { config = try JSONDecoder().decode(LaunchConfig.self, from: data) } catch {
      throw ChiError.failed("Unreadable launch file \(launchPath): \(error.localizedDescription)")
    }
    guard !config.argv.isEmpty else { throw ChiError.failed("Empty argv in \(launchPath)") }
    for path in config.argv where path.hasPrefix("/") && !FileManager.default.fileExists(atPath: path) {
      throw ChiError.missing(path)
    }
    return config
  }

  /// Runs `chi <args>` through ProcessRunner (no pipe deadlock near the
  /// 16 KiB note cap). Calls back on +queue+ (the main queue by default; a
  /// headless seam waits on another one); a launch file that can't be read
  /// calls back at once.
  /// @param timeout this call's limit instead of the runner's
  func run(_ args: [String], stdin: Data? = nil, timeout: TimeInterval? = nil, queue: DispatchQueue = .main,
           completion: @escaping (Result<ChiResult, ChiError>) -> Void) {
    let config: LaunchConfig
    do { config = try loadLaunch() } catch let error as ChiError {
      completion(.failure(error)); return
    } catch {
      completion(.failure(.failed("\(error)"))); return
    }

    var env = ProcessInfo.processInfo.environment.merging(config.env ?? [:]) { _, baked in baked }
    // chi reads CHI_REMOTE for every call without --remote: one from the
    // shell would send this Mac's rows to a remote. --remote is the only way.
    env["CHI_REMOTE"] = nil
    ProcessRunner.run(executable: config.argv[0], args: Array(config.argv.dropFirst()) + args,
                      env: env, stdin: stdin, timeout: timeout ?? self.timeout, queue: queue, completion: completion)
  }

  /// The live sessions, oldest started first, then up to +recentCount+
  /// stopped ones, newest first. The live order is by creation so ⌘1…⌘9
  /// stay on their sessions as turns update them; a new one comes last.
  /// A session a chi REPL holds is in neither: it takes no notes or
  /// messages. A failed second call just leaves "recent" empty. Calls
  /// back on +queue+ (a headless seam waits on another one).
  func sessions(recentCount: Int = 3, queue: DispatchQueue = .main,
                completion: @escaping (Result<[LiveSession], ChiError>) -> Void) {
    list(Self.liveFlags, queue: queue) { result in
      guard case .success(let live) = result else { completion(result); return }
      self.list(Self.recentFlags, queue: queue) { recent in
        completion(.success(Self.rows(live: live, recent: recent, recentCount: recentCount)))
      }
    }
  }

  private static let liveFlags = ["--live", "--sort", "created_at", "--order", "asc"]
  private static let recentFlags = ["--limit", "20"]

  /// The live rows, then up to +recentCount+ of the recent list that are
  /// neither live nor a REPL's; a failed recent list adds none.
  private static func rows(live: [LiveSession], recent: Result<[LiveSession], ChiError>, recentCount: Int) -> [LiveSession] {
    let liveIds = Set(live.map(\.id))
    let stopped = ((try? recent.get()) ?? [])
      .filter { $0.owner == nil && !liveIds.contains($0.id) }
      .prefix(recentCount)
      .map { session -> LiveSession in var session = session; session.recent = true; return session }
    return live + stopped
  }

  /// `chi remote ls --format json`: the remotes with a token, in chi's
  /// order; none when it fails (an older chi has no `remote`).
  func remotes(queue: DispatchQueue = .main, completion: @escaping ([String]) -> Void) {
    run(["remote", "ls", "--format", "json"], queue: queue) { result in
      guard case .success(let r) = result, r.status == 0, !r.timedOut,
            let entries = try? JSONDecoder().decode([Remotes.Entry].self, from: Data(r.stdout.utf8)) else {
        completion([]); return
      }
      completion(Remotes.names(entries))
    }
  }

  /// A remote's rows as sessions(...) lists this Mac's, each tagged with
  /// +name+. Its two lists run at once under one budget (each is a chi boot
  /// and two requests); the failure is the panel's line for that remote.
  func sessions(remote name: String, recentCount: Int = 3, queue: DispatchQueue = .main,
                completion: @escaping (Result<[LiveSession], ChiError>) -> Void) {
    var live: Result<[LiveSession], ChiError>?
    var recent: Result<[LiveSession], ChiError>?
    // Both answer on +queue+, one at a time.
    let finish = {
      guard let live, let recent else { return }
      completion(live.map { rows in
        Self.rows(live: rows, recent: recent, recentCount: recentCount)
          .map { session -> LiveSession in var session = session; session.remote = name; return session }
      })
    }
    list(Self.liveFlags, remote: name, queue: queue) { live = $0; finish() }
    list(Self.recentFlags, remote: name, queue: queue) { recent = $0; finish() }
  }

  /// The model a new session starts on (`chi self --model`: the config's
  /// default, as chi resolves it), or nil when none is configured or chi
  /// can't say. Only a single line counts: nothing that looks like a whole
  /// `chi self` report ends up as the hint.
  func defaultModel(completion: @escaping (String?) -> Void) {
    run(["self", "--model"]) { result in
      guard case .success(let r) = result, r.status == 0, !r.timedOut else { completion(nil); return }
      let model = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      completion(model.isEmpty || model.contains("\n") ? nil : model)
    }
  }

  /// `chi models --format json`: every host's models and the aliases. Exit
  /// 1 (no host listed) still prints the default and the warnings. 10 s:
  /// the boot and chi's own 4 s cap on the hosts, with a margin.
  func models(completion: @escaping (Result<ModelList, ChiError>) -> Void) {
    run(["models", "--format", "json"], timeout: 10) { result in
      switch result {
      case .failure(let error): completion(.failure(error))
      case .success(let r):
        if r.timedOut { completion(.failure(.failed("chi models took over 10 s"))); return }
        guard r.status == 0 || r.status == 1, let list = ModelList.decode(Data(r.stdout.utf8)) else {
          let detail = r.stderr.isEmpty ? r.stdout : r.stderr
          completion(.failure(.failed("chi models failed (exit \(r.status)): \(detail.prefix(300))")))
          return
        }
        completion(.success(list))
      }
    }
  }

  /// @param remote a remote's name: `--remote NAME` first, the remote
  ///   budget, and its two failure lines (no answer in time, or the first
  ///   line of chi's stderr: it names the remote and why)
  private func list(_ flags: [String], remote: String? = nil, queue: DispatchQueue = .main,
                    completion: @escaping (Result<[LiveSession], ChiError>) -> Void) {
    let prefix = remote.map { ["--remote", $0] } ?? []
    let timeout = remote == nil ? self.timeout : Self.remoteBudget
    // Every project's sessions: the helper isn't in any one project (an
    // older chi ignores the flag).
    run(prefix + ["sessions", "list"] + flags + ["--scope=all", "--format", "json"], timeout: timeout,
        queue: queue) { result in
      switch result {
      case .failure(let error): completion(.failure(error))
      case .success(let r):
        if r.timedOut {
          let message = remote.map { "\($0): no answer within \(Int(timeout)) s" } ?? "chi sessions list took over \(Int(timeout)) s"
          completion(.failure(.failed(message)))
          return
        }
        guard r.status == 0, let data = r.stdout.data(using: .utf8),
              let sessions = try? JSONDecoder().decode([LiveSession].self, from: data) else {
          let detail = r.stderr.isEmpty ? r.stdout : r.stderr
          if let remote {
            // chi's own line names the remote and why; Ruby's warnings
            // ("…: warning: …") before it aren't the reason.
            let line = r.status == 0 ? nil : detail.split(whereSeparator: \.isNewline).map(String.init)
              .first { !$0.contains("warning:") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let fallback = r.status == 0 ? "\(remote): chi sessions list answered no session list"
                                         : "\(remote): chi sessions list failed (exit \(r.status))"
            completion(.failure(.failed(line ?? fallback)))
            return
          }
          completion(.failure(.failed("chi sessions list failed (exit \(r.status)): \(detail.prefix(400))")))
          return
        }
        completion(.success(sessions.filter(\.valid)))
      }
    }
  }
}
