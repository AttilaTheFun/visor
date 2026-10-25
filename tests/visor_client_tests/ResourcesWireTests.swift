// What a computer is using, as the wire carries it: every field there and
// back, and the ones a server leaves out left out.

import VisorProtocol
import XCTest

final class ResourcesWireTests: XCTestCase {
    func testResourcesCrossTheWireWhole() throws {
        var answer = Envelope(type: "resources")
        answer.resources = ServerResources(
            sampledAt: 1_790_000_000.5,
            host: ComputerUsage(name: "Mac", cpus: 10, cpuPercent: 230.5, memoryBytes: 34_359_738_368, memoryUsedBytes: 19_864_223_744),
            containers: [ContainerUsage(id: "visor-a", session: "a", cpus: 10, cpuPercent: 85, memoryLimitBytes: 8_589_934_592, memoryUsedBytes: 2_254_857_830)],
            machines: [LeaseUsage(id: "lease-ios", platform: "ios", config: "iphone", session: "a", cpuPercent: 40, memoryBytes: 1_717_986_918)],
            machinesHost: ComputerUsage(cpus: 16, memoryBytes: 68_719_476_736),
            machinesNote: "oss does not say yet")
        let read = try XCTUnwrap(Envelope.decode(answer.encoded())?.resources)
        XCTAssertEqual(read, answer.resources)
        XCTAssertNil(read.machines.first?.cpus, "a simulator is given no cores, and says none")
    }
}
