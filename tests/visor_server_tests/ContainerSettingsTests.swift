// The Sessions container's settings (ServerSettings.container): off by
// default, read field by field, an image override that is a digest or
// nothing, and the CPUs and memory it starts with.

import Foundation
@testable import VisorServer
import Testing

@Suite struct ContainerSettingsTests {
    private static let gib: UInt64 = 1 << 30
    private static let digest = "sha256:" + String(repeating: "0123456789abcdef", count: 4)

    private func decoded(_ json: String) throws -> ServerSettings {
        try JSONDecoder().decode(ServerSettings.self, from: Data(json.utf8))
    }

    @Test func noneIsOff() throws {
        #expect(ServerSettings().container == nil)
        #expect(try decoded("{}").container == nil)
        let defaults = try #require(try decoded(#"{"container":{}}"#).container)
        #expect(!defaults.enabled && defaults.cpus == nil && defaults.memoryGiB == nil && defaults.imageDigest == nil)
        #expect(defaults.idleMinutes == 30)
    }

    @Test func itsFieldsAreRead() throws {
        let json = #"{"container":{"enabled":true,"cpus":6,"memoryGiB":12,"idleMinutes":45,"imageDigest":"\#(Self.digest)"}}"#
        let container = try #require(try decoded(json).container)
        #expect(container.enabled && container.cpus == 6 && container.memoryGiB == 12 && container.idleMinutes == 45)
        #expect(container.imageDigest == Self.digest)
        // And written back as read.
        var settings = ServerSettings()
        settings.container = container
        #expect(try JSONDecoder().decode(ServerSettings.self, from: JSONEncoder().encode(settings)).container == container)
    }

    @Test func whatIsntAFieldsValueReadsAsItsDefault() throws {
        let json = #"{"lan":true,"container":{"enabled":"yes","cpus":0,"memoryGiB":-2,"idleMinutes":0,"imageDigest":"ghcr.io/attilathefun/visor-agent:latest"}}"#
        let settings = try decoded(json)
        #expect(settings.lan, "the rest of the file still read")
        let container = try #require(settings.container)
        #expect(!container.enabled && container.cpus == nil && container.memoryGiB == nil && container.idleMinutes == 30)
        #expect(container.imageDigest == nil, "a tag is never an override")
        #expect(try decoded(#"{"lan":true,"container":7}"#).container == nil)
        #expect(try decoded(#"{"lan":true,"container":7}"#).lan)
    }

    @Test func theOverrideIsADigestAlone() {
        #expect(ContainerSettings.isImageDigest(Self.digest))
        #expect(!ContainerSettings.isImageDigest(Self.digest.uppercased()))
        #expect(!ContainerSettings.isImageDigest(String(Self.digest.dropLast())))
        #expect(!ContainerSettings.isImageDigest("ghcr.io/attilathefun/visor-agent@" + Self.digest))
    }

    @Test func theDefaultMemoryIsHalfWhatsFreeWithinFourAndTwentyFour() {
        // The Mini: 32 GB, 20 free: 10.
        #expect(ContainerSettings.defaultMemoryGiB(availableBytes: 20 * Self.gib, physicalBytes: 32 * Self.gib) == 10)
        // Much free: no more than 24.
        #expect(ContainerSettings.defaultMemoryGiB(availableBytes: 100 * Self.gib, physicalBytes: 128 * Self.gib) == 24)
        // Little free: at least 4.
        #expect(ContainerSettings.defaultMemoryGiB(availableBytes: 3 * Self.gib, physicalBytes: 16 * Self.gib) == 4)
        // Unknown: half of all of it.
        #expect(ContainerSettings.defaultMemoryGiB(availableBytes: nil, physicalBytes: 16 * Self.gib) == 8)
        // Never more than all of it less 4 GiB.
        #expect(ContainerSettings.defaultMemoryGiB(availableBytes: 8 * Self.gib, physicalBytes: 6 * Self.gib) == 2)
    }

    @Test func theCPUsAndMemoryItStartsWith() {
        var container = ContainerSettings()
        #expect(container.resolvedCPUs(cores: 10) == 8)
        #expect(container.resolvedCPUs(cores: 4) == 2)
        #expect(container.resolvedMemoryGiB(availableBytes: 20 * Self.gib, physicalBytes: 32 * Self.gib) == 10)
        container.cpus = 64
        container.memoryGiB = 64
        #expect(container.resolvedCPUs(cores: 10) == 10)
        #expect(container.resolvedMemoryGiB(availableBytes: 20 * Self.gib, physicalBytes: 32 * Self.gib) == 28)
        container.memoryGiB = 16
        #expect(container.resolvedMemoryGiB(availableBytes: 2 * Self.gib, physicalBytes: 32 * Self.gib) == 16, "a setting is taken as set")
    }
}
