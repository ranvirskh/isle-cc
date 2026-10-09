import Foundation

public struct ShelfItem: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// Path relative to the shelf directory for copied items; nil for referenced items.
    public var storedRelativePath: String?
    /// Absolute path of the original, for items that are referenced rather than copied.
    public var referencePath: String?
    /// Bookmark so a referenced file is still found after it is moved or renamed.
    public var referenceBookmark: Data?
    public var addedAt: Date
    public var isDirectory: Bool

    public var isReference: Bool { storedRelativePath == nil }
}

/// Persistence for the Shelf.
///
/// Strategy: dropped items are COPIED into Application Support/Isle/Shelf/<id>/<original name>, so they survive
/// the original being moved or deleted and keep their file name when dragged back out. Items larger than
/// `referenceThreshold` are REFERENCED instead (path + bookmark) so a multi-gigabyte file is not duplicated.
public final class ShelfStore {
    public let directory: URL
    public var referenceThreshold: Int64
    public private(set) var items: [ShelfItem] = []
    private let fileManager = FileManager.default
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    public init(directory: URL, referenceThreshold: Int64 = 200 * 1024 * 1024) {
        self.directory = directory
        self.referenceThreshold = referenceThreshold
    }

    // MARK: Loading and saving

    /// Loads the index and drops entries whose file no longer exists. A corrupt index yields an empty shelf.
    @discardableResult
    public func load() -> [ShelfItem] {
        var loaded: [ShelfItem] = []
        if let data = try? Data(contentsOf: indexURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            loaded = (try? decoder.decode([ShelfItem].self, from: data)) ?? []
        }
        let existing = loaded.filter { url(for: $0) != nil }
        items = existing
        if existing.count != loaded.count { save() }
        return items
    }

    private func save() {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(items).write(to: indexURL, options: .atomic)
        } catch {
            // Keep the in-memory shelf; the next successful save catches up.
        }
    }

    // MARK: Resolving

    /// The file to show, drag or open for an item; nil when it has gone missing.
    public func url(for item: ShelfItem) -> URL? {
        if let relative = item.storedRelativePath {
            let url = directory.appendingPathComponent(relative)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }
        if let bookmark = item.referenceBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale),
               fileManager.fileExists(atPath: url.path) {
                return url
            }
        }
        if let path = item.referencePath, fileManager.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // MARK: Mutations

    /// Size of a file or folder in bytes, giving up early once `limit` is passed.
    public func size(of url: URL, limit: Int64) -> Int64 {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let attrs = try? fileManager.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
            if total > limit { break }
        }
        return total
    }

    /// Adds files or folders. Returns the items that were added. Safe to call off the main thread.
    @discardableResult
    public func add(_ urls: [URL], now: Date = Date()) -> [ShelfItem] {
        var added: [ShelfItem] = []
        for source in urls {
            var isDir: ObjCBool = false
            guard source.isFileURL, fileManager.fileExists(atPath: source.path, isDirectory: &isDir) else { continue }
            // Dropping a shelf item back on the shelf is a no-op.
            if source.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/") { continue }
            if items.contains(where: { $0.referencePath == source.path }) { continue }

            let id = UUID().uuidString
            let name = source.lastPathComponent
            var item = ShelfItem(id: id, name: name, storedRelativePath: nil, referencePath: nil,
                                 referenceBookmark: nil, addedAt: now, isDirectory: isDir.boolValue)

            if size(of: source, limit: referenceThreshold) > referenceThreshold {
                item.referencePath = source.path
                item.referenceBookmark = try? source.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            } else {
                let folder = directory.appendingPathComponent(id, isDirectory: true)
                do {
                    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                    try fileManager.copyItem(at: source, to: folder.appendingPathComponent(name))
                    item.storedRelativePath = id + "/" + name
                } catch {
                    try? fileManager.removeItem(at: folder)
                    continue
                }
            }
            items.append(item)
            added.append(item)
        }
        if !added.isEmpty { save() }
        return added
    }

    /// Stores dropped text or a link as a small file so it behaves like any other shelf item.
    @discardableResult
    public func addText(_ text: String, suggestedName: String, fileExtension: String, now: Date = Date()) -> ShelfItem? {
        let id = UUID().uuidString
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        let safeName = suggestedName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let name = (safeName.isEmpty ? "Text" : String(safeName.prefix(60))) + "." + fileExtension
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
        } catch {
            try? fileManager.removeItem(at: folder)
            return nil
        }
        let item = ShelfItem(id: id, name: name, storedRelativePath: id + "/" + name, referencePath: nil,
                             referenceBookmark: nil, addedAt: now, isDirectory: false)
        items.append(item)
        save()
        return item
    }

    public func remove(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for item in items where ids.contains(item.id) {
            deleteStoredCopy(of: item)
        }
        items.removeAll { ids.contains($0.id) }
        save()
    }

    public func clear() {
        remove(ids: Set(items.map(\.id)))
        // Sweep anything left behind by an interrupted copy.
        if let leftovers = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in leftovers where url.lastPathComponent != "index.json" {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// Removes items older than `days`. Returns how many were removed. `days` <= 0 disables auto-clear.
    @discardableResult
    public func purgeExpired(days: Int, now: Date = Date()) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        let expired = Set(items.filter { $0.addedAt < cutoff }.map(\.id))
        remove(ids: expired)
        return expired.count
    }

    /// Only ever deletes inside the shelf directory; referenced originals are never touched.
    private func deleteStoredCopy(of item: ShelfItem) {
        guard item.storedRelativePath != nil else { return }
        let folder = directory.appendingPathComponent(item.id, isDirectory: true)
        guard folder.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/") else { return }
        try? fileManager.removeItem(at: folder)
    }
}
