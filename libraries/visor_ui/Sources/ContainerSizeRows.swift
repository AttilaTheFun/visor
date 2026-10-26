import SwiftUI
import VisorProtocol

/// What a container is given, as a row each: processor cores, memory, and
/// the disk its builds keep their output on. The computer gives no more
/// than it has (the server holds a container to that).
@MainActor
struct ContainerSizeRows: View {
    @Binding var size: ContainerSize

    static let cores = [2, 4, 6, 8, 12, 16, 24, 32]
    static let memory: [Int64] = [8, 16, 24, 32, 48, 64, 96, 128, 256]
    static let disk: [Int64] = [64, 128, 256, 512, 1024]

    var body: some View {
        Picker("Processors", selection: $size.cpus) {
            ForEach(Self.choices(Self.cores, with: size.cpus), id: \.self) { Text("\($0) cores").tag($0) }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("container-cpus")
        Picker("Memory", selection: gigabytes(\.memoryBytes)) {
            ForEach(Self.choices(Self.memory, with: size.memoryBytes / ContainerSize.gigabyte), id: \.self) { Text("\($0) GB").tag($0) }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("container-memory")
        Picker("Disk", selection: gigabytes(\.diskBytes)) {
            ForEach(Self.choices(Self.disk, with: size.diskBytes / ContainerSize.gigabyte), id: \.self) { Text(Self.diskWords($0)).tag($0) }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("container-disk")
    }

    /// The offered choices, with what is set now among them.
    static func choices<T: Comparable>(_ offered: [T], with now: T) -> [T] {
        offered.contains(now) ? offered : (offered + [now]).sorted()
    }

    static func diskWords(_ gigabytes: Int64) -> String {
        gigabytes >= 1024 && gigabytes % 1024 == 0 ? "\(gigabytes / 1024) TB" : "\(gigabytes) GB"
    }

    /// A size's bytes, read and set in gigabytes.
    private func gigabytes(_ path: WritableKeyPath<ContainerSize, Int64>) -> Binding<Int64> {
        Binding(get: { size[keyPath: path] / ContainerSize.gigabyte }, set: { size[keyPath: path] = $0 * ContainerSize.gigabyte })
    }

    /// What a heavy build wants, said under the rows.
    static let heavyNote = "6 cores, 16 GB and 128 GB suit most work. A heavy build (a Swift toolchain) wants 16–24 cores, 32–64 GB of memory and 256 GB of disk."
}
