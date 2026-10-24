import ADBClientCore
import Foundation

// Derived, disposable data; favorites and configuration backups never contain it.
struct ADBTVQuickLaunchIconCache: Sendable {
    let directory: URL
    let maximumEntryCount: Int

    init(directory: URL? = nil, maximumEntryCount: Int = 128) {
        precondition(maximumEntryCount > 0)
        self.directory = directory ?? (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("ADBTV-QuickLaunchIcons", isDirectory: true)
        self.maximumEntryCount = maximumEntryCount
    }

    func load(_ packages: [ADBTVInstalledPackage], deviceID: UUID, userID: Int) -> [String: ADBTVInstalledAppIcon] {
        guard userID >= 0 else { return [:] }
        var icons: [String: ADBTVInstalledAppIcon] = [:]
        for package in packages {
            let url = file(package, deviceID: deviceID, userID: userID)
            if let data = try? readBounded(url),
               (try? ADBTVScreenshot(pngData: data)) != nil,
               let icon = try? ADBTVInstalledAppIcon(pngData: data) {
                icons[package.packageName] = icon
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        return icons
    }

    func save(_ icons: [String: ADBTVInstalledAppIcon], packages: [ADBTVInstalledPackage], deviceID: UUID, userID: Int) {
        guard userID >= 0, !icons.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { prune() }
            for package in packages {
                guard let icon = icons[package.packageName] else { continue }
                guard (try? ADBTVScreenshot(pngData: icon.pngData)) != nil else { continue }
                try icon.pngData.write(to: file(package, deviceID: deviceID, userID: userID), options: .atomic)
            }
        } catch {
            // A cache failure must not erase favorites or a successfully loaded icon.
        }
    }

    func removeDevice(_ deviceID: UUID) {
        for url in files() where url.lastPathComponent.hasPrefix("icon-\(deviceID.uuidString)-") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func file(_ package: ADBTVInstalledPackage, deviceID: UUID, userID: Int) -> URL {
        directory.appendingPathComponent("icon-\(deviceID.uuidString)-\(userID)-\(package.packageName).png")
    }

    private func readBounded(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= ADBTVInstalledAppIcon.maximumPNGByteCount else {
            throw ADBTVQuickLaunchError.invalidArchive
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        while result.count <= ADBTVInstalledAppIcon.maximumPNGByteCount {
            let chunk = try handle.read(upToCount: ADBTVInstalledAppIcon.maximumPNGByteCount + 1 - result.count) ?? Data()
            if chunk.isEmpty { break }
            result.append(chunk)
        }
        guard result.count == size, result.count <= ADBTVInstalledAppIcon.maximumPNGByteCount else {
            throw ADBTVQuickLaunchError.invalidArchive
        }
        return result
    }

    private func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("icon-") && $0.pathExtension == "png" }
    }

    private func prune() {
        let entries: [(url: URL, date: Date)] = files().map { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            return (url, values?.contentModificationDate ?? Date.distantPast)
        }
        let oldestFirst = entries.sorted {
            $0.date == $1.date ? $0.url.lastPathComponent < $1.url.lastPathComponent : $0.date < $1.date
        }
        for entry in oldestFirst.prefix(max(0, entries.count - maximumEntryCount)) {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }
}
