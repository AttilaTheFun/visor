// Sizes as diskutil takes them and as people read them.

import Foundation

/// Sizes in bytes: given to diskutil exactly, shown in decimal gigabytes as
/// the Finder shows them.
public enum ByteSize {
    /// A decimal gigabyte, as diskutil's `g` and the Finder count one.
    public static let gigabyte: Int64 = 1_000_000_000

    /// A size as diskutil's `-reserve` and `-quota` take it exactly:
    /// `<bytes>b` (its `g` is decimal and rounds to the block).
    public static func argument(_ bytes: Int64) -> String { "\(bytes)b" }

    /// Whole or fractional gigabytes for a person: "200 GB", "1.5 GB",
    /// "512 MB" below one.
    public static func describe(_ bytes: Int64) -> String {
        if bytes < gigabyte {
            return "\(bytes / 1_000_000) MB"
        }
        let tenths = (bytes * 10 + gigabyte / 2) / gigabyte
        return tenths % 10 == 0 ? "\(tenths / 10) GB" : "\(tenths / 10).\(tenths % 10) GB"
    }

    /// Gigabytes a person typed ("200", "1.5", "" for none) in bytes; nil
    /// if it isn't a size.
    public static func gigabytes(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return 0 }
        guard let value = Double(trimmed), value >= 0, value.isFinite, value < 1_000_000 else { return nil }
        return Int64((value * Double(gigabyte)).rounded())
    }
}
