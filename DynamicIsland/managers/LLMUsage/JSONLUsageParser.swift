import Foundation
import os

struct UsageRecord: Sendable {
    let timestamp: Date
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let dedupKey: String?
}

struct JSONLUsageParser {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseDate(_ s: String) -> Date? {
        if let d = iso.date(from: s) { return d }
        return isoPlain.date(from: s)
    }

    /// Raw bytes of the only key that can yield a record. Lines without it are
    /// skipped before JSONSerialization ever builds a dictionary tree for them —
    /// most transcript lines are user turns or tool results with no usage block,
    /// and their `content` fields are the bulk of the file.
    private static let usageNeedle = Array("\"usage\"".utf8)

    private static func containsUsage(_ data: Data) -> Bool {
        guard data.count >= usageNeedle.count else { return false }
        return data.withUnsafeBytes { haystack -> Bool in
            guard let base = haystack.baseAddress else { return false }
            return usageNeedle.withUnsafeBufferPointer { needle in
                memmem(base, haystack.count, needle.baseAddress!, needle.count) != nil
            }
        }
    }

    static func parseLine(_ data: Data) -> UsageRecord? {
        guard containsUsage(data),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let message = obj["message"] as? [String: Any]
        let usage = (message?["usage"] as? [String: Any]) ?? (obj["usage"] as? [String: Any])
        guard let usage else { return nil }
        let input = (usage["input_tokens"] as? Int ?? 0)
            + (usage["cache_creation_input_tokens"] as? Int ?? 0)
            + (usage["cache_read_input_tokens"] as? Int ?? 0)
        let output = usage["output_tokens"] as? Int ?? 0
        guard input + output > 0 else { return nil }
        let model = (message?["model"] as? String) ?? (obj["model"] as? String) ?? "unknown"
        let tsString = (obj["timestamp"] as? String) ?? (message?["timestamp"] as? String) ?? ""
        guard let ts = parseDate(tsString) else { return nil }
        let messageId = message?["id"] as? String
        let requestId = (obj["requestId"] as? String) ?? (obj["request_id"] as? String)
        let dedupKey = (messageId != nil || requestId != nil) ? "\(messageId ?? "")-\(requestId ?? "")" : nil
        return UsageRecord(timestamp: ts, model: model, inputTokens: input, outputTokens: output, dedupKey: dedupKey)
    }

    static func aggregate(files: [URL], now: Date) -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        var perModel: [String: UsageTotals] = [:]
        var seen = Set<String>()
        let cal = Calendar.current
        let sessionStart = now.addingTimeInterval(-5 * 3600)
        let weekStart = now.addingTimeInterval(-7 * 86400)

        // A JSONL transcript is append-only, so a file whose last write predates the
        // aggregation window cannot hold a record inside it. Without this the parser
        // walked every transcript ever written (~1800 files / GBs here) on every
        // refresh just to keep the last seven days, allocating a JSON object tree per
        // line and pushing the process past 6 GB.
        let mtimeCutoff = weekStart.addingTimeInterval(-3600)

        // Bucketing is identical whether a record came off disk or out of the cache,
        // so both paths funnel through here. The order inside matters: the dedup set
        // is populated *before* the window test, so an out-of-window record still
        // suppresses a later copy of itself. Keeping that order is what makes a
        // cached sweep produce the same numbers as a cold one.
        func consume(_ rec: UsageRecord) {
            if let key = rec.dedupKey {
                if seen.contains(key) { return }
                seen.insert(key)
            }
            guard rec.timestamp >= weekStart else { return }
            let cost = ModelPricing.cost(model: rec.model, inputTokens: rec.inputTokens, outputTokens: rec.outputTokens)
            func add(_ t: inout UsageTotals) {
                t.inputTokens += rec.inputTokens
                t.outputTokens += rec.outputTokens
                if let cost { t.costUSD += cost } else { t.hasUnpricedModel = true }
            }
            add(&snapshot.week)
            if cal.isDate(rec.timestamp, inSameDayAs: now) { add(&snapshot.today) }
            if rec.timestamp >= sessionStart { add(&snapshot.session) }
            var mt = perModel[rec.model] ?? UsageTotals()
            add(&mt)
            perModel[rec.model] = mt
        }

        for file in files {
            let before = fileStamp(of: file)
            if let mtime = before.mtime, mtime < mtimeCutoff { continue }

            // Even after the mtime cutoff a refresh still re-read hundreds of MB every
            // 60 s, and an unchanged transcript yields exactly the records it yielded
            // last time. A hit here means no FileHandle, no read and no JSON parse.
            if let mtime = before.mtime, let size = before.size,
               let cached = cachedRecords(path: file.path, mtime: mtime, size: size, weekStart: weekStart, now: now) {
                for rec in cached { consume(rec) }
                continue
            }

            // Stream the file line-by-line instead of loading the whole JSONL log
            // (potentially many MB) into a String plus a full array of substrings.
            var parsed: [UsageRecord] = []
            enumerateLines(of: file) { line in
                guard let rec = parseLine(line) else { return }
                consume(rec)
                // Retain only what a later sweep can still act on. `weekStart` only
                // ever moves forward, so a record already outside the window can never
                // re-enter it and contribute tokens; it is worth keeping only when it
                // carries a dedup key, because `consume` uses that key to suppress
                // duplicates that other files may repeat.
                if rec.timestamp >= weekStart || rec.dedupKey != nil { parsed.append(rec) }
            }

            // Publish the parse only under the stamp the bytes were actually read at.
            // Claude Code appends to the live transcript continuously, so a file can
            // grow mid-read; caching the pre-read stamp would pin a truncated parse
            // until the next append happened to change the size again.
            let after = fileStamp(of: file)
            if let mtime = after.mtime, let size = after.size,
               mtime == before.mtime, size == before.size {
                storeRecords(parsed, path: file.path, mtime: mtime, size: size, prunedBefore: weekStart, now: now)
            }
        }
        evictStaleCacheEntries(now: now)

        snapshot.models = perModel
            .map { ModelUsage(model: $0.key, totals: $0.value) }
            .sorted { $0.totals.costUSD > $1.totals.costUSD }
        snapshot.lastUpdated = now
        return snapshot
    }

    /// Reads a file in fixed-size chunks and invokes `handler` once per non-empty
    /// line, without ever holding the entire file in memory. Runs synchronously on
    /// the caller's thread (aggregation already happens off the main thread).
    private static func enumerateLines(of file: URL, _ handler: (Data) -> Void) {
        guard let fh = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? fh.close() }

        let chunkSize = 1 << 18 // 256 KB
        // A plain byte array, scanned with memchr. Slicing Data and calling
        // firstIndex(of:) routed every single byte through __DataStorage's
        // _bytes/_offset accessors, which dominated the profile.
        var buffer = [UInt8]()

        while let chunk = try? fh.read(upToCount: chunkSize), !chunk.isEmpty {
            buffer.append(contentsOf: chunk)
            var consumed = 0
            buffer.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                while consumed < buf.count {
                    guard let hit = memchr(base + consumed, 0x0A, buf.count - consumed) else { break }
                    let newlineIndex = UnsafeRawPointer(hit) - UnsafeRawPointer(base)
                    if newlineIndex > consumed {
                        handler(Data(bytes: base + consumed, count: newlineIndex - consumed))
                    }
                    consumed = newlineIndex + 1
                }
            }
            if consumed > 0 { buffer.removeFirst(consumed) }
        }

        if !buffer.isEmpty { handler(Data(buffer)) }
    }

    // MARK: - Parsed-file cache

    /// The records parsed out of one file, valid only while that file still carries
    /// the mtime *and* size it had when we read it. Size is part of the stamp because
    /// `contentModificationDate` is coarse enough that a quick append can land on the
    /// same value as the previous write.
    private struct CachedParse: Sendable {
        let mtime: Date
        let size: Int
        /// Records older than this were dropped before the entry was stored, so the
        /// entry cannot answer a sweep whose window reaches further back.
        let prunedBefore: Date
        var lastUsed: Date
        let records: [UsageRecord]
    }

    /// `aggregate` is a static func reached from every provider, and
    /// `LLMUsageManager.runRefresh` fans those providers out through a
    /// `withTaskGroup` — so this dictionary is shared mutable state touched from
    /// several threads at once. The lock is only ever held across the dictionary
    /// read or write itself; the file I/O and JSON parsing that produce a value stay
    /// outside it, so one provider never blocks on another provider's disk work.
    /// Providers walk disjoint roots, so a single path-keyed map serves all of them.
    private static let cache = OSAllocatedUnfairLock(initialState: [String: CachedParse]())

    /// How long an entry survives without a sweep touching it. Nothing tells us when
    /// a project directory is deleted or when a transcript ages out of the seven-day
    /// window, so untouched means dead. Comfortably above the manager's 60 s refresh
    /// floor, and short enough that the parsed set is handed back when the usage UI
    /// is closed and nothing is refreshing.
    private static let cacheTTL: TimeInterval = 15 * 60

    /// Memory backstop. A record costs ~215 B: 56 B in the array plus heap for its
    /// model name (~18 chars) and dedup key (~57 chars), both past the 15-byte inline
    /// String limit. A heavy seven-day working set measured here — 337 files, 570 MB
    /// of transcripts — retains 31.7 k records, about 6.5 MB. This ceiling allows
    /// six times that (~41 MB); beyond it reparsing is the better trade.
    private static let cacheRecordLimit = 200_000

    /// mtime and size read through a freshly built URL. Resource values fetched from
    /// a directory enumerator's URL can be served out of `NSURL`'s per-object cache,
    /// which would hand back a stamp older than the bytes we just read and defeat the
    /// post-read verification.
    private static func fileStamp(of file: URL) -> (mtime: Date?, size: Int?) {
        let values = try? URL(fileURLWithPath: file.path)
            .resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return (values?.contentModificationDate, values?.fileSize)
    }

    private static func cachedRecords(path: String, mtime: Date, size: Int, weekStart: Date, now: Date) -> [UsageRecord]? {
        cache.withLock { entries in
            guard var entry = entries[path], entry.mtime == mtime, entry.size == size,
                  weekStart >= entry.prunedBefore else { return nil }
            entry.lastUsed = now
            entries[path] = entry
            return entry.records
        }
    }

    private static func storeRecords(_ records: [UsageRecord], path: String, mtime: Date, size: Int, prunedBefore: Date, now: Date) {
        cache.withLock { entries in
            entries[path] = CachedParse(mtime: mtime, size: size, prunedBefore: prunedBefore, lastUsed: now, records: records)
        }
    }

    private static func evictStaleCacheEntries(now: Date) {
        cache.withLock { entries in
            // `abs` so that a clock moved backwards drops entries stamped in the
            // future instead of pinning them forever; a cold reparse is the safe way
            // to lose an argument with the clock.
            entries = entries.filter { abs(now.timeIntervalSince($0.value.lastUsed)) < cacheTTL }

            var total = 0
            for entry in entries.values { total += entry.records.count }
            guard total > cacheRecordLimit else { return }
            // Oldest sweep first — those are already on their way out via the TTL —
            // then the least recently written files, whose retained records are mostly
            // out-of-window dedup ballast rather than tokens anyone is looking at.
            let victims = entries.sorted {
                $0.value.lastUsed == $1.value.lastUsed
                    ? $0.value.mtime < $1.value.mtime
                    : $0.value.lastUsed < $1.value.lastUsed
            }
            for (path, entry) in victims {
                guard total > cacheRecordLimit else { break }
                entries.removeValue(forKey: path)
                total -= entry.records.count
            }
        }
    }
}
