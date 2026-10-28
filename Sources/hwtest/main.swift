import Foundation
import HWTestKit

let usage = """
hwtest - factory-style hardware test station for serial devices

USAGE
  hwtest run   --port <path> [--spec <file>] [--baud <rate>] [--station <name>] [--report <dir>]
  hwtest sim   [--fault <name>] [--serial <SN>] [--seed <n>]
  hwtest bench [--units <n>] [--stations <n>] [--spec <file>] [--report <dir>]
  hwtest check-spec [<file>]
  hwtest ports

COMMANDS
  run         test one device and print a step table; exit code 0 = PASS, 1 = FAIL, 2 = error
  sim         serve a simulated IMU board on a pseudo-terminal (prints the port path to test against)
  bench       production run on simulated boards with parallel stations, plus the requirement table
  check-spec  validate a test specification
  ports       list serial ports (USB-serial adapters show up as /dev/cu.usb*)

FAULTS for sim: \(DeviceFault.allCases.map { $0.rawValue }.joined(separator: ", "))
"""

/// Minimal option parser: `--name value` pairs after the command.
struct Options {
    var values: [String: String] = [:]
    var positional: [String] = []

    init(_ args: ArraySlice<String>) {
        var it = args.makeIterator()
        while let a = it.next() {
            if a.hasPrefix("--") {
                values[String(a.dropFirst(2))] = it.next() ?? ""
            } else {
                positional.append(a)
            }
        }
    }

    func string(_ name: String, _ fallback: String) -> String { return values[name] ?? fallback }
    func int(_ name: String, _ fallback: Int) -> Int { return values[name].flatMap { Int($0) } ?? fallback }
}

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func loadSpec(_ path: String) -> TestSpec {
    do {
        return try TestSpec.load(path: path)
    } catch {
        fail("cannot read spec \(path): \(error)")
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    print(usage)
    exit(0)
}
let command = args[1]
let options = Options(args.dropFirst(2))
let defaultSpec = "specs/imu_board_a.json"

switch command {
case "run":
    let spec = loadSpec(options.string("spec", defaultSpec))
    guard let port = options.values["port"] else { fail("run needs --port <path>") }
    let transport: SerialPort
    do {
        transport = try SerialPort(path: port, baud: options.int("baud", 115200))
    } catch {
        fail("\(error)")
    }
    let unit = TestRunner(spec: spec, transport: transport).run(station: options.string("station", "station-1"))
    print(formatUnit(unit))
    do {
        let writer = try ReportWriter(directory: options.string("report", "reports"))
        let url = try writer.write(unit)
        print("report: \(url.path)")
    } catch {
        print("warning: could not write report: \(error)")
    }
    exit(unit.passed ? 0 : 1)

case "sim":
    let faultName = options.string("fault", "none")
    guard let fault = DeviceFault(rawValue: faultName) else { fail("unknown fault '\(faultName)'") }
    let board = SimulatedIMUBoard(fault: fault, serial: options.string("serial", "SN00042"),
                                  seed: UInt64(options.int("seed", 1)))
    do {
        let server = try PTYDeviceServer(board: board)
        print("Simulated IMU-BOARD-A (fault: \(fault.rawValue)) on \(server.path)")
        print("In another terminal:  swift run hwtest run --port \(server.path)")
        print("Press Ctrl-C to stop.")
        while true { sleep(3600) }
    } catch {
        fail("cannot start simulator: \(error)")
    }

case "bench":
    let spec = loadSpec(options.string("spec", defaultSpec))
    var config = BenchConfig()
    config.units = options.int("units", 200)
    config.stations = options.int("stations", 8)
    config.reportDir = options.string("report", "reports/bench")
    try? FileManager.default.removeItem(atPath: config.reportDir)
    do {
        let ok = try runBench(spec: spec, config: config) { print($0) }
        exit(ok ? 0 : 1)
    } catch {
        fail("bench failed: \(error)")
    }

case "check-spec":
    let path = options.positional.first ?? defaultSpec
    let spec = loadSpec(path)
    let problems = spec.problems()
    if problems.isEmpty {
        print("\(path): valid, \(spec.steps.count) steps for \(spec.product)")
        exit(0)
    }
    for p in problems { print("problem: \(p)") }
    exit(1)

case "ports":
    let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
    let ports = names.filter { $0.hasPrefix("cu.") || $0.hasPrefix("ttyUSB") || $0.hasPrefix("ttyACM") }.sorted()
    if ports.isEmpty { print("no serial ports found") }
    for p in ports { print("/dev/\(p)") }

default:
    print(usage)
    exit(command == "help" || command == "--help" ? 0 : 2)
}
