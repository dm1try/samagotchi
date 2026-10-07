// Runs chi the way `chi desktop install` wrote down in launch.json: an
// absolute ruby + bin/chi and a few env vars, since an app started by
// launchd has none of the shell's setup. Talks to chi only through its CLI.
import Foundation

struct LaunchConfig: Decodable {
  let version: String?
  let argv: [String]
  let env: [String: String]?
  /// Agents in kitty windows (Kitty.swift); nil = none.
  let kitty: KittySettings?
  /// Seconds `chi broadcast` may take (Broadcast.swift); nil = the default.
  let broadcastTimeout: Double?

  enum CodingKeys: String, CodingKey {
    case version, argv, env, kitty
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
/// recent stopped one (listed below the live ones; a message wakes it).
struct LiveSession: Decodable, Identifiable, Equatable {
  let id: String
  let desc: String?
  let cwd: String?
  let busy: Bool?
  let owner: String?
  let updatedAt: String?
  var recent = false

  enum CodingKeys: String, CodingKey {
    case id, desc, cwd, busy, owner
    case updatedAt = "updated_at"
  }

  /// Only UUID-shaped ids go into chi's argv, so nothing can turn into a flag.
  var valid: Bool { UUID(uuidString: id) != nil }

  var shortCwd: String { cwd.map(Self.shorten) ?? "" }

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

final class ChiRunner {
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

    ProcessRunner.run(executable: config.argv[0], args: Array(config.argv.dropFirst()) + args,
                      env: ProcessInfo.processInfo.environment.merging(config.env ?? [:]) { _, baked in baked },
                      stdin: stdin, timeout: timeout ?? self.timeout, queue: queue, completion: completion)
  }

  /// The live sessions, oldest started first, then up to +recentCount+
  /// stopped ones, newest first. The live order is by creation so ⌘1…⌘9
  /// stay on their sessions as turns update them; a new one comes last.
  /// A session a chi REPL holds is in neither: it takes no notes or
  /// messages. A failed second call just leaves "recent" empty.
  func sessions(recentCount: Int = 3, completion: @escaping (Result<[LiveSession], ChiError>) -> Void) {
    list(["--live", "--sort", "created_at", "--order", "asc"]) { result in
      guard case .success(let live) = result else { completion(result); return }
      self.list(["--limit", "20"]) { recent in
        let liveIds = Set(live.map(\.id))
        let stopped = ((try? recent.get()) ?? [])
          .filter { $0.owner == nil && !liveIds.contains($0.id) }
          .prefix(recentCount)
          .map { session -> LiveSession in var session = session; session.recent = true; return session }
        completion(.success(live + stopped))
      }
    }
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

  private func list(_ flags: [String], completion: @escaping (Result<[LiveSession], ChiError>) -> Void) {
    // Every project's sessions: the helper isn't in any one project (an
    // older chi ignores the flag).
    run(["sessions", "list"] + flags + ["--scope=all", "--format", "json"]) { result in
      switch result {
      case .failure(let error): completion(.failure(error))
      case .success(let r):
        if r.timedOut { completion(.failure(.failed("chi sessions list took over \(Int(self.timeout)) s"))); return }
        guard r.status == 0, let data = r.stdout.data(using: .utf8),
              let sessions = try? JSONDecoder().decode([LiveSession].self, from: data) else {
          let detail = r.stderr.isEmpty ? r.stdout : r.stderr
          completion(.failure(.failed("chi sessions list failed (exit \(r.status)): \(detail.prefix(400))")))
          return
        }
        completion(.success(sessions.filter(\.valid)))
      }
    }
  }
}
