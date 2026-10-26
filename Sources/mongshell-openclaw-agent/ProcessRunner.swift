import Foundation

/// Runs a command with a hard time limit and cleans up after it — the one
/// way the agent starts another process (the openclaw probe, `launchctl
/// kickstart`, `launchctl print`). Moved out of `Probe` once it had three
/// callers: changing how a process is run and changing how openclaw's output
/// is judged are different reasons to touch a file (#105).
enum ProcessRunner {
    /// How the child ended, as far as the runner could tell.
    enum Termination: Equatable {
        case exited(status: Int32)
        case signaled(Int32)
        /// `pipe()` or `posix_spawn` failed with this errno; nothing ran.
        case launchFailed(errno: Int32)
        /// No status to report: the child was still running at the read
        /// deadline, or it had already been reaped elsewhere (ECHILD).
        case unknown
    }

    struct RunResult {
        let stdout: String
        let termination: Termination
        let timedOut: Bool
    }

    /// SIGTERM → SIGKILL grace on timeout.
    static let killGrace: TimeInterval = 1
    /// How long output may keep arriving after the direct child exits (or,
    /// if it never does, after the SIGKILL). Past it, the read is abandoned
    /// even if something still holds the pipe open.
    static let readGrace: TimeInterval = 1
    /// Output kept per run. Real probe output is a few hundred bytes and the
    /// verdict needs only that much; past the cap the pipe is still drained
    /// (read and dropped) so a full pipe never blocks the child.
    static let maxOutputBytes = 64 * 1024
    /// How often the runner wakes to check for exit and the deadlines.
    private static let tick: TimeInterval = 0.01
    private static let readChunkSize = 4096

    /// Runs `path args…` with stdout+stderr merged into one pipe and stdin on
    /// /dev/null. Returns within about `timeout + killGrace + readGrace`
    /// seconds whatever the child and its descendants do.
    ///
    /// - The child leads a new process group, so on timeout the whole group is
    ///   SIGTERM'd, then SIGKILL'd after `killGrace` — openclaw re-executes
    ///   itself with inherited stdio, and the real worker is a grandchild that
    ///   a kill of the direct child alone leaves running (and holding the pipe).
    /// - Once the direct child has exited, whatever is left of its group is
    ///   SIGKILL'd, so stragglers neither hold up the read nor pile up across
    ///   runs.
    /// - Output is read without blocking, until `readGrace` after the direct
    ///   child exits or the overall deadline, whichever is first: a descendant
    ///   that left the group (setsid) and still holds the pipe can only cost
    ///   that much, not stop the agent.
    ///
    /// Every fd opened here is closed on every path — the agent runs for
    /// weeks, and one fd leaked per probe once hit the fd limit, after which
    /// every probe read empty output.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> RunResult {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else {
            return RunResult(stdout: "", termination: .launchFailed(errno: errno), timedOut: false)
        }
        let (readFD, writeFD) = (fds[0], fds[1])
        defer { close(readFD) }

        var pid: pid_t = 0
        let spawnError = spawnInNewGroup(path, args, output: writeFD, pid: &pid)
        // The child holds its own copy; ours must go or EOF never arrives.
        close(writeFD)
        guard spawnError == 0 else {
            return RunResult(stdout: "", termination: .launchFailed(errno: spawnError), timedOut: false)
        }

        _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)

        let start = ProcessInfo.processInfo.systemUptime
        let termAt = start + timeout
        let killAt = termAt + killGrace
        let giveUpAt = killAt + readGrace

        var output = Data()
        var reachedEOF = false
        var exited = false
        var reapable = false
        var readUntil = giveUpAt
        var timedOut = false
        var killSent = false
        while true {
            if !reachedEOF { reachedEOF = readAvailable(readFD, into: &output) }
            let now = ProcessInfo.processInfo.systemUptime
            if !exited {
                switch childState(pid) {
                case .running:
                    break
                case .exited:
                    exited = true
                    reapable = true
                    // Stragglers left in the group could hold the pipe and
                    // stall EOF; the child's own output is complete by now.
                    killGroup(of: pid)
                    readUntil = min(giveUpAt, now + readGrace)
                case .reapedElsewhere:
                    // Its pid — and so its group id — may already be reused,
                    // so the group is left alone.
                    exited = true
                    readUntil = min(giveUpAt, now + readGrace)
                }
            }
            if exited && reachedEOF { break }

            if now >= readUntil { break }
            if !exited && now >= termAt && !timedOut {
                timedOut = true
                kill(-pid, SIGTERM)
            }
            if !exited && now >= killAt && !killSent {
                killSent = true
                killGroup(of: pid)
            }

            if reachedEOF {
                Thread.sleep(forTimeInterval: tick)
            } else {
                var pfd = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
                _ = poll(&pfd, 1, Int32(tick * 1000))
            }
        }

        // `.unknown` covers every case without a status to read: reaped
        // elsewhere (ECHILD), a failed reap, or not exited even after the
        // SIGKILL (stuck in the kernel) — that last one is left unreaped rather
        // than risk a blocking wait, and stays a zombie until the agent process
        // itself is restarted. `parseProbe` then can't credit a clean exit, so a
        // channel-less "Gateway reachable." reads as down; ECHILD only happens
        // if something else reaps our children, which nothing here does.
        let termination = reapable ? reap(pid) : .unknown
        return RunResult(stdout: String(decoding: output, as: UTF8.self),
                         termination: termination, timedOut: timedOut)
    }

    /// posix_spawn with the child as leader of a new process group, stdin on
    /// /dev/null, stdout+stderr on `output`, and no other fd inherited. Signal
    /// dispositions and mask are reset to defaults, as `Process` does. Returns
    /// posix_spawn's result — 0, or the errno it failed with — and sets `pid`
    /// on success.
    private static func spawnInNewGroup(_ path: String, _ args: [String], output: Int32,
                                        pid: inout pid_t) -> Int32 {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attr, Int16(flags))
        posix_spawnattr_setpgroup(&attr, 0) // 0: a new group whose id is the child's pid
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output, STDERR_FILENO)

        // Give the child a real PATH so anything openclaw shells out to resolves.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let argv = ([path] + args).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        return posix_spawn(&pid, path, &actions, &attr, argv, envp)
    }

    /// Appends whatever the pipe has right now, up to `maxOutputBytes` in
    /// total; the rest is read and dropped. Returns true once the pipe is at
    /// EOF (or unreadable) — nothing more will come.
    private static func readAvailable(_ fd: Int32, into output: inout Data) -> Bool {
        var chunk = [UInt8](repeating: 0, count: readChunkSize)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                let room = maxOutputBytes - output.count
                if room > 0 { output.append(chunk, count: min(n, room)) }
                continue
            }
            if n == 0 { return true }
            if errno == EINTR { continue }
            return errno != EAGAIN
        }
    }

    private enum ChildState { case running, exited, reapedElsewhere }

    /// Checks `pid` without reaping it: an unreaped child keeps its pid — and
    /// so its process group id — from being reused, which is what makes
    /// `killGroup` safe to call after the exit.
    private static func childState(_ pid: pid_t) -> ChildState {
        var info = siginfo_t()
        if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 {
            return info.si_pid == pid ? .exited : .running
        }
        // ECHILD: no such child any more — it exited and something else
        // reaped it (e.g. SIGCHLD set to ignore). Waiting on would only end
        // in a false timeout.
        return errno == ECHILD ? .reapedElsewhere : .running
    }

    /// Best-effort: SIGKILLs every process still in the group `pid` leads.
    private static func killGroup(of pid: pid_t) {
        kill(-pid, SIGKILL)
    }

    /// Reaps the exited child.
    private static func reap(_ pid: pid_t) -> Termination {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno != EINTR { return .unknown }
        }
        let signal = status & 0x7f
        return signal == 0 ? .exited(status: (status >> 8) & 0xff) : .signaled(signal)
    }
}
