import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Thin wrappers so class methods named read/write/close never shadow the C calls.
@inline(__always) func cOpen(_ path: String, _ flags: Int32) -> Int32 { return open(path, flags) }
@inline(__always) func cClose(_ fd: Int32) { _ = close(fd) }
@inline(__always) func cRead(_ fd: Int32, _ buf: UnsafeMutableRawPointer?, _ count: Int) -> Int { return read(fd, buf, count) }
@inline(__always) func cWrite(_ fd: Int32, _ buf: UnsafeRawPointer?, _ count: Int) -> Int { return write(fd, buf, count) }

/// Milliseconds on a monotonic clock.
public func monotonicMs() -> Double {
    return Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000.0
}

public enum SerialError: Error, CustomStringConvertible {
    case open(path: String, errno: Int32)
    case configure(String)
    case io(String)

    public var description: String {
        switch self {
        case let .open(path, code):
            return "cannot open \(path): \(String(cString: strerror(code)))"
        case let .configure(why):
            return "cannot configure port: \(why)"
        case let .io(why):
            return "serial I/O error: \(why)"
        }
    }
}

/// Anything the test runner can talk to: a real serial port, a pseudo-terminal, or an in-memory fake.
public protocol Transport: AnyObject {
    func writeLine(_ line: String) throws
    /// Returns the next complete line without its newline, or nil if none arrived within the timeout.
    func readLine(timeoutMs: Int) throws -> String?
    /// Throws away anything already received (used before a retry).
    func drainInput()
}

/// Puts a terminal file descriptor into raw mode (no echo, no line editing, 8N1) at the given speed.
func configureRaw(fd: Int32, baud: Int) throws {
    var settings = termios()
    guard tcgetattr(fd, &settings) == 0 else {
        throw SerialError.configure("tcgetattr failed (errno \(errno))")
    }
    cfmakeraw(&settings)
    let speed = speedConstant(baud)
    _ = cfsetispeed(&settings, speed)
    _ = cfsetospeed(&settings, speed)
    settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
    guard tcsetattr(fd, TCSANOW, &settings) == 0 else {
        throw SerialError.configure("tcsetattr failed (errno \(errno))")
    }
}

func speedConstant(_ baud: Int) -> speed_t {
    switch baud {
    case 9600: return speed_t(B9600)
    case 19200: return speed_t(B19200)
    case 38400: return speed_t(B38400)
    case 57600: return speed_t(B57600)
    default: return speed_t(B115200)
    }
}

/// Waits until `fd` is readable or the timeout passes. Returns true if readable.
func waitReadable(_ fd: Int32, timeoutMs: Int) throws -> Bool {
    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    while true {
        let r = poll(&pfd, 1, Int32(max(0, timeoutMs)))
        if r > 0 { return true }
        if r == 0 { return false }
        if errno == EINTR { continue }
        throw SerialError.io("poll failed (errno \(errno))")
    }
}

/// Writes every byte of `bytes`, waiting briefly if the port is temporarily full.
func writeAll(_ fd: Int32, _ bytes: [UInt8]) throws {
    var offset = 0
    let deadline = monotonicMs() + 1000
    while offset < bytes.count {
        let n = bytes.withUnsafeBytes { raw -> Int in
            return cWrite(fd, raw.baseAddress! + offset, raw.count - offset)
        }
        if n > 0 {
            offset += n
            continue
        }
        let code = errno
        if n < 0 && (code == EAGAIN || code == EINTR) && monotonicMs() < deadline {
            usleep(1000)
            continue
        }
        throw SerialError.io("write failed (errno \(code))")
    }
}

/// A POSIX serial port (a USB-serial adapter such as /dev/cu.usbserial-0001, or a pseudo-terminal),
/// read line by line with timeouts.
public final class SerialPort: Transport {
    public let path: String
    private var fd: Int32
    private var buffer: [UInt8] = []

    public init(path: String, baud: Int = 115200) throws {
        self.path = path
        let handle = cOpen(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard handle >= 0 else { throw SerialError.open(path: path, errno: errno) }
        fd = handle
        do {
            try configureRaw(fd: fd, baud: baud)
        } catch {
            cClose(handle)
            fd = -1
            throw error
        }
        _ = tcflush(fd, TCIOFLUSH)
    }

    deinit { closePort() }

    public func closePort() {
        if fd >= 0 {
            cClose(fd)
            fd = -1
        }
    }

    public func writeLine(_ line: String) throws {
        guard fd >= 0 else { throw SerialError.io("port closed") }
        try writeAll(fd, Array(line.utf8))
    }

    public func readLine(timeoutMs: Int) throws -> String? {
        guard fd >= 0 else { throw SerialError.io("port closed") }
        let deadline = monotonicMs() + Double(timeoutMs)
        var chunk = [UInt8](repeating: 0, count: 512)
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let lineBytes = Array(buffer[0..<newline])
                buffer.removeSubrange(0...newline)
                return String(decoding: lineBytes, as: UTF8.self)
            }
            let remaining = deadline - monotonicMs()
            if remaining <= 0 { return nil }
            guard try waitReadable(fd, timeoutMs: Int(remaining.rounded(.up))) else { return nil }
            let n = chunk.withUnsafeMutableBytes { raw -> Int in
                return cRead(fd, raw.baseAddress, raw.count)
            }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
            } else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                continue
            } else {
                throw SerialError.io(n == 0 ? "device disconnected" : "read failed (errno \(errno))")
            }
        }
    }

    public func drainInput() {
        buffer.removeAll()
        if fd >= 0 { _ = tcflush(fd, TCIFLUSH) }
    }
}

/// A pseudo-terminal pair: software that opens `slavePath` sees an ordinary serial port, while the
/// simulator reads and writes the other end (`masterFD`). This is how the tool is tested without hardware.
public final class PseudoTerminal {
    public let masterFD: Int32
    public let slavePath: String
    private let slaveFD: Int32
    private var closed = false

    public init() throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw SerialError.configure("posix_openpt failed (errno \(errno))") }
        guard grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            cClose(master)
            throw SerialError.configure("cannot set up pseudo-terminal (errno \(errno))")
        }
        let path = String(cString: name)
        // Keep one handle on the device side open so the pair stays alive between test runs, and make it
        // raw at once so the terminal layer never echoes or edits what the host sends.
        let slave = cOpen(path, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            cClose(master)
            throw SerialError.open(path: path, errno: errno)
        }
        do {
            try configureRaw(fd: slave, baud: 115200)
        } catch {
            cClose(slave)
            cClose(master)
            throw error
        }
        masterFD = master
        slaveFD = slave
        slavePath = path
    }

    deinit { close() }

    public func close() {
        if !closed {
            closed = true
            cClose(slaveFD)
            cClose(masterFD)
        }
    }
}
