import Foundation

struct ShellResult {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut = false
    var cancelled = false
    var ok: Bool { status == 0 && !timedOut && !cancelled }
    /// stdout + stderr with progress-bar redraws (\r) collapsed to their final state.
    var combined: String { Self.collapse([stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")) }

    static func collapse(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "\r").last.map(String.init) ?? "" }
            .joined(separator: "\n")
    }
}

enum Shell {
    private final class CancelState: @unchecked Sendable {
        let lock = NSLock()
        var pid: pid_t?
        var cancelled = false

        func attach(_ pid: pid_t) -> Bool {
            lock.lock()
            let wasCancelled = cancelled
            self.pid = pid
            lock.unlock()
            return wasCancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let pid = self.pid
            lock.unlock()
            if let pid { Shell.killTree(pid) }
        }

        var isCancelled: Bool { lock.withLock { cancelled } }
    }

    /// Runs a process, optionally feeding `input` on stdin. `onOutput` gets stdout and stderr as they arrive.
    /// After `timeout` seconds (or if the enclosing Swift Task is cancelled), the process and everything it started are stopped.
    static func run(_ launchPath: String, _ args: [String], input: String? = nil, timeout: TimeInterval = 60,
                    onOutput: (@Sendable (String) -> Void)? = nil) async -> ShellResult {
        if Task.isCancelled { return ShellResult(status: -1, stdout: "", stderr: "Cancelled", cancelled: true) }
        let cancelState = CancelState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                DispatchQueue.global().async {
                    cont.resume(returning: runSync(launchPath, args, input: input, timeout: timeout, cancelState: cancelState, onOutput: onOutput))
                }
            }
        } onCancel: {
            cancelState.cancel()
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
                                cancelState: CancelState, onOutput: (@Sendable (String) -> Void)?) -> ShellResult {
        if cancelState.isCancelled { return ShellResult(status: -1, stdout: "", stderr: "Cancelled", cancelled: true) }
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
        if cancelState.attach(p.processIdentifier) {
            killTree(p.processIdentifier)
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
        let c = cancelState.isCancelled
        return ShellResult(status: p.terminationStatus, stdout: String(decoding: o, as: UTF8.self),
                           stderr: String(decoding: e, as: UTF8.self), timedOut: t, cancelled: c)
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
