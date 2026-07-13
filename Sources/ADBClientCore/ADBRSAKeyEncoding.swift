import Foundation

public struct ADBRSAPublicKeyComponents: Equatable, Sendable {
    public static let adbModulusByteCount = 256

    public var modulus: [UInt8]
    public var exponent: UInt32

    public init(modulus: [UInt8], exponent: UInt32) throws {
        let normalizedModulus = Self.normalizedModulus(modulus)
        guard !normalizedModulus.isEmpty else {
            throw ADBRSAKeyEncodingError.emptyModulus
        }

        guard normalizedModulus.count <= Self.adbModulusByteCount else {
            throw ADBRSAKeyEncodingError.unsupportedModulusByteCount(normalizedModulus.count)
        }

        guard normalizedModulus.last.map({ $0 & 1 == 1 }) == true else {
            throw ADBRSAKeyEncodingError.evenModulus
        }

        guard exponent == 3 || exponent == 65_537 else {
            throw ADBRSAKeyEncodingError.unsupportedExponent(exponent)
        }

        self.modulus = normalizedModulus
        self.exponent = exponent
    }

    var adbPaddedModulus: [UInt8] {
        Array(repeating: 0, count: Self.adbModulusByteCount - modulus.count) + modulus
    }

    private static func normalizedModulus(_ modulus: [UInt8]) -> [UInt8] {
        var normalized = modulus
        while normalized.count > 1 && normalized.first == 0 {
            normalized.removeFirst()
        }
        return normalized
    }
}

public enum ADBRSAKeyEncodingError: Error, Equatable, Sendable {
    case emptyModulus
    case unsupportedModulusByteCount(Int)
    case evenModulus
    case unsupportedExponent(UInt32)
    case invalidDER
    case unsupportedDERInteger
    case invalidMontgomeryReduction
}

public enum ADBRSAKeyEncoder {
    public static let androidPublicKeyByteCount = 524

    public static func androidPublicKey(
        components: ADBRSAPublicKeyComponents,
        comment: String
    ) throws -> ADBAuthenticationPublicKey {
        let binaryKey = try androidPublicKeyBinary(components: components)
        let encodedKey = Data(binaryKey).base64EncodedString()
        return try ADBAuthenticationPublicKey("\(encodedKey) \(comment)")
    }

    public static func androidPublicKeyBinary(components: ADBRSAPublicKeyComponents) throws -> [UInt8] {
        let littleEndianModulusBytes = Array(components.adbPaddedModulus.reversed())
        let modulusWords = words(fromLittleEndianBytes: littleEndianModulusBytes)
        let rrWords = try montgomeryRRWords(modulusWords: modulusWords)

        var bytes: [UInt8] = []
        bytes.reserveCapacity(androidPublicKeyByteCount)
        bytes.appendLittleEndianUInt32(UInt32(ADBRSAPublicKeyComponents.adbModulusByteCount / 4))
        bytes.appendLittleEndianUInt32(negatedModularInverse32(modulusWords[0]))
        bytes.append(contentsOf: littleEndianModulusBytes)
        bytes.append(contentsOf: littleEndianBytes(fromWords: rrWords))
        bytes.appendLittleEndianUInt32(components.exponent)
        return bytes
    }

    public static func componentsFromDEREncodedPublicKey(_ bytes: [UInt8]) throws -> ADBRSAPublicKeyComponents {
        if let components = try? componentsFromPKCS1DEREncodedPublicKey(bytes) {
            return components
        }

        return try componentsFromSubjectPublicKeyInfoDER(bytes)
    }

    public static func componentsFromPKCS1DEREncodedPublicKey(_ bytes: [UInt8]) throws -> ADBRSAPublicKeyComponents {
        var reader = DERReader(bytes)
        var sequence = try reader.readSequence()
        let modulus = try sequence.readInteger()
        let exponentBytes = try sequence.readInteger()

        guard sequence.isAtEnd, reader.isAtEnd else {
            throw ADBRSAKeyEncodingError.invalidDER
        }

        return try ADBRSAPublicKeyComponents(
            modulus: modulus,
            exponent: exponent(fromBigEndianBytes: exponentBytes)
        )
    }

    private static func componentsFromSubjectPublicKeyInfoDER(_ bytes: [UInt8]) throws -> ADBRSAPublicKeyComponents {
        var reader = DERReader(bytes)
        var sequence = try reader.readSequence()
        _ = try sequence.readSequence()
        let publicKeyBytes = try sequence.readBitString()

        guard sequence.isAtEnd, reader.isAtEnd else {
            throw ADBRSAKeyEncodingError.invalidDER
        }

        return try componentsFromPKCS1DEREncodedPublicKey(publicKeyBytes)
    }

    private static func exponent(fromBigEndianBytes bytes: [UInt8]) throws -> UInt32 {
        guard bytes.count <= 4 else {
            throw ADBRSAKeyEncodingError.unsupportedDERInteger
        }

        return bytes.reduce(UInt32(0)) { value, byte in
            (value << 8) | UInt32(byte)
        }
    }

    private static func words(fromLittleEndianBytes bytes: [UInt8]) -> [UInt32] {
        stride(from: 0, to: bytes.count, by: 4).map { offset in
            UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }
    }

    private static func littleEndianBytes(fromWords words: [UInt32]) -> [UInt8] {
        words.flatMap { word in
            [
                UInt8(word & 0xff),
                UInt8((word >> 8) & 0xff),
                UInt8((word >> 16) & 0xff),
                UInt8((word >> 24) & 0xff)
            ]
        }
    }

    private static func negatedModularInverse32(_ word: UInt32) -> UInt32 {
        var inverse = word
        inverse &*= 2 &- word &* inverse
        inverse &*= 2 &- word &* inverse
        inverse &*= 2 &- word &* inverse
        inverse &*= 2 &- word &* inverse
        inverse &*= 2 &- word &* inverse
        return 0 &- inverse
    }

    private static func montgomeryRRWords(modulusWords: [UInt32]) throws -> [UInt32] {
        guard modulusWords.first.map({ $0 & 1 == 1 }) == true else {
            throw ADBRSAKeyEncodingError.evenModulus
        }

        var value = [UInt32](repeating: 0, count: modulusWords.count)
        value[0] = 1

        for _ in 0..<(ADBRSAPublicKeyComponents.adbModulusByteCount * 16) {
            let carry = double(&value)
            if carry > 0 || compare(value, modulusWords) >= 0 {
                value = try subtract(modulusWords, from: value, highCarry: carry)
            }
        }

        return value
    }

    @discardableResult
    private static func double(_ words: inout [UInt32]) -> UInt32 {
        var carry: UInt64 = 0

        for index in words.indices {
            let value = UInt64(words[index]) * 2 + carry
            words[index] = UInt32(truncatingIfNeeded: value)
            carry = value >> 32
        }

        return UInt32(carry)
    }

    private static func compare(_ lhs: [UInt32], _ rhs: [UInt32]) -> Int {
        for index in lhs.indices.reversed() {
            if lhs[index] < rhs[index] {
                return -1
            }

            if lhs[index] > rhs[index] {
                return 1
            }
        }

        return 0
    }

    private static func subtract(
        _ modulus: [UInt32],
        from words: [UInt32],
        highCarry: UInt32 = 0
    ) throws -> [UInt32] {
        var result = [UInt32](repeating: 0, count: words.count)
        var borrow: UInt64 = 0

        for index in words.indices {
            let lhs = UInt64(words[index])
            let rhs = UInt64(modulus[index]) + borrow

            if lhs >= rhs {
                result[index] = UInt32(lhs - rhs)
                borrow = 0
            } else {
                result[index] = UInt32((UInt64(1) << 32) + lhs - rhs)
                borrow = 1
            }
        }

        guard UInt64(highCarry) >= borrow else {
            throw ADBRSAKeyEncodingError.invalidMontgomeryReduction
        }

        return result
    }
}

private struct DERReader {
    private let bytes: [UInt8]
    private var offset: Int

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.offset = 0
    }

    var isAtEnd: Bool {
        offset == bytes.count
    }

    mutating func readSequence() throws -> DERReader {
        let content = try readElement(expectedTag: 0x30)
        return DERReader(content)
    }

    mutating func readInteger() throws -> [UInt8] {
        var integer = try readElement(expectedTag: 0x02)

        guard !integer.isEmpty else {
            throw ADBRSAKeyEncodingError.invalidDER
        }

        while integer.count > 1 && integer.first == 0 {
            integer.removeFirst()
        }

        return integer
    }

    mutating func readBitString() throws -> [UInt8] {
        let bitString = try readElement(expectedTag: 0x03)

        guard bitString.first == 0 else {
            throw ADBRSAKeyEncodingError.invalidDER
        }

        return Array(bitString.dropFirst())
    }

    private mutating func readElement(expectedTag: UInt8) throws -> [UInt8] {
        guard try readByte() == expectedTag else {
            throw ADBRSAKeyEncodingError.invalidDER
        }

        let length = try readLength()
        guard offset + length <= bytes.count else {
            throw ADBRSAKeyEncodingError.invalidDER
        }

        let content = Array(bytes[offset..<(offset + length)])
        offset += length
        return content
    }

    private mutating func readLength() throws -> Int {
        let first = try readByte()

        if first & 0x80 == 0 {
            return Int(first)
        }

        let byteCount = Int(first & 0x7f)
        guard byteCount > 0, byteCount <= 4, offset + byteCount <= bytes.count else {
            throw ADBRSAKeyEncodingError.invalidDER
        }

        var length = 0
        for _ in 0..<byteCount {
            length = (length << 8) | Int(try readByte())
        }
        return length
    }

    private mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else {
            throw ADBRSAKeyEncodingError.invalidDER
        }

        let byte = bytes[offset]
        offset += 1
        return byte
    }
}

private extension Array where Element == UInt8 {
    mutating func appendLittleEndianUInt32(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
