func makeADBTVTestAPK() -> [UInt8] {
    let fileName = Array("AndroidManifest.xml".utf8)
    var localRecord: [UInt8] = []
    localRecord.appendADBTVTestUInt32(0x0403_4b50)
    localRecord.appendADBTVTestUInt16(20)
    localRecord.appendADBTVTestUInt16(0)
    localRecord.appendADBTVTestUInt16(0)
    localRecord.appendADBTVTestUInt16(0)
    localRecord.appendADBTVTestUInt16(0)
    localRecord.appendADBTVTestUInt32(0)
    localRecord.appendADBTVTestUInt32(0)
    localRecord.appendADBTVTestUInt32(0)
    localRecord.appendADBTVTestUInt16(UInt16(fileName.count))
    localRecord.appendADBTVTestUInt16(0)
    localRecord.append(contentsOf: fileName)

    var centralRecord: [UInt8] = []
    centralRecord.appendADBTVTestUInt32(0x0201_4b50)
    centralRecord.appendADBTVTestUInt16(20)
    centralRecord.appendADBTVTestUInt16(20)
    centralRecord.appendADBTVTestUInt16(0)
    centralRecord.appendADBTVTestUInt16(0)
    centralRecord.appendADBTVTestUInt16(0)
    centralRecord.appendADBTVTestUInt16(0)
    centralRecord.appendADBTVTestUInt32(0)
    centralRecord.appendADBTVTestUInt32(0)
    centralRecord.appendADBTVTestUInt32(0)
    centralRecord.appendADBTVTestUInt16(UInt16(fileName.count))
    centralRecord.appendADBTVTestUInt16(0)
    centralRecord.appendADBTVTestUInt16(0)
    centralRecord.appendADBTVTestUInt16(0)
    centralRecord.appendADBTVTestUInt16(0)
    centralRecord.appendADBTVTestUInt32(0)
    centralRecord.appendADBTVTestUInt32(0)
    centralRecord.append(contentsOf: fileName)

    var result = localRecord
    let centralDirectoryOffset = UInt32(result.count)
    result.append(contentsOf: centralRecord)
    result.appendADBTVTestUInt32(0x0605_4b50)
    result.appendADBTVTestUInt16(0)
    result.appendADBTVTestUInt16(0)
    result.appendADBTVTestUInt16(1)
    result.appendADBTVTestUInt16(1)
    result.appendADBTVTestUInt32(UInt32(centralRecord.count))
    result.appendADBTVTestUInt32(centralDirectoryOffset)
    result.appendADBTVTestUInt16(0)
    return result
}

private extension Array where Element == UInt8 {
    mutating func appendADBTVTestUInt16(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendADBTVTestUInt32(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
