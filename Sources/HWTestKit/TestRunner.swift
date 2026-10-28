import Foundation

public struct StepResult: Codable, Equatable {
    public var name: String
    public var passed: Bool
    public var measured: String
    public var limits: String
    public var message: String
    public var durationMs: Double
}

public struct UnitResult: Codable {
    public var serial: String
    public var product: String
    public var station: String
    public var passed: Bool
    public var firstFailure: String?
    public var steps: [StepResult]
    public var durationMs: Double
    public var queries: Int
    public var retries: Int
    public var crcErrors: Int
    public var timeouts: Int
    public var staleReplies: Int
    public var startedAt: String
}

/// Raised when the device never gives a valid reply to a command, even after retries.
public struct CommunicationError: Error, CustomStringConvertible {
    public let command: String
    public let reason: String
    public var description: String { return "no valid reply to '\(command)' (\(reason))" }
}

/// Runs a test specification against one device and judges every step.
///
/// Every request carries a sequence number; a reply with a different number (a late answer to an earlier
/// request) is thrown away. A reply that fails its CRC, is not a valid frame, or never arrives triggers a
/// retry, up to `spec.retries` times.
public final class TestRunner {
    public let spec: TestSpec
    private let transport: Transport
    private var seq = 0
    private var queries = 0
    private var retries = 0
    private var crcErrors = 0
    private var timeouts = 0
    private var staleReplies = 0

    public init(spec: TestSpec, transport: Transport) {
        self.spec = spec
        self.transport = transport
    }

    /// Sends one command and returns the parsed reply, retrying on corruption or timeout.
    public func query(_ command: String) throws -> Response {
        queries += 1
        var lastProblem = "no reply"
        for attempt in 0...spec.retries {
            if attempt > 0 {
                retries += 1
                transport.drainInput()
            }
            seq += 1
            try transport.writeLine(Frame(seq: seq, payload: command).encoded())
            let deadline = monotonicMs() + Double(spec.timeoutMs)
            var gotAnswer = false
            while true {
                let remaining = deadline - monotonicMs()
                if remaining <= 0 { break }
                guard let line = try transport.readLine(timeoutMs: Int(remaining.rounded(.up))) else { break }
                let frame: Frame
                do {
                    frame = try Frame.decode(line)
                } catch {
                    crcErrors += 1
                    lastProblem = "\(error)"
                    gotAnswer = true
                    break
                }
                if frame.seq != seq {
                    staleReplies += 1
                    continue
                }
                if frame.payload.hasPrefix("ERR") {
                    lastProblem = "device said '\(frame.payload)'"
                    gotAnswer = true
                    break
                }
                return Response.parse(frame.payload)
            }
            if !gotAnswer {
                timeouts += 1
                lastProblem = "timeout after \(spec.timeoutMs) ms"
            }
        }
        throw CommunicationError(command: command, reason: lastProblem)
    }

    public func run(station: String = "station-1") -> UnitResult {
        let start = monotonicMs()
        let startedAt = ISO8601DateFormatter().string(from: Date())
        var serial = "unknown"
        var results: [StepResult] = []
        for step in spec.steps {
            let t0 = monotonicMs()
            var result: StepResult
            var commsFailed = false
            do {
                let (r, rows) = try evaluate(step)
                result = r
                if step.command == "ID?", let row = rows.first, row.count > 2 { serial = row[2] }
            } catch {
                commsFailed = true
                result = StepResult(name: step.name, passed: false, measured: "-", limits: limitsText(step),
                                    message: "\(error)", durationMs: 0)
            }
            result.durationMs = monotonicMs() - t0
            results.append(result)
            // No point continuing if the device stopped answering, or a gating step (such as identify) failed.
            if !result.passed && (commsFailed || step.abortOnFail == true) { break }
        }
        let failed = results.first { !$0.passed }
        return UnitResult(serial: serial, product: spec.product, station: station, passed: failed == nil,
                          firstFailure: failed?.name, steps: results, durationMs: monotonicMs() - start,
                          queries: queries, retries: retries, crcErrors: crcErrors, timeouts: timeouts,
                          staleReplies: staleReplies, startedAt: startedAt)
    }

    /// Runs one step: queries the device `samples` times and applies the check.
    func evaluate(_ step: TestStep) throws -> (StepResult, [[String]]) {
        let n = max(1, step.samples ?? 1)
        var rows: [[String]] = []
        for _ in 0..<n {
            let response = try query(step.command)
            if let key = step.key, response.key != key {
                let r = StepResult(name: step.name, passed: false, measured: response.key, limits: limitsText(step),
                                   message: "unexpected reply '\(response.key)', expected '\(key)'", durationMs: 0)
                return (r, rows)
            }
            rows.append(response.fields)
        }
        let indices = step.fields ?? [0]
        func text(_ row: [String], _ i: Int) -> String? { return i < row.count ? row[i] : nil }

        switch step.check {
        case .equals:
            let values = indices.map { text(rows[0], $0) ?? "<missing>" }
            let ok = values.allSatisfy { $0 == step.equals }
            return (StepResult(name: step.name, passed: ok, measured: values.joined(separator: ","),
                               limits: limitsText(step), message: ok ? "ok" : "value mismatch", durationMs: 0), rows)

        case .version:
            let raw = text(rows[0], indices.first ?? 0) ?? ""
            guard let have = SemanticVersion(raw), let need = SemanticVersion(step.minVersion ?? "") else {
                return (StepResult(name: step.name, passed: false, measured: raw, limits: limitsText(step),
                                   message: "unreadable version", durationMs: 0), rows)
            }
            let ok = have >= need
            return (StepResult(name: step.name, passed: ok, measured: raw, limits: limitsText(step),
                               message: ok ? "ok" : "firmware too old", durationMs: 0), rows)

        case .range, .noise:
            var measured: [String] = []
            var ok = true
            var message = "ok"
            for i in indices {
                let numbers = rows.compactMap { row -> Double? in
                    guard let t = text(row, i) else { return nil }
                    return Double(t)
                }
                guard numbers.count == rows.count else {
                    return (StepResult(name: step.name, passed: false, measured: "non-numeric", limits: limitsText(step),
                                       message: "field \(i) is not a number", durationMs: 0), rows)
                }
                let value = step.check == .range ? Stats.mean(numbers) : Stats.std(numbers)
                measured.append(fixed(value, 4))
                let lo = step.check == .range ? (step.low ?? -Double.infinity) : (step.minStd ?? 0)
                let hi = step.check == .range ? (step.high ?? Double.infinity) : (step.maxStd ?? Double.infinity)
                if !(value >= lo && value <= hi) {
                    ok = false
                    if message == "ok" {
                        message = "field \(i) = \(fixed(value, 4)) outside [\(lo), \(hi)]"
                    }
                }
            }
            return (StepResult(name: step.name, passed: ok, measured: measured.joined(separator: ","),
                               limits: limitsText(step), message: message, durationMs: 0), rows)
        }
    }

    func limitsText(_ step: TestStep) -> String {
        let unit = step.unit.map { " " + $0 } ?? ""
        switch step.check {
        case .equals: return "= \(step.equals ?? "?")"
        case .version: return ">= \(step.minVersion ?? "?")"
        case .range: return "[\(step.low ?? -Double.infinity), \(step.high ?? Double.infinity)]\(unit)"
        case .noise: return "std [\(step.minStd ?? 0), \(step.maxStd ?? Double.infinity)]\(unit)"
        }
    }
}
