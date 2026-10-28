import Foundation

/// Connects the runner straight to a simulated board, with no serial port in between (used by unit tests).
/// Replies become readable after the board's processing delay, as they would on a real link.
public final class InMemoryTransport: Transport {
    private let board: SimulatedIMUBoard
    private var queue: [(line: String, readyAt: Double)] = []

    public init(board: SimulatedIMUBoard) {
        self.board = board
    }

    public func writeLine(_ line: String) throws {
        let reply = board.handle(line)
        let readyAt = monotonicMs() + Double(reply.delayMs)
        for out in reply.lines {
            queue.append((line: out.trimmingCharacters(in: .newlines), readyAt: readyAt))
        }
    }

    public func readLine(timeoutMs: Int) throws -> String? {
        let deadline = monotonicMs() + Double(timeoutMs)
        while true {
            let now = monotonicMs()
            if let first = queue.first, first.readyAt <= now {
                queue.removeFirst()
                return first.line
            }
            if now >= deadline { return nil }
            let wakeAt = Swift.min(deadline, queue.first?.readyAt ?? deadline)
            Thread.sleep(forTimeInterval: Swift.max(0.0002, (wakeAt - now) / 1000.0))
        }
    }

    public func drainInput() {
        let now = monotonicMs()
        queue.removeAll { $0.readyAt <= now }
    }
}

/// Writes one JSON report per unit and appends a row to a CSV summary, like a factory test log.
public final class ReportWriter {
    public let directory: URL
    private let lock = NSLock()
    private var reportCount = 0
    private var csvURL: URL { return directory.appendingPathComponent("summary.csv") }

    public init(directory: String) throws {
        self.directory = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: csvURL.path) {
            let header = "serial,product,station,result,first_failure,duration_ms,queries,retries,crc_errors,timeouts,stale_replies\n"
            try header.write(to: csvURL, atomically: true, encoding: .utf8)
        }
    }

    /// Returns the path of the JSON report it wrote.
    @discardableResult
    public func write(_ unit: UnitResult) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(unit)
        // Every report gets its own running number: a board that never answers has no serial number
        // ("unknown"), and two of those finishing in the same second must not overwrite each other.
        lock.lock()
        reportCount += 1
        let number = reportCount
        lock.unlock()
        let safeSerial = unit.serial.replacingOccurrences(of: "/", with: "_")
        let stamp = unit.startedAt.replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent(
            "\(String(number).leftPad(5).replacingOccurrences(of: " ", with: "0"))_\(safeSerial)_\(unit.station)_\(stamp).json")
        try data.write(to: url)
        let row = [unit.serial, unit.product, unit.station, unit.passed ? "PASS" : "FAIL", unit.firstFailure ?? "",
                   fixed(unit.durationMs, 1), String(unit.queries), String(unit.retries), String(unit.crcErrors),
                   String(unit.timeouts), String(unit.staleReplies)].joined(separator: ",") + "\n"
        lock.lock()
        defer { lock.unlock() }
        let handle = try FileHandle(forWritingTo: csvURL)
        defer { handle.closeFile() }
        handle.seekToEndOfFile()
        handle.write(Data(row.utf8))
        return url
    }
}

/// Human-readable step table for the terminal.
public func formatUnit(_ unit: UnitResult) -> String {
    func pad(_ s: String, _ n: Int) -> String {
        return s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }
    var lines: [String] = []
    lines.append("\(unit.product)  serial \(unit.serial)  station \(unit.station)")
    lines.append(pad("step", 18) + pad("result", 8) + pad("measured", 28) + pad("limits", 26) + "time")
    for s in unit.steps {
        lines.append(pad(s.name, 18) + pad(s.passed ? "PASS" : "FAIL", 8) + pad(s.measured, 28)
                     + pad(s.limits, 26) + fixed(s.durationMs, 0) + " ms" + (s.passed ? "" : "   <- " + s.message))
    }
    let verdict = unit.passed ? "PASS" : "FAIL at \(unit.firstFailure ?? "?")"
    lines.append("RESULT: \(verdict)  (\(fixed(unit.durationMs, 0)) ms, \(unit.queries) queries, \(unit.retries) retries, "
                 + "\(unit.crcErrors) CRC errors, \(unit.timeouts) timeouts, \(unit.staleReplies) stale replies)")
    return lines.joined(separator: "\n")
}
