import SwiftUI

/// Parses SVG path data (`d` attribute) into a SwiftUI `Path`: move, line, horizontal/vertical line, cubic and
/// quadratic Béziers (with their smooth forms) and close, absolute and relative, with implicit repeats. Arcs are
/// not supported (`scripts/build-body-map.mjs` rewrites the body map's arcs as cubics). Returns nil on malformed data.
enum SVGPath {
    static func parse(_ data: String) -> Path? {
        var tokens = Tokens(Array(data.utf8))
        var builder = Builder()
        var command: UInt8?
        while tokens.skipSeparators() {
            if let next = tokens.command() {
                command = next
            }
            guard let cmd = command, builder.started || cmd | 0x20 == UInt8(ascii: "m"),
                  case .next(let following) = builder.apply(cmd, &tokens) else { return nil }
            command = following
        }
        return builder.path
    }

    /// What may follow a command's parameters: more parameters for this (or the implied) command, or — after
    /// Z — only a new command (`next(nil)`); `invalid` when the parameters are malformed.
    private enum Step { case next(UInt8?), invalid }

    /// Path under construction plus the pen state SVG's relative and smooth commands need.
    private struct Builder {
        var path = Path()
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var started = false

        /// Applies one command's parameters.
        mutating func apply(_ cmd: UInt8, _ tokens: inout Tokens) -> Step {
            let relative = cmd >= UInt8(ascii: "a")
            let base = relative ? current : .zero
            let point = { (t: inout Tokens) -> CGPoint? in
                guard let x = t.number(), let y = t.number() else { return nil }
                return CGPoint(x: base.x + x, y: base.y + y)
            }
            switch cmd | 0x20 {
            case UInt8(ascii: "m"):
                guard let p = point(&tokens) else { return .invalid }
                path.move(to: p)
                current = p
                start = p
                lastControl = nil
                started = true
                return .next(relative ? UInt8(ascii: "l") : UInt8(ascii: "L")) // further pairs are lines
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = start
                lastControl = nil
                return .next(nil)
            case UInt8(ascii: "l"), UInt8(ascii: "h"), UInt8(ascii: "v"):
                return line(cmd | 0x20, relative: relative, tokens: &tokens, point: point) ? .next(cmd) : .invalid
            default:
                return curve(cmd | 0x20, tokens: &tokens, point: point) ? .next(cmd) : .invalid
            }
        }

        private mutating func line(_ kind: UInt8, relative: Bool, tokens: inout Tokens,
                                   point: (inout Tokens) -> CGPoint?) -> Bool {
            let target: CGPoint?
            switch kind {
            case UInt8(ascii: "h"): target = tokens.number().map { CGPoint(x: (relative ? current.x : 0) + $0, y: current.y) }
            case UInt8(ascii: "v"): target = tokens.number().map { CGPoint(x: current.x, y: (relative ? current.y : 0) + $0) }
            default: target = point(&tokens)
            }
            guard let target else { return false }
            path.addLine(to: target)
            current = target
            lastControl = nil
            return true
        }

        private mutating func curve(_ kind: UInt8, tokens: inout Tokens, point: (inout Tokens) -> CGPoint?) -> Bool {
            let reflected = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
            switch kind {
            case UInt8(ascii: "c"), UInt8(ascii: "s"):
                let first = kind == UInt8(ascii: "c") ? point(&tokens) : reflected
                guard let first, let second = point(&tokens), let end = point(&tokens) else { return false }
                path.addCurve(to: end, control1: first, control2: second)
                current = end
                lastControl = second
            case UInt8(ascii: "q"), UInt8(ascii: "t"):
                let control = kind == UInt8(ascii: "q") ? point(&tokens) : reflected
                guard let control, let end = point(&tokens) else { return false }
                path.addQuadCurve(to: end, control: control)
                current = end
                lastControl = control
            default:
                return false
            }
            return true
        }
    }

    /// Byte scanner over the path string.
    private struct Tokens {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        private static let separators: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D, UInt8(ascii: ",")]
        private static let commands = Set("MmLlHhVvCcSsQqTtZz".utf8)

        private func isDigit(_ at: Int) -> Bool {
            at < bytes.count && bytes[at] >= UInt8(ascii: "0") && bytes[at] <= UInt8(ascii: "9")
        }

        private func isSign(_ at: Int) -> Bool {
            at < bytes.count && (bytes[at] == UInt8(ascii: "-") || bytes[at] == UInt8(ascii: "+"))
        }

        /// Skips whitespace and commas; false at the end.
        mutating func skipSeparators() -> Bool {
            while index < bytes.count, Self.separators.contains(bytes[index]) { index += 1 }
            return index < bytes.count
        }

        mutating func command() -> UInt8? {
            guard Self.commands.contains(bytes[index]) else { return nil }
            index += 1
            return bytes[index - 1]
        }

        /// A number such as `-6.8`, `.5`, `1e-3`; `0.5.5` reads as `0.5` then `.5`.
        mutating func number() -> CGFloat? {
            guard skipSeparators() else { return nil }
            let begin = index
            if isSign(index) { index += 1 }
            var digits = false
            var dot = false
            while index < bytes.count {
                if isDigit(index) {
                    digits = true
                } else if bytes[index] == UInt8(ascii: "."), !dot {
                    dot = true
                } else {
                    break
                }
                index += 1
            }
            if digits, index < bytes.count, bytes[index] | 0x20 == UInt8(ascii: "e") {
                let exponent = isSign(index + 1) ? index + 2 : index + 1
                if isDigit(exponent) {
                    index = exponent
                    while isDigit(index) { index += 1 }
                }
            }
            guard digits, let value = Double(String(decoding: bytes[begin..<index], as: UTF8.self)) else {
                index = begin
                return nil
            }
            return CGFloat(value)
        }
    }
}
