// Runs chi the way `chi desktop install` wrote down in launch.json: an
// absolute ruby + bin/chi and a few env vars, since an app started by
// launchd has none of the shell's setup. Talks to chi only through its CLI.
import Foundation

struct LaunchConfig: Decodable {
  let version: String?
  let argv: [String]
  let env: [String: String]?
}

struct ChiResult {
  let status: Int32
  let stdout: String
  let stderr: String
  let timedOut: Bool
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

/// One live session from `chi sessions list --live --format json`.
struct LiveSession: Decodable, Identifiable, Equatable {
  let id: String
  let desc: String?
  let cwd: String?
  let busy: Bool?

  /// Only UUID-shaped ids go into chi's argv, so nothing can turn into a flag.
  var valid: Bool { UUID(uuidString: id) != nil }

  var shortCwd: String {
    guard let cwd else { return "" }
    let home = NSHomeDirectory()
    return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
  }
}

final class ChiRunner {
  static let supportDir = NSString(string: "~/Library/Application Support/Chi Helper").expandingTildeInPath
  static let launchPath = supportDir + "/launch.json"

  let timeout: TimeInterval

  init(timeout: TimeInterval = 10) {
    self.timeout = timeout
  }

  func loadLaunch() throws -> LaunchConfig {
    guard let data = FileManager.default.contents(atPath: Self.launchPath) else {
      throw ChiError.noLaunchFile(Self.launchPath)
    }
    let config: LaunchConfig
    do { config = try JSONDecoder().decode(LaunchConfig.self, from: data) } catch {
      throw ChiError.failed("Unreadable launch file \(Self.launchPath): \(error.localizedDescription)")
    }
    guard !config.argv.isEmpty else { throw ChiError.failed("Empty argv in \(Self.launchPath)") }
    for path in config.argv where path.hasPrefix("/") && !FileManager.default.fileExists(atPath: path) {
      throw ChiError.missing(path)
    }
    return config
  }

  /// Runs `chi <args>`, with stdin written from a background queue and
  /// stdout/stderr drained as they come (no pipe deadlock near the 16 KiB
  /// note cap). Calls back on the main queue.
  func run(_ args: [String], stdin: Data? = nil, completion: @escaping (Result<ChiResult, ChiError>) -> Void) {
    let config: LaunchConfig
    do { config = try loadLaunch() } catch let error as ChiError {
      completion(.failure(error)); return
    } catch {
      completion(.failure(.failed("\(error)"))); return
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: config.argv[0])
    process.arguments = Array(config.argv.dropFirst()) + args
    process.environment = ProcessInfo.processInfo.environment.merging(config.env ?? [:]) { _, baked in baked }
    process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
    let out = Pipe(), err = Pipe(), input = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = stdin == nil ? FileHandle.nullDevice : input

    let lock = NSLock()
    var outData = Data(), errData = Data()
    out.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      lock.lock(); outData.append(chunk); lock.unlock()
    }
    err.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      lock.lock(); errData.append(chunk); lock.unlock()
    }

    var timedOut = false
    process.terminationHandler = { proc in
      out.fileHandleForReading.readabilityHandler = nil
      err.fileHandleForReading.readabilityHandler = nil
      let restOut = out.fileHandleForReading.readDataToEndOfFile()
      let restErr = err.fileHandleForReading.readDataToEndOfFile()
      lock.lock()
      outData.append(restOut); errData.append(restErr)
      let result = ChiResult(status: proc.terminationStatus,
                             stdout: String(decoding: outData, as: UTF8.self),
                             stderr: String(decoding: errData, as: UTF8.self),
                             timedOut: timedOut)
      lock.unlock()
      DispatchQueue.main.async { completion(.success(result)) }
    }

    do { try process.run() } catch {
      completion(.failure(.failed("Could not start \(config.argv[0]): \(error.localizedDescription)")))
      return
    }
    if let stdin {
      DispatchQueue.global().async {
        try? input.fileHandleForWriting.write(contentsOf: stdin)
        try? input.fileHandleForWriting.close()
      }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
      if process.isRunning {
        lock.lock(); timedOut = true; lock.unlock()
        process.terminate()
      }
    }
  }

  func liveSessions(completion: @escaping (Result<[LiveSession], ChiError>) -> Void) {
    run(["sessions", "list", "--live", "--format", "json"]) { result in
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
