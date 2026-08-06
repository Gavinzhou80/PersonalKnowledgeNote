import Foundation

enum WebCheckpointJSONLimits {
    static let maximumDepth = 64
    // An 8 MiB JSON array can hold roughly four million one-byte values
    // plus separators. These lower caps keep Foundation object allocation
    // bounded while still allowing prepared graphs with thousands of blocks.
    static let maximumContainerEntryCount = 16_384
    static let maximumTotalValueCount = 100_000
}

enum StrictJSONValidator {
    static func validate(_ data: Data) throws {
        var parser = Parser(bytes: Array(data))
        try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.isAtEnd else {
            throw WebImportCheckpointError.invalidPackage
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var totalValueCount = 0

        var isAtEnd: Bool { index == bytes.count }

        mutating func parseValue(depth: Int) throws {
            guard depth <= WebCheckpointJSONLimits.maximumDepth else {
                throw WebImportCheckpointError.invalidPackage
            }
            totalValueCount += 1
            guard totalValueCount
                    <= WebCheckpointJSONLimits.maximumTotalValueCount
            else {
                throw WebImportCheckpointError.invalidPackage
            }
            skipWhitespace()
            guard let byte = current else {
                throw WebImportCheckpointError.invalidPackage
            }
            switch byte {
            case UInt8(ascii: "{"):
                try parseObject(depth: depth)
            case UInt8(ascii: "["):
                try parseArray(depth: depth)
            case UInt8(ascii: "\""):
                _ = try parseString()
            case UInt8(ascii: "t"):
                try consume("true")
            case UInt8(ascii: "f"):
                try consume("false")
            case UInt8(ascii: "n"):
                try consume("null")
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                try parseNumber()
            default:
                throw WebImportCheckpointError.invalidPackage
            }
        }

        mutating func skipWhitespace() {
            while let byte = current,
                byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
            {
                index += 1
            }
        }

        private var current: UInt8? {
            index < bytes.count ? bytes[index] : nil
        }

        private mutating func parseObject(depth: Int) throws {
            try expect(UInt8(ascii: "{"))
            skipWhitespace()
            if current == UInt8(ascii: "}") {
                index += 1
                return
            }
            var keys: Set<String> = []
            var entryCount = 0
            while true {
                entryCount += 1
                guard entryCount
                        <= WebCheckpointJSONLimits.maximumContainerEntryCount
                else {
                    throw WebImportCheckpointError.invalidPackage
                }
                skipWhitespace()
                let keyData = try parseString()
                let key = try JSONDecoder().decode(String.self, from: keyData)
                guard keys.insert(key).inserted else {
                    throw WebImportCheckpointError.invalidPackage
                }
                skipWhitespace()
                try expect(UInt8(ascii: ":"))
                try parseValue(depth: depth + 1)
                skipWhitespace()
                if current == UInt8(ascii: "}") {
                    index += 1
                    return
                }
                try expect(UInt8(ascii: ","))
            }
        }

        private mutating func parseArray(depth: Int) throws {
            try expect(UInt8(ascii: "["))
            skipWhitespace()
            if current == UInt8(ascii: "]") {
                index += 1
                return
            }
            var entryCount = 0
            while true {
                entryCount += 1
                guard entryCount
                        <= WebCheckpointJSONLimits.maximumContainerEntryCount
                else {
                    throw WebImportCheckpointError.invalidPackage
                }
                try parseValue(depth: depth + 1)
                skipWhitespace()
                if current == UInt8(ascii: "]") {
                    index += 1
                    return
                }
                try expect(UInt8(ascii: ","))
            }
        }

        private mutating func parseString() throws -> Data {
            let start = index
            try expect(UInt8(ascii: "\""))
            while let byte = current {
                if byte == UInt8(ascii: "\"") {
                    index += 1
                    return Data(bytes[start..<index])
                }
                guard byte >= 0x20 else {
                    throw WebImportCheckpointError.invalidPackage
                }
                index += 1
                guard byte == UInt8(ascii: "\\") else {
                    continue
                }
                guard let escape = current,
                    [
                        UInt8(ascii: "\""), UInt8(ascii: "\\"),
                        UInt8(ascii: "/"), UInt8(ascii: "b"),
                        UInt8(ascii: "f"), UInt8(ascii: "n"),
                        UInt8(ascii: "r"), UInt8(ascii: "t"),
                        UInt8(ascii: "u"),
                    ].contains(escape)
                else {
                    throw WebImportCheckpointError.invalidPackage
                }
                index += 1
                if escape == UInt8(ascii: "u") {
                    guard index + 4 <= bytes.count,
                        bytes[index..<(index + 4)].allSatisfy(isHexDigit)
                    else {
                        throw WebImportCheckpointError.invalidPackage
                    }
                    index += 4
                }
            }
            throw WebImportCheckpointError.invalidPackage
        }

        private mutating func parseNumber() throws {
            let start = index
            while let byte = current,
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                    || [
                        UInt8(ascii: "-"), UInt8(ascii: "+"),
                        UInt8(ascii: "."), UInt8(ascii: "e"),
                        UInt8(ascii: "E"),
                    ].contains(byte)
            {
                index += 1
            }
            guard index > start else {
                throw WebImportCheckpointError.invalidPackage
            }
        }

        private mutating func consume(_ literal: StaticString) throws {
            let expected = Array(String(describing: literal).utf8)
            guard index + expected.count <= bytes.count,
                Array(bytes[index..<(index + expected.count)]) == expected
            else {
                throw WebImportCheckpointError.invalidPackage
            }
            index += expected.count
        }

        private mutating func expect(_ byte: UInt8) throws {
            guard current == byte else {
                throw WebImportCheckpointError.invalidPackage
            }
            index += 1
        }

        private func isHexDigit(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
        }
    }
}
