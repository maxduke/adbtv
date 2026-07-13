enum ADBPayload {
    static func nullTerminatedUTF8(_ value: String) -> [UInt8] {
        Array(value.utf8) + [0]
    }

    static func stringFromNullTerminatedUTF8(_ bytes: [UInt8]) -> String {
        let content = bytes.prefix { byte in
            byte != 0
        }

        return String(decoding: content, as: UTF8.self)
    }
}
