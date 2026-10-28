import Foundation

/// A production run on simulated boards: every unit is served on its own pseudo-terminal and tested through
/// the real serial-port code, by several test stations working in parallel.
public struct BenchConfig {
    public var units: Int = 200
    public var stations: Int = 8
    public var seed: UInt64 = 7
    public var reportDir: String = "reports/bench"
    public var processingMs: Int = 2

    public init() {}
}

public struct BenchUnit {
    public let index: Int
    public let fault: DeviceFault
    public let result: UnitResult
}

/// The fault plan: 70% good boards, 10% good boards on a noisy link, 20% defective boards spread evenly over
/// the 12 defect types. Shuffled with a fixed seed so every run tests the same units in the same order.
public func faultPlan(units: Int, seed: UInt64) -> [DeviceFault] {
    let defects = DeviceFault.allCases.filter { $0.isDefect }
    let nDefect = Int((Double(units) * 0.20).rounded())
    let nNoisy = Int((Double(units) * 0.10).rounded())
    var plan: [DeviceFault] = []
    for i in 0..<nDefect { plan.append(defects[i % defects.count]) }
    plan += Array(repeating: DeviceFault.linkNoise, count: nNoisy)
    plan += Array(repeating: DeviceFault.none, count: max(0, units - plan.count))
    var rng = SeededRNG(seed: seed)
    plan.shuffle(using: &rng)
    return plan
}

/// Work queue shared by the station threads (a class, so threads share one instance behind a lock).
final class StationQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    private let count: Int
    private(set) var finished: [BenchUnit] = []

    init(count: Int) { self.count = count }

    func take() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard next < count else { return nil }
        next += 1
        return next - 1
    }

    func add(_ unit: BenchUnit) {
        lock.lock()
        finished.append(unit)
        lock.unlock()
    }
}

/// Tests the given units on `stations` parallel stations (one thread each, pulling from a shared queue).
public func runStations(spec: TestSpec, plan: [DeviceFault], stations: Int, seed: UInt64, processingMs: Int,
                        writer: ReportWriter?, firstIndex: Int = 0) -> (units: [BenchUnit], wallSeconds: Double) {
    let queue = StationQueue(count: plan.count)
    let group = DispatchGroup()
    let start = monotonicMs()
    for s in 0..<max(1, stations) {
        group.enter()
        let thread = Thread {
            while let i = queue.take() {
                let unit = testOneUnit(spec: spec, fault: plan[i], number: firstIndex + i, station: "station-\(s + 1)",
                                       seed: seed, processingMs: processingMs)
                if let writer = writer { _ = try? writer.write(unit.result) }
                queue.add(unit)
            }
            group.leave()
        }
        thread.start()
    }
    group.wait()
    let wall = (monotonicMs() - start) / 1000.0
    return (queue.finished.sorted { $0.index < $1.index }, wall)
}

/// One simulated board on its own pseudo-terminal, tested through the serial-port code.
func testOneUnit(spec: TestSpec, fault: DeviceFault, number: Int, station: String, seed: UInt64,
                 processingMs: Int) -> BenchUnit {
    let serial = "SN" + String(String(100_000 + number + 1).dropFirst())
    let board = SimulatedIMUBoard(fault: fault, serial: serial, seed: seed &+ UInt64(number) &* 7919,
                                  processingMs: processingMs)
    var result: UnitResult
    do {
        let server = try PTYDeviceServer(board: board)
        let port = try SerialPort(path: server.path)
        result = TestRunner(spec: spec, transport: port).run(station: station)
        port.closePort()
        server.stop()
    } catch {
        result = UnitResult(serial: serial, product: spec.product, station: station, passed: false,
                            firstFailure: "setup: \(error)", steps: [], durationMs: 0, queries: 0, retries: 0,
                            crcErrors: 0, timeouts: 0, staleReplies: 0,
                            startedAt: ISO8601DateFormatter().string(from: Date()))
    }
    return BenchUnit(index: number, fault: fault, result: result)
}

public struct Requirement {
    public let id: String
    public let text: String
    public let result: String
    public let target: String
    public let pass: Bool
}

/// Runs the whole benchmark, prints the results and the requirement table. Returns true if all requirements pass.
public func runBench(spec: TestSpec, config: BenchConfig, log: (String) -> Void) throws -> Bool {
    let problems = spec.problems()
    let plan = faultPlan(units: config.units, seed: config.seed)
    let writer = try ReportWriter(directory: config.reportDir)

    log("[1  Production run: \(config.units) simulated \(spec.product) boards, \(config.stations) parallel stations]")
    log("  every board is served on its own pseudo-terminal and tested through the real serial-port code")
    let (units, wall) = runStations(spec: spec, plan: plan, stations: config.stations, seed: config.seed,
                                    processingMs: config.processingMs, writer: writer)

    let good = units.filter { !$0.fault.isDefect }
    let bad = units.filter { $0.fault.isDefect }
    let falseFails = good.filter { !$0.result.passed }
    let escapes = bad.filter { $0.result.passed }
    let caught = bad.filter { !$0.result.passed }
    let rightStep = caught.filter { $0.result.firstFailure == $0.fault.expectedFailingStep }
    let noisy = units.filter { $0.fault == .linkNoise }
    let noisyPassed = noisy.filter { $0.result.passed }
    let totalCRC = units.reduce(0) { $0 + $1.result.crcErrors }
    let totalRetries = units.reduce(0) { $0 + $1.result.retries }
    let totalStale = units.reduce(0) { $0 + $1.result.staleReplies }
    let yieldPct = 100.0 * Double(units.filter { $0.result.passed }.count) / Double(max(1, units.count))

    log("  units tested \(units.count): good \(good.count) (of which \(noisy.count) on a noisy link), defective \(bad.count)")
    log("  yield \(fixed(yieldPct, 1)) %, false failures \(falseFails.count), escapes \(escapes.count)")
    log("  link: \(totalCRC) CRC errors and \(totalRetries) retries, \(totalStale) stale replies rejected")
    log("  wall time \(fixed(wall, 1)) s = \(fixed(Double(units.count) / wall * 3600, 0)) units per hour")

    log("")
    log("[2  Defects: was each one caught at the right step?]")
    log("  fault             units caught  first failing step (expected)")
    let defectTypes = DeviceFault.allCases.filter { $0.isDefect }
    for f in defectTypes {
        let us = bad.filter { $0.fault == f }
        if us.isEmpty { continue }
        let c = us.filter { !$0.result.passed }.count
        let steps = Set(us.compactMap { $0.result.firstFailure }).sorted().joined(separator: "/")
        let name = f.rawValue.padding(toLength: 17, withPad: " ", startingAt: 0)
        log("  \(name) " + String(us.count).leftPad(5) + " " + String(c).leftPad(6) + "  \(steps) (\(f.expectedFailingStep ?? "-"))")
    }

    log("")
    log("[3  Unresponsive boards: time to a verdict]")
    let budgetMs = Double(spec.timeoutMs * (spec.retries + 1)) + 500
    let unresponsive = units.filter { $0.fault == .silent || $0.fault == .slowResponse }
    let slowest = unresponsive.map { $0.result.durationMs }.max() ?? 0
    log("  \(unresponsive.count) silent or slow boards; slowest verdict \(fixed(slowest, 0)) ms "
        + "(budget \(fixed(budgetMs, 0)) ms = \(spec.timeoutMs) ms x \(spec.retries + 1) attempts + 0.5 s)")

    log("")
    log("[4  Station scaling: the same first 48 units on 1 station vs. \(config.stations) stations]")
    let subset = Array(plan.prefix(48))
    let one = runStations(spec: spec, plan: subset, stations: 1, seed: config.seed, processingMs: config.processingMs,
                          writer: nil)
    let many = runStations(spec: spec, plan: subset, stations: config.stations, seed: config.seed,
                           processingMs: config.processingMs, writer: nil)
    let speedup = one.wallSeconds / max(0.001, many.wallSeconds)
    let sameVerdicts = zip(one.units, many.units).allSatisfy { $0.result.passed == $1.result.passed }
    log("  1 station \(fixed(one.wallSeconds, 2)) s, \(config.stations) stations \(fixed(many.wallSeconds, 2)) s: "
        + "\(fixed(speedup, 1))x faster; identical verdicts: \(sameVerdicts ? "yes" : "no")")

    let reports = (try? FileManager.default.contentsOfDirectory(atPath: config.reportDir))?
        .filter { $0.hasSuffix(".json") }.count ?? 0
    let csvRows = ((try? String(contentsOfFile: config.reportDir + "/summary.csv", encoding: .utf8)) ?? "")
        .split(separator: "\n").count - 1

    let reqs: [Requirement] = [
        Requirement(id: "R1", text: "Defective boards caught (escapes = 0)", result: "\(caught.count)/\(bad.count)",
                    target: "all", pass: escapes.isEmpty && !bad.isEmpty),
        Requirement(id: "R2", text: "Good boards passed (false failures = 0)", result: "\(good.count - falseFails.count)/\(good.count)",
                    target: "all", pass: falseFails.isEmpty),
        Requirement(id: "R3", text: "Failing step named correctly", result: "\(rightStep.count)/\(caught.count)",
                    target: "all", pass: rightStep.count == caught.count && !caught.isEmpty),
        Requirement(id: "R4", text: "Noisy-link boards recovered by CRC + retry", result: "\(noisyPassed.count)/\(noisy.count), \(totalCRC) CRC",
                    target: "all, >0 CRC", pass: noisyPassed.count == noisy.count && totalCRC > 0),
        Requirement(id: "R5", text: "Unresponsive board verdict within budget", result: "\(fixed(slowest, 0)) ms",
                    target: "<= \(fixed(budgetMs, 0)) ms", pass: !unresponsive.isEmpty && slowest <= budgetMs),
        Requirement(id: "R6", text: "Speed-up with \(config.stations) stations", result: "\(fixed(speedup, 1))x",
                    target: ">= 4.0x", pass: speedup >= 4.0 && sameVerdicts),
        Requirement(id: "R7", text: "JSON report + CSV row for every unit", result: "\(reports)/\(units.count), \(csvRows) rows",
                    target: "all", pass: reports >= units.count && csvRows >= units.count),
        Requirement(id: "R8", text: "Test specification valid", result: "\(problems.count) problems",
                    target: "0", pass: problems.isEmpty),
    ]
    log("")
    log("ID   " + "Requirement".padding(toLength: 44, withPad: " ", startingAt: 0) + "Result".padding(toLength: 20, withPad: " ", startingAt: 0)
        + "Target".padding(toLength: 14, withPad: " ", startingAt: 0) + "Status")
    for r in reqs {
        log(r.id.padding(toLength: 5, withPad: " ", startingAt: 0) + r.text.padding(toLength: 44, withPad: " ", startingAt: 0)
            + r.result.padding(toLength: 20, withPad: " ", startingAt: 0) + r.target.padding(toLength: 14, withPad: " ", startingAt: 0)
            + (r.pass ? "PASS" : "FAIL"))
    }
    let passed = reqs.filter { $0.pass }.count
    log("\(passed)/\(reqs.count) requirements pass")
    return passed == reqs.count
}

extension String {
    func leftPad(_ width: Int) -> String {
        return count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
