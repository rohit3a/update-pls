import Foundation

struct ShellResult {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut = false
    var ok: Bool { status == 0 && !timedOut }
    /// stdout + stderr with progress-bar redraws (\r) collapsed to their final state.
    var combined: String { Self.collapse([stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")) }

    static func collapse(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "\r").last.map(String.init) ?? "" }
            .joined(separator: "\n")
    }
}

enum Shell {
    /// Runs a process, optionally feeding `input` on stdin. `onOutput` gets stdout and stderr as they arrive.
    /// After `timeout` seconds the process and everything it started are stopped.
    static func run(_ launchPath: String, _ args: [String], input: String? = nil, timeout: TimeInterval = 60,
                    onOutput: (@Sendable (String) -> Void)? = nil) async -> ShellResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                cont.resume(returning: runSync(launchPath, args, input: input, timeout: timeout, onOutput: onOutput))
            }
        }
    }

    private final class Sink: @unchecked Sendable {
        let lock = NSLock()
        var out = Data(), err = Data()
        var open = 2
        let closed = DispatchSemaphore(value: 0)
        func add(_ d: Data, err isErr: Bool) {
            lock.lock(); if isErr { err.append(d) } else { out.append(d) }; lock.unlock()
        }
        func close() {
            lock.lock(); open -= 1; let done = open == 0; lock.unlock()
            if done { closed.signal() }
        }
    }

    private static func runSync(_ launchPath: String, _ args: [String], input: String?, timeout: TimeInterval,
                                onOutput: (@Sendable (String) -> Void)?) -> ShellResult {
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
        let sink = Sink()
        for (pipe, isErr) in [(out, false), (err, true)] {
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil; sink.close(); return }
                sink.add(d, err: isErr)
                onOutput?(String(decoding: d, as: UTF8.self))
            }
        }
        do { try p.run() } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            return ShellResult(status: -1, stdout: "", stderr: "Couldn't start \(launchPath): \(error.localizedDescription)")
        }
        if let input { try? inp.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
        try? inp.fileHandleForWriting.close()
        let lock = NSLock()
        var timedOut = false
        let timer = DispatchWorkItem {
            guard p.isRunning else { return }
            lock.lock(); timedOut = true; lock.unlock()
            killTree(p.processIdentifier)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        p.waitUntilExit()
        timer.cancel()
        // Something the process started may still hold the pipes open; don't wait on it forever.
        if sink.closed.wait(timeout: .now() + 5) == .timedOut {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
        }
        sink.lock.lock(); let o = sink.out, e = sink.err; sink.lock.unlock()
        lock.lock(); let t = timedOut; lock.unlock()
        return ShellResult(status: p.terminationStatus, stdout: String(decoding: o, as: UTF8.self),
                           stderr: String(decoding: e, as: UTF8.self), timedOut: t)
    }

    /// Stops a process and all its descendants: TERM first, KILL after 3 seconds.
    static func killTree(_ root: pid_t) {
        let pids = [root] + descendants(of: root)
        for pid in pids.reversed() { kill(pid, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    static func descendants(of root: pid_t) -> [pid_t] {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid="]
        p.standardOutput = out
        guard (try? p.run()) != nil else { return [] }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        var children: [pid_t: [pid_t]] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ").compactMap { pid_t($0) }
            if f.count == 2 { children[f[1], default: []].append(f[0]) }
        }
        var found: [pid_t] = [], stack = [root]
        while let next = stack.popLast() {
            for c in children[next] ?? [] { found.append(c); stack.append(c) }
        }
        return found
    }

    /// Single-quotes a string for POSIX shells.
    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Single-quotes a string for PowerShell.
    static func psq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
}
