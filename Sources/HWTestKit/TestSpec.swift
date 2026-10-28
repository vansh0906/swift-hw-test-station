import Foundation

/// How a step judges the device's answer.
public enum CheckKind: String, Codable {
    case equals    // listed fields must equal `equals`
    case version   // field must be at least `minVersion` (semantic version)
    case range     // mean of each listed field over `samples` readings must be within [low, high]
    case noise     // sample standard deviation of each listed field must be within [minStd, maxStd]
}

/// One line of a hardware test specification.
public struct TestStep: Codable, Equatable {
    public var name: String
    public var command: String
    public var check: CheckKind
    public var key: String?
    public var fields: [Int]?
    public var equals: String?
    public var minVersion: String?
    public var low: Double?
    public var high: Double?
    public var minStd: Double?
    public var maxStd: Double?
    public var samples: Int?
    public var unit: String?
    public var abortOnFail: Bool?
}

/// A hardware test specification for one product, loaded from JSON (see specs/imu_board_a.json).
public struct TestSpec: Codable, Equatable {
    public var product: String
    public var timeoutMs: Int
    public var retries: Int
    public var steps: [TestStep]

    public static func load(path: String) throws -> TestSpec {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(TestSpec.self, from: data)
    }

    /// Problems that would make the spec ambiguous or impossible to pass. Empty means the spec is valid.
    public func problems() -> [String] {
        var out: [String] = []
        if steps.isEmpty { out.append("spec has no steps") }
        if timeoutMs <= 0 { out.append("timeoutMs must be positive") }
        if retries < 0 { out.append("retries cannot be negative") }
        var seen = Set<String>()
        for step in steps {
            if seen.contains(step.name) { out.append("duplicate step name '\(step.name)'") }
            seen.insert(step.name)
            if step.command.isEmpty { out.append("\(step.name): empty command") }
            if let n = step.samples, n < 1 { out.append("\(step.name): samples must be at least 1") }
            if let fields = step.fields, fields.contains(where: { $0 < 0 }) {
                out.append("\(step.name): negative field index")
            }
            switch step.check {
            case .equals:
                if step.equals == nil { out.append("\(step.name): 'equals' check needs an 'equals' value") }
            case .version:
                if step.minVersion.flatMap(SemanticVersion.init) == nil {
                    out.append("\(step.name): 'version' check needs a valid 'minVersion'")
                }
            case .range:
                guard let lo = step.low, let hi = step.high else {
                    out.append("\(step.name): 'range' check needs 'low' and 'high'")
                    break
                }
                if lo > hi { out.append("\(step.name): low limit above high limit") }
            case .noise:
                guard let lo = step.minStd, let hi = step.maxStd else {
                    out.append("\(step.name): 'noise' check needs 'minStd' and 'maxStd'")
                    break
                }
                if lo > hi { out.append("\(step.name): minStd above maxStd") }
                if (step.samples ?? 1) < 3 { out.append("\(step.name): 'noise' check needs at least 3 samples") }
            }
        }
        return out
    }
}

/// Semantic version like 1.2.0, compared component by component.
public struct SemanticVersion: Comparable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        let pieces = text.trimmingCharacters(in: .whitespaces).split(separator: ".")
        var values: [Int] = []
        for piece in pieces {
            guard let v = Int(piece), v >= 0 else { return nil }
            values.append(v)
        }
        guard !values.isEmpty else { return nil }
        parts = values
    }

    public var description: String { return parts.map(String.init).joined(separator: ".") }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        let n = Swift.max(a.parts.count, b.parts.count)
        for i in 0..<n {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: SemanticVersion, b: SemanticVersion) -> Bool {
        return !(a < b) && !(b < a)
    }
}

public enum Stats {
    public static func mean(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return .nan }
        return xs.reduce(0, +) / Double(xs.count)
    }

    /// Sample standard deviation (n - 1 in the denominator).
    public static func std(_ xs: [Double]) -> Double {
        guard xs.count > 1 else { return 0 }
        let m = mean(xs)
        let ss = xs.reduce(0) { $0 + ($1 - m) * ($1 - m) }
        return (ss / Double(xs.count - 1)).squareRoot()
    }
}
