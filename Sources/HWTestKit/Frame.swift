import Foundation

/// CRC-8 with polynomial 0x07, initial value 0x00, no reflection (the "CRC-8/SMBUS" variant).
/// Any burst error of 8 bits or fewer in a frame is guaranteed to be caught.
public enum CRC8 {
    public static func compute(bytes: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 {
                if crc & 0x80 != 0 {
                    crc = (crc << 1) ^ 0x07
                } else {
                    crc = crc << 1
                }
            }
        }
        return crc
    }

    public static func compute(_ text: String) -> UInt8 {
        return compute(bytes: Array(text.utf8))
    }
}

/// Two uppercase hex digits, e.g. 0x0A -> "0A".
public func hex2(_ value: UInt8) -> String {
    let s = String(value, radix: 16, uppercase: true)
    return s.count == 1 ? "0" + s : s
}

public enum FrameError: Error, Equatable, CustomStringConvertible {
    case missingChecksum
    case badChecksum(expected: UInt8, received: UInt8)
    case malformed(String)

    public var description: String {
        switch self {
        case .missingChecksum:
            return "no checksum in frame"
        case let .badChecksum(expected, received):
            return "checksum mismatch (computed \(hex2(expected)), received \(hex2(received)))"
        case let .malformed(why):
            return "malformed frame: \(why)"
        }
    }
}

/// One line on the wire: `<seq>:<payload>*<CRC8 as 2 hex digits>\n`, for example `7:READ ACC*A6`.
/// The sequence number lets the host reject a late reply to an earlier request.
public struct Frame: Equatable {
    public let seq: Int
    public let payload: String

    public init(seq: Int, payload: String) {
        self.seq = seq
        self.payload = payload
    }

    public var body: String { return "\(seq):\(payload)" }

    public func encoded() -> String {
        return body + "*" + hex2(CRC8.compute(body)) + "\n"
    }

    public static func decode(_ rawLine: String) throws -> Frame {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let star = line.lastIndex(of: "*") else { throw FrameError.missingChecksum }
        let body = String(line[line.startIndex..<star])
        let crcText = String(line[line.index(after: star)...])
        guard crcText.count == 2, let received = UInt8(crcText, radix: 16) else {
            throw FrameError.malformed("checksum field '\(crcText)'")
        }
        let expected = CRC8.compute(body)
        guard expected == received else {
            throw FrameError.badChecksum(expected: expected, received: received)
        }
        guard let colon = body.firstIndex(of: ":"), let seq = Int(body[body.startIndex..<colon]) else {
            throw FrameError.malformed("no sequence number")
        }
        return Frame(seq: seq, payload: String(body[body.index(after: colon)...]))
    }
}

/// A device reply payload such as `ACC 0.0213,-0.0098,9.8102` split into its key and comma-separated fields.
public struct Response: Equatable {
    public let key: String
    public let fields: [String]

    public init(key: String, fields: [String]) {
        self.key = key
        self.fields = fields
    }

    public static func parse(_ payload: String) -> Response {
        guard let space = payload.firstIndex(of: " ") else {
            return Response(key: payload, fields: [])
        }
        let key = String(payload[payload.startIndex..<space])
        let rest = String(payload[payload.index(after: space)...])
        let fields = rest.split(separator: ",", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        return Response(key: key, fields: fields)
    }
}
