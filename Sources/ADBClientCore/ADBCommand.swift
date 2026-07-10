public enum ADBCommand: UInt32, CaseIterable, Sendable {
    case connect = 0x4e58_4e43
    case auth = 0x4854_5541
    case secureTLS = 0x534c_5453
    case open = 0x4e45_504f
    case okay = 0x5941_4b4f
    case close = 0x4553_4c43
    case write = 0x4554_5257

    public var wireName: String {
        let bytes = [
            UInt8(rawValue & 0xff),
            UInt8((rawValue >> 8) & 0xff),
            UInt8((rawValue >> 16) & 0xff),
            UInt8((rawValue >> 24) & 0xff)
        ]

        return String(decoding: bytes, as: UTF8.self)
    }
}
