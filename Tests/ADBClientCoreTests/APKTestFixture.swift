func makeTestAPK(entryNames: [String] = ["AndroidManifest.xml"]) -> [UInt8] {
    var localRecords: [UInt8] = []
    var centralRecords: [UInt8] = []

    for entryName in entryNames {
        let fileName = Array(entryName.utf8)
        let localHeaderOffset = UInt32(localRecords.count)

        localRecords.appendTestUInt32(0x0403_4b50)
        localRecords.appendTestUInt16(20)
        localRecords.appendTestUInt16(0)
        localRecords.appendTestUInt16(0)
        localRecords.appendTestUInt16(0)
        localRecords.appendTestUInt16(0)
        localRecords.appendTestUInt32(0)
        localRecords.appendTestUInt32(0)
        localRecords.appendTestUInt32(0)
        localRecords.appendTestUInt16(UInt16(fileName.count))
        localRecords.appendTestUInt16(0)
        localRecords.append(contentsOf: fileName)

        centralRecords.appendTestUInt32(0x0201_4b50)
        centralRecords.appendTestUInt16(20)
        centralRecords.appendTestUInt16(20)
        centralRecords.appendTestUInt16(0)
        centralRecords.appendTestUInt16(0)
        centralRecords.appendTestUInt16(0)
        centralRecords.appendTestUInt16(0)
        centralRecords.appendTestUInt32(0)
        centralRecords.appendTestUInt32(0)
        centralRecords.appendTestUInt32(0)
        centralRecords.appendTestUInt16(UInt16(fileName.count))
        centralRecords.appendTestUInt16(0)
        centralRecords.appendTestUInt16(0)
        centralRecords.appendTestUInt16(0)
        centralRecords.appendTestUInt16(0)
        centralRecords.appendTestUInt32(0)
        centralRecords.appendTestUInt32(localHeaderOffset)
        centralRecords.append(contentsOf: fileName)
    }

    var result = localRecords
    let centralDirectoryOffset = UInt32(result.count)
    result.append(contentsOf: centralRecords)
    result.appendTestUInt32(0x0605_4b50)
    result.appendTestUInt16(0)
    result.appendTestUInt16(0)
    result.appendTestUInt16(UInt16(entryNames.count))
    result.appendTestUInt16(UInt16(entryNames.count))
    result.appendTestUInt32(UInt32(centralRecords.count))
    result.appendTestUInt32(centralDirectoryOffset)
    result.appendTestUInt16(0)
    return result
}

extension Array where Element == UInt8 {
    mutating func appendTestUInt16(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendTestUInt32(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }

    func testUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
