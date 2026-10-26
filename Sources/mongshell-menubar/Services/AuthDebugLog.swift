import Foundation

/// Append-only diagnostic log for the OAuth token path (`Config.authDebugLogURL`).
///
/// Exists so that the next time the login lapses, "how long after sign-in" and
/// "when did the last refresh succeed" can be read off the file instead of
/// reconstructed from network captures. Never write a token or auth code here.
enum AuthDebugLog {
    static func write(_ message: String) {
        let line = "\(iso(Date())) \(message)\n"
        let url = Config.authDebugLogURL
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size <= Config.authDebugLogMaxBytes, let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// `signed_in=<ISO> age=<N>d<H>h` for a token, or `signed_in=unknown` for
    /// one saved before sign-in time was recorded.
    static func session(_ token: OAuthToken, now: Date = Date()) -> String {
        guard let signedInAt = token.signedInAt else { return "signed_in=unknown" }
        return "signed_in=\(iso(signedInAt)) age=\(age(from: signedInAt, to: now))"
    }

    /// Local time with offset, to the second — e.g. `2026-10-06T20:05:00+09:00`.
    static func iso(_ date: Date?) -> String {
        guard let date else { return "none" }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// `3d14h` — whole days and the remaining whole hours.
    static func age(from start: Date, to end: Date) -> String {
        let hours = max(0, Int(end.timeIntervalSince(start)) / 3600)
        return "\(hours / 24)d\(hours % 24)h"
    }

    // MARK: usage response — limits the app has no rule for

    /// One line naming what the usage response carried that the app has no
    /// rule for — or a window it had to read from the flat object because
    /// its `limits` row went missing — or nil when there is nothing to report. Percentages and
    /// reset times only — never tokens or amounts.
    static func usageUnknownLine(_ snap: UsageSnapshot) -> String? {
        var parts: [String] = []
        if !snap.extraLimits.isEmpty {
            let limits = snap.extraLimits.map { limit in
                "kind=\(limit.kind) percent=\(limit.percent) resets_at=\(iso(limit.resetAt))"
                + " is_active=\(limit.isActive.map { "\($0)" } ?? "-") scope=\(limit.scopeModel ?? "-")"
            }
            parts.append("usage unknown limits " + limits.joined(separator: ", "))
        }
        if !snap.unknownTopLevel.isEmpty {
            let buckets = snap.unknownTopLevel.map { bucket in
                "\(bucket.key) utilization=\(bucket.utilization.map { "\($0)" } ?? "-")"
                + " resets_at=\(iso(bucket.resetAt))"
            }
            parts.append("top-level " + buckets.joined(separator: ", "))
        }
        if !snap.flatFallbacks.isEmpty {
            parts.append("limits row missing, read flat " + snap.flatFallbacks.joined(separator: ", "))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " | ")
    }

    /// What `usageUnknownLine` is deduplicated on: the *set* of unknown
    /// things (kind, scope, is_active, reset time; bucket key), not their
    /// moving numbers — a percentage ticking up must not write a line per
    /// poll. nil when there is nothing unknown.
    static func usageUnknownKey(_ snap: UsageSnapshot) -> String? {
        guard !snap.extraLimits.isEmpty || !snap.unknownTopLevel.isEmpty
              || !snap.flatFallbacks.isEmpty else { return nil }
        let limits = snap.extraLimits.map { limit in
            "\(limit.kind)/\(limit.scopeModel ?? "-")/\(limit.isActive.map { "\($0)" } ?? "-")/\(iso(limit.resetAt))"
        }
        let buckets = snap.unknownTopLevel.map(\.key)
        return "limits=\(limits.joined(separator: ",")) top=\(buckets.joined(separator: ","))"
            + " flat=\(snap.flatFallbacks.joined(separator: ","))"
    }
}
