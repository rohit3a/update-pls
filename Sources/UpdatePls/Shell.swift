import Foundation

struct ShellResult {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut = false
    var ok: Bool { status == 0 && !timedOut }
    /// stdout + stderr with progress-bar redraws (\r) collapsed to their final state.
    var combined: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "\r").last.map(String.init) ?? "" }
            .joined(separator: "\n")
    }
}

enum Shell {
    /// Runs a process, optionally feeding `input` on stdin, and kills it after `timeout` seconds.
    static func run(_ launchPath: String, _ args: [String], input: String? = nil, timeout: TimeInterval = 60) async -> ShellResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: launchPath)
                p.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
                p.environment = env
                let out = Pipe(), err = Pipe(), inp = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = inp
                var outData = Data(), errData = Data()
                let group = DispatchGroup()
                group.enter(); group.enter()
                DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                do { try p.run() } catch {
                    cont.resume(returning: ShellResult(status: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }
                if let input { inp.fileHandleForWriting.write(Data(input.utf8)) }
                try? inp.fileHandleForWriting.close()
                var timedOut = false
                let timer = DispatchWorkItem { if p.isRunning { timedOut = true; p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                p.waitUntilExit()
                timer.cancel()
                _ = group.wait(timeout: .now() + 5)
                cont.resume(returning: ShellResult(
                    status: p.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self),
                    timedOut: timedOut))
            }
        }
    }

    /// Single-quotes a string for POSIX shells.
    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Single-quotes a string for PowerShell.
    static func psq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
}
