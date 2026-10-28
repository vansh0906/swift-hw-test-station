// Self-tests for HWTestKit that need no XCTest, so they run with only Apple's Command Line Tools:
//   swift run selftest
// Exit code 0 means every check passed.
import Foundation
import HWTestKit

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        passed += 1
        print("ok    \(name)")
    } else {
        failed += 1
        let extra = detail()
        print("FAIL  \(name)" + (extra.isEmpty ? "" : "\n      \(extra.replacingOccurrences(of: "\n", with: "\n      "))"))
    }
}

/// The repository's spec file, found relative to this source file so it works from any directory.
func repoSpec() -> TestSpec {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // selftest
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // repository root
    let path = root.appendingPathComponent("specs/imu_board_a.json").path
    do {
        return try TestSpec.load(path: path)
    } catch {
        print("cannot load \(path): \(error)")
        exit(2)
    }
}

func runInMemory(_ fault: DeviceFault, seed: UInt64 = 3) -> UnitResult {
    let board = SimulatedIMUBoard(fault: fault, serial: "SN-TEST", seed: seed, processingMs: 0)
    return TestRunner(spec: repoSpec(), transport: InMemoryTransport(board: board)).run()
}

/// A transport that plays back scripted replies, to test the runner's protocol handling exactly.
final class ScriptedTransport: Transport {
    var script: [(Int) -> [String]]
    private var pending: [String] = []

    init(script: [(Int) -> [String]]) { self.script = script }

    func writeLine(_ line: String) throws {
        let seq = (try? Frame.decode(line).seq) ?? -1
        if !script.isEmpty { pending += script.removeFirst()(seq) }
    }

    func readLine(timeoutMs: Int) throws -> String? {
        if pending.isEmpty { return nil }
        return pending.removeFirst()
    }

    func drainInput() { pending.removeAll() }
}

print("[protocol]")
check("CRC-8 check value of \"123456789\" is 0xF4", CRC8.compute("123456789") == 0xF4)
check("CRC-8 of empty input is 0x00", CRC8.compute("") == 0x00)
// Same vectors as tools/crc8_vectors.py and firmware/host_test/test_protocol.cpp.
check("frame vector 1:ID?", Frame(seq: 1, payload: "ID?").encoded() == "1:ID?*0F\n")
check("frame vector 7:READ ACC", Frame(seq: 7, payload: "READ ACC").encoded() == "7:READ ACC*A6\n")
check("frame vector 12:ST PASS,0x00", Frame(seq: 12, payload: "ST PASS,0x00").encoded() == "12:ST PASS,0x00*04\n")

let sample = Frame(seq: 42, payload: "ACC 0.0213,-0.0098,9.8102")
check("frame round trip", (try? Frame.decode(sample.encoded())) == sample)
check("frame round trip with CRLF", (try? Frame.decode(sample.encoded().replacingOccurrences(of: "\n", with: "\r\n"))) == sample)

do {
    var chars = Array(Frame(seq: 9, payload: "VBUS 3.301").encoded().dropLast())
    var caught = 0
    var total = 0
    for i in 0..<chars.count {
        let original = chars[i]
        for replacement in ["~", "#", "0", "A"] {
            let r = Character(replacement)
            if r == original { continue }
            chars[i] = r
            total += 1
            if (try? Frame.decode(String(chars))) == nil { caught += 1 }
            chars[i] = original
        }
    }
    check("every single-character corruption is rejected (\(caught)/\(total))", caught == total)
}

check("frame without checksum rejected", (try? Frame.decode("1:ID?")) == nil)
check("frame with non-hex checksum rejected", (try? Frame.decode("1:ID?*ZZ")) == nil)
check("garbage line rejected", (try? Frame.decode("?? id imu-board-a,1.2.0")) == nil)
check("response parsing: fields", Response.parse("ACC 1.0,2.0,3.0") == Response(key: "ACC", fields: ["1.0", "2.0", "3.0"]))
check("response parsing: key only", Response.parse("OK") == Response(key: "OK", fields: []))

print("\n[versions and statistics]")
if let a = SemanticVersion("1.2.0"), let b = SemanticVersion("1.10.0"), let c = SemanticVersion("1.9.9"),
   let d = SemanticVersion("1.1.4"), let e = SemanticVersion("1.2") {
    check("1.2.0 >= 1.2.0", a >= a)
    check("1.10.0 > 1.9.9", b > c)
    check("1.1.4 < 1.2", d < e)
} else {
    check("versions parse", false)
}
check("'1.x' is not a version", SemanticVersion("1.x") == nil)
check("mean", abs(Stats.mean([1, 2, 3, 4]) - 2.5) < 1e-12)
check("sample standard deviation", abs(Stats.std([2, 4, 4, 4, 5, 5, 7, 9]) - 2.138089935) < 1e-6)
check("standard deviation of a constant is 0", Stats.std([5, 5, 5]) == 0)

print("\n[test specification]")
let spec = repoSpec()
check("repository spec has 8 steps", spec.steps.count == 8)
check("repository spec is valid", spec.problems().isEmpty, "\(spec.problems())")
do {
    var broken = spec
    broken.steps[2].low = 5.0             // low above high
    broken.steps.append(broken.steps[0])  // duplicate name
    broken.steps[5].samples = 2           // noise needs >= 3 samples
    let problems = broken.problems()
    check("broken spec reports 3 problems", problems.count == 3, "\(problems)")
}

print("\n[runner, in memory]")
do {
    let unit = runInMemory(.none)
    check("good board passes every step", unit.passed && unit.steps.count == 8 && unit.crcErrors == 0, formatUnit(unit))
    check("serial number read from the board", unit.serial == "SN-TEST")
}
for fault in DeviceFault.allCases where fault.isDefect {
    let unit = runInMemory(fault)
    check("\(fault.rawValue) fails at \(fault.expectedFailingStep ?? "-")",
          !unit.passed && unit.firstFailure == fault.expectedFailingStep, formatUnit(unit))
}
do {
    var crcErrors = 0
    var allPassed = true
    for seed in UInt64(1)...UInt64(5) {
        let unit = runInMemory(.linkNoise, seed: seed)
        allPassed = allPassed && unit.passed
        crcErrors += unit.crcErrors
    }
    check("noisy link: all 5 good boards pass via retries (\(crcErrors) CRC errors seen)", allPassed && crcErrors > 0)
}
do {
    var one = spec
    one.steps = [spec.steps[0]]
    let transport = ScriptedTransport(script: [
        { _ in [] },
        { seq in [Frame(seq: seq - 1, payload: "ID IMU-BOARD-B,1.0.0,OLD").encoded(),
                  Frame(seq: seq, payload: "ID IMU-BOARD-A,1.2.0,SN9").encoded()] },
    ])
    let unit = TestRunner(spec: one, transport: transport).run()
    check("late reply to an earlier request is ignored",
          unit.passed && unit.staleReplies == 1 && unit.timeouts == 1 && unit.serial == "SN9", formatUnit(unit))
}
do {
    let t0 = monotonicMs()
    let unit = runInMemory(.silent)
    let elapsed = monotonicMs() - t0
    let budget = Double(spec.timeoutMs * (spec.retries + 1)) + 500
    check("silent board: gives up after all retries, stops early, within \(Int(budget)) ms (took \(Int(elapsed)))",
          unit.firstFailure == "identify" && unit.timeouts == spec.retries + 1 && unit.steps.count == 1 && elapsed < budget)
}
do {
    let dir = NSTemporaryDirectory() + "hwtest-\(UUID().uuidString)"
    do {
        let writer = try ReportWriter(directory: dir)
        let good = runInMemory(.none)
        let url = try writer.write(good)
        try writer.write(runInMemory(.lowVoltage))
        let decoded = try JSONDecoder().decode(UnitResult.self, from: Data(contentsOf: url))
        let csv = try String(contentsOfFile: dir + "/summary.csv", encoding: .utf8)
        check("JSON report reads back", decoded.serial == good.serial)
        check("CSV has a header and 2 rows", csv.split(separator: "\n").count == 3, csv)
        check("CSV records the failing step", csv.contains("FAIL,supply_voltage"), csv)
        // Two boards that never identify themselves (serial "unknown"), same station, same second:
        // each must still get its own report file.
        let dead = runInMemory(.garbage)
        try writer.write(dead)
        try writer.write(dead)
        let jsons = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".json") }
        check("unidentified boards never overwrite each other's report (\(jsons.count) files)",
              dead.serial == "unknown" && jsons.count == 4)
    } catch {
        check("reports written", false, "\(error)")
    }
}

print("\n[serial port through a real pseudo-terminal]")
for (fault, shouldPass) in [(DeviceFault.none, true), (DeviceFault.stuckAccel, false)] {
    do {
        let server = try PTYDeviceServer(board: SimulatedIMUBoard(fault: fault, serial: "SN-PTY", seed: 5))
        let port = try SerialPort(path: server.path)
        let unit = TestRunner(spec: spec, transport: port).run()
        port.closePort()
        server.stop()
        check("\(fault.rawValue) board over \(server.path): \(shouldPass ? "PASS" : "FAIL") as expected",
              unit.passed == shouldPass && unit.serial == "SN-PTY", formatUnit(unit))
    } catch {
        check("pseudo-terminal test (\(fault.rawValue))", false, "\(error)")
    }
}

print("\n[fault plan]")
let plan = faultPlan(units: 200, seed: 7)
check("200 units: 40 defective, 20 noisy link, all 12 defect types",
      plan.count == 200 && plan.filter { $0.isDefect }.count == 40 && plan.filter { $0 == .linkNoise }.count == 20
          && Set(plan.filter { $0.isDefect }).count == 12)

print("\n\(failed == 0 ? "all \(passed) checks passed" : "\(failed) of \(passed + failed) checks FAILED")")
exit(failed == 0 ? 0 : 1)
