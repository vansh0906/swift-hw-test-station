import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Deterministic random numbers (SplitMix64), so every simulated board behaves the same on every machine.
public struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Standard normal sample (Box-Muller).
    public mutating func gaussian() -> Double {
        let u1 = Double.random(in: Double.ulpOfOne..<1.0, using: &self)
        let u2 = Double.random(in: 0.0..<1.0, using: &self)
        return (-2.0 * log(u1)).squareRoot() * cos(2.0 * Double.pi * u2)
    }
}

/// Faults a production unit can arrive with. `none` and `linkNoise` are good boards; the rest are defects.
public enum DeviceFault: String, CaseIterable, Codable {
    case none
    case linkNoise = "link_noise"           // good board on a noisy cable: 5% of replies corrupted
    case wrongProduct = "wrong_product"     // wrong board variant loaded on the fixture
    case oldFirmware = "old_firmware"       // firmware below the minimum version
    case lowVoltage = "low_voltage"         // 3.3 V rail sagging
    case overTemp = "over_temp"             // board running hot
    case deadAccel = "dead_accel"           // accelerometer reads no gravity
    case stuckAccel = "stuck_accel"         // accelerometer repeats the same value (no noise at all)
    case noisyAccel = "noisy_accel"         // accelerometer far too noisy
    case gyroBias = "gyro_bias"             // gyro offset out of spec
    case selfTestFail = "selftest_fail"     // on-chip self-test reports a fault
    case slowResponse = "slow_response"     // firmware answers after 400 ms, too late
    case silent                             // no reply at all (unpowered or dead MCU)
    case garbage                            // replies are not valid frames (wrong baud rate, for example)

    public var isDefect: Bool {
        switch self {
        case .none, .linkNoise:
            return false
        default:
            return true
        }
    }

    /// The test step that should catch this fault first (nil for good boards).
    public var expectedFailingStep: String? {
        switch self {
        case .none, .linkNoise: return nil
        case .wrongProduct, .slowResponse, .silent, .garbage: return "identify"
        case .oldFirmware: return "firmware_version"
        case .lowVoltage: return "supply_voltage"
        case .overTemp: return "temperature"
        case .deadAccel: return "accel_gravity"
        case .stuckAccel, .noisyAccel: return "accel_noise"
        case .gyroBias: return "gyro_bias"
        case .selfTestFail: return "selftest"
        }
    }
}

/// A simulated IMU sensor board that answers the same line protocol as the ESP32 firmware in firmware/.
public final class SimulatedIMUBoard {
    public struct Reply {
        public var lines: [String]
        public var delayMs: Int
    }

    public let fault: DeviceFault
    public let serial: String
    public let processingMs: Int
    private var rng: SeededRNG

    public init(fault: DeviceFault = .none, serial: String = "SN00001", seed: UInt64 = 1, processingMs: Int = 2) {
        self.fault = fault
        self.serial = serial
        self.processingMs = processingMs
        self.rng = SeededRNG(seed: seed)
    }

    public func handle(_ rawLine: String) -> Reply {
        let request: Frame
        do {
            request = try Frame.decode(rawLine)
        } catch {
            return Reply(lines: [Frame(seq: 0, payload: "ERR FRAME").encoded()], delayMs: processingMs)
        }
        if fault == .silent {
            return Reply(lines: [], delayMs: 0)
        }
        let payload = respond(to: request.payload)
        var line = Frame(seq: request.seq, payload: payload).encoded()
        if fault == .garbage {
            line = "?? " + payload.lowercased() + "\n"
        }
        if fault == .linkNoise && Double.random(in: 0.0..<1.0, using: &rng) < 0.05 {
            line = corrupt(line)
        }
        return Reply(lines: [line], delayMs: fault == .slowResponse ? 400 : processingMs)
    }

    private func respond(to command: String) -> String {
        switch command {
        case "ID?":
            let product = fault == .wrongProduct ? "IMU-BOARD-B" : "IMU-BOARD-A"
            let firmware = fault == .oldFirmware ? "1.1.4" : "1.2.0"
            return "ID \(product),\(firmware),\(serial)"
        case "READ VBUS":
            let volts = (fault == .lowVoltage ? 3.05 : 3.30) + 0.004 * rng.gaussian()
            return "VBUS " + fixed(volts, 3)
        case "READ TEMP":
            let celsius = (fault == .overTemp ? 72.0 : 31.0) + 0.2 * rng.gaussian()
            return "TEMP " + fixed(celsius, 2)
        case "READ ACC":
            let base = [0.02, -0.01, fault == .deadAccel ? 0.0 : 9.81]
            if fault == .stuckAccel {
                return "ACC " + base.map { fixed($0, 4) }.joined(separator: ",")
            }
            let sigma = fault == .noisyAccel ? 0.5 : 0.02
            let values = base.map { $0 + sigma * rng.gaussian() }
            return "ACC " + values.map { fixed($0, 4) }.joined(separator: ",")
        case "READ GYR":
            let bias = [fault == .gyroBias ? 0.2 : 0.002, -0.001, 0.003]
            let values = bias.map { $0 + 0.001 * rng.gaussian() }
            return "GYR " + values.map { fixed($0, 5) }.joined(separator: ",")
        case "SELFTEST":
            return fault == .selfTestFail ? "ST FAIL,0x04" : "ST PASS,0x00"
        default:
            return "ERR UNKNOWN"
        }
    }

    /// Changes one character of the frame (never the newline), as electrical noise on a cable would.
    private func corrupt(_ line: String) -> String {
        var chars = Array(line)
        guard chars.count > 2 else { return line }
        let index = Int.random(in: 0..<(chars.count - 1), using: &rng)
        chars[index] = chars[index] == "~" ? "#" : "~"
        return String(chars)
    }
}

func fixed(_ value: Double, _ decimals: Int) -> String {
    return String(format: "%.\(decimals)f", value)
}

/// Serves a simulated board on a pseudo-terminal, so the test tool talks to it through a real serial-port path.
public final class PTYDeviceServer: @unchecked Sendable {
    public let board: SimulatedIMUBoard
    private let pty: PseudoTerminal
    private let lock = NSLock()
    private var running = true
    private let finished = DispatchSemaphore(value: 0)

    public var path: String { return pty.slavePath }

    public init(board: SimulatedIMUBoard) throws {
        self.board = board
        self.pty = try PseudoTerminal()
        let thread = Thread { [self] in self.serve() }
        thread.start()
    }

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func serve() {
        var pending: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 512)
        let fd = pty.masterFD
        while isRunning() {
            guard let readable = try? waitReadable(fd, timeoutMs: 20), readable else { continue }
            let n = chunk.withUnsafeMutableBytes { raw -> Int in
                return cRead(fd, raw.baseAddress, raw.count)
            }
            if n <= 0 {
                usleep(2000)
                continue
            }
            pending.append(contentsOf: chunk[0..<n])
            while isRunning(), let newline = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[0..<newline], as: UTF8.self)
                pending.removeSubrange(0...newline)
                let reply = board.handle(line)
                if reply.delayMs > 0 { usleep(UInt32(reply.delayMs * 1000)) }
                for out in reply.lines {
                    try? writeAll(fd, Array(out.utf8))
                }
            }
        }
        finished.signal()
    }

    /// Stops the simulator thread and closes the pseudo-terminal.
    public func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        if wasRunning {
            finished.wait()
            pty.close()
        }
    }
}
