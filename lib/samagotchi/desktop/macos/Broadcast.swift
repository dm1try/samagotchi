// The note interface's "Everyone it concerns" row: ⌘⏎ runs `chi broadcast`
// with the note on stdin instead of `chi note` for picked sessions; chi
// finds the sessions it concerns (tags, then a triage model). The panel
// shows "broadcasting…", then the summary line, and stays open; `chi
// broadcast log` has the details. `ChiHelper --broadcast` is the build
// spec's seam.
import Foundation

enum Broadcast {
  /// broadcast.triage_deadline's default (20 s) + 10 s, for a launch file
  /// written before it carried broadcast_timeout.
  static let defaultTimeout: TimeInterval = 30

  /// The launch file's broadcast_timeout (Desktop::MacOS.broadcast_timeout:
  /// the triage deadline, then the deliveries and chi's start), not
  /// ChiRunner's 10 s.
  static func timeout(_ launch: LaunchConfig?) -> TimeInterval {
    guard let seconds = launch?.broadcastTimeout, seconds > 0 else { return defaultTimeout }
    return seconds
  }

  struct Outcome {
    let ok: Bool
    let message: String
  }

  /// What the panel says once chi broadcast ended: the broadcast's id and
  /// its summary line ("b-7f3a1c9e: delivered 4 · skipped 2"); on a failure,
  /// the summary, the failed recipients' lines and stderr (a refusal is
  /// stderr alone).
  static func outcome(_ result: Result<ChiResult, ChiError>, timeout: TimeInterval) -> Outcome {
    let r: ChiResult
    switch result {
    case .failure(let error): return Outcome(ok: false, message: error.description)
    case .success(let done): r = done
    }
    if r.timedOut {
      return Outcome(ok: false, message: "chi broadcast took over \(Int(timeout)) s and was stopped; "
                                       + "the note may be partly delivered (chi broadcast log)")
    }
    let lines = r.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    // "broadcast b-7f3a1c9e  "…"": the first line names it.
    let id = lines.first.flatMap { line -> String? in
      let words = line.split(separator: " ")
      return words.count >= 2 && words[0] == "broadcast" && words[1].hasPrefix("b-") ? String(words[1]) : nil
    }
    let summary = lines.last { $0.hasPrefix("delivered ") }.map { line in id.map { "\($0): \(line)" } ?? line }
    if r.status == 0 {
      return Outcome(ok: true, message: [summary ?? "Broadcast.", "details: chi broadcast log"].joined(separator: "\n"))
    }
    let failed = lines.filter { $0.split(separator: " ").dropFirst().first == "failed" }
    let err = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = ([summary].compactMap { $0 } + failed + [err]).filter { !$0.isEmpty }
    return Outcome(ok: false, message: parts.isEmpty ? "chi broadcast failed (exit \(r.status))" : parts.joined(separator: "\n"))
  }
}

extension ChiRunner {
  /// `chi broadcast` with +note+ on stdin, under Broadcast.timeout.
  /// Calls back on +queue+ with the outcome and the timeout it had.
  func broadcast(_ note: String, queue: DispatchQueue = .main,
                 completion: @escaping (Broadcast.Outcome, TimeInterval) -> Void) {
    let timeout = Broadcast.timeout(try? loadLaunch())
    run(["broadcast"], stdin: Data(note.utf8), timeout: timeout, queue: queue) { result in
      completion(Broadcast.outcome(result, timeout: timeout), timeout)
    }
  }
}

/// `ChiHelper --broadcast [--launch PATH]`: the note on stdin, the outcome
/// as JSON on stdout ({"ok", "message", "timeout"}); exit 1 when not ok.
func broadcastCommand(_ args: [String]) -> Int32 {
  var args = args
  var launchPath = ChiRunner.launchPath
  while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--launch" where !args.isEmpty: launchPath = args.removeFirst()
    default:
      FileHandle.standardError.write("usage: ChiHelper --broadcast [--launch PATH]\n".data(using: .utf8)!)
      return 2
    }
  }
  let note = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
  let queue = DispatchQueue(label: "broadcast-command")
  let done = DispatchSemaphore(value: 0)
  var status: Int32 = 0
  ChiRunner(launchPath: launchPath).broadcast(note, queue: queue) { outcome, timeout in
    let out: [String: Any] = ["ok": outcome.ok, "message": outcome.message, "timeout": Int(timeout)]
    let data = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    status = outcome.ok ? 0 : 1
    done.signal()
  }
  done.wait()
  return status
}
