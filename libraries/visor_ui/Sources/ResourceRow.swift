import SwiftUI

/// One thing's use, as a row: its name and kind, then its processors and
/// its memory, each in words and as a bar of what it was given (or of the
/// computer's, where it was given no share). A dash where it does not say.
@MainActor
struct ResourceRow: View {
    let title: String
    /// What it is, at the line's end; nothing for a computer.
    var subtitle: String? = nil
    /// A symbol for what it is, or a lease's platform for its mark.
    var mark: String? = nil
    var platform: String? = nil
    let cpus: Int?
    let cpuPercent: Double?
    let memoryLimit: Int64?
    let memoryUsed: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let platform {
                    LeaseMarks.mark(platform).foregroundStyle(.secondary)
                } else if let mark {
                    Image(systemName: mark).foregroundStyle(.secondary)
                }
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
            }
            meter("CPU", words: cpuWords, share: cpuShare)
            meter("Memory", words: memoryWords, share: memoryShare)
        }
        .padding(.vertical, 2)
    }

    private func meter(_ name: String, words: String, share: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(name).font(.subheadline)
                Spacer()
                Text(words).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let share { ProgressView(value: min(max(share, 0), 1), total: 1) }
        }
    }

    private var cpuWords: String {
        guard let cpuPercent else { return "—" }
        let percent = "\(Int(cpuPercent.rounded()))%"
        return cpus.map { "\(percent) of \($0) cores" } ?? percent
    }

    private var cpuShare: Double? {
        guard let cpuPercent, let cpus, cpus > 0 else { return nil }
        return cpuPercent / Double(cpus * 100)
    }

    private var memoryWords: String {
        guard let memoryUsed else { return "—" }
        return memoryLimit.map { "\(Self.bytes(memoryUsed)) of \(Self.bytes($0))" } ?? Self.bytes(memoryUsed)
    }

    private var memoryShare: Double? {
        guard let memoryUsed, let memoryLimit, memoryLimit > 0 else { return nil }
        return Double(memoryUsed) / Double(memoryLimit)
    }

    /// Bytes in GB to a tenth (MB below one GB), as a person reads them.
    static func bytes(_ count: Int64) -> String {
        let gigabytes = Double(count) / 1_073_741_824
        if gigabytes >= 1 {
            let tenths = (gigabytes * 10).rounded() / 10
            return tenths == tenths.rounded() ? "\(Int(tenths)) GB" : "\(tenths) GB"
        }
        return "\(Int((Double(count) / 1_048_576).rounded())) MB"
    }
}
