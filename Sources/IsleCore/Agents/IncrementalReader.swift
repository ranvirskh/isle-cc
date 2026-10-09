import Foundation

/// Where reading of one log file stopped. Persisted so nothing is ever read twice.
public struct FileCursor: Codable, Equatable {
    public var offset: UInt64
    /// File identity; a different inode at the same path means the file was rotated.
    public var inode: UInt64
    public var context: FileContext

    public init(offset: UInt64 = 0, inode: UInt64 = 0, context: FileContext = FileContext()) {
        self.offset = offset
        self.inode = inode
        self.context = context
    }
}

public enum IncrementalReader {
    public enum Outcome: Equatable {
        case missing
        case unchanged
        /// Bytes consumed, and whether the cursor had to restart from zero (rotation or truncation).
        case read(bytes: Int, restarted: Bool)
    }

    /// Hands every COMPLETE new line since the cursor to `handler`, then advances the cursor.
    /// A partially written last line (no trailing newline yet) is left for the next call.
    /// Lines are passed as raw bytes and are not retained.
    @discardableResult
    public static func readNewLines(path: String, cursor: inout FileCursor, chunkSize: Int = 1 << 20,
                                    handler: (Data, inout FileContext) -> Void) -> Outcome {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return .missing }
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0

        var restarted = false
        if (cursor.inode != 0 && inode != 0 && inode != cursor.inode) || size < cursor.offset {
            // Rotated (new file at the same path) or truncated: start over with a clean parser context.
            cursor = FileCursor(offset: 0, inode: inode)
            restarted = true
        }
        cursor.inode = inode
        guard size > cursor.offset else { return restarted ? .read(bytes: 0, restarted: true) : .unchanged }

        guard let handle = FileHandle(forReadingAtPath: path) else { return .missing }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: cursor.offset)
        } catch {
            return .missing
        }

        var carry = Data()
        var consumed = 0
        let newline = UInt8(ascii: "\n")
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                break
            }
            if chunk.isEmpty { break }
            carry.append(chunk)
            guard let lastNewline = carry.lastIndex(of: newline) else { continue }
            let complete = carry[carry.startIndex...lastNewline]
            for line in complete.split(separator: newline, omittingEmptySubsequences: true) {
                handler(Data(line), &cursor.context)
            }
            consumed += complete.count
            carry = Data(carry[carry.index(after: lastNewline)...])
        }
        cursor.offset += UInt64(consumed)
        return .read(bytes: consumed, restarted: restarted)
    }
}
