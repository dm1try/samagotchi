// Runs one outside program without a shell: stdin written from a
// background queue, stdout/stderr drained as they come (no pipe deadlock on
// big input or output), a time limit. ChiRunner and KittyRunner use it.
import Foundation

struct ChiResult {
  let status: Int32
  let stdout: String
  let stderr: String
  let timedOut: Bool
}

enum ProcessRunner {
  /// Calls back on +queue+ (the main queue by default; a headless seam
  /// waits on another one).
  /// @param env the whole environment the program gets
  static func run(executable: String, args: [String], env: [String: String], stdin: Data? = nil,
                  timeout: TimeInterval, queue: DispatchQueue = .main,
                  completion: @escaping (Result<ChiResult, ChiError>) -> Void) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    process.environment = env
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
      queue.async { completion(.success(result)) }
    }

    do { try process.run() } catch {
      completion(.failure(.failed("Could not start \(executable): \(error.localizedDescription)")))
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
}
