// The services' servers (VisorClientGRPCServer), named as the protos name
// them. A file of their own: the clients' module names the same services,
// and one file can't import both.

import GRPCCore
import Testing
import VisorClientGRPCServer

@Suite struct ServicesServerTests {
    @Test func testTheServersAreNamedAsTheProtosSay() {
        #expect(Visor_Client_V1_Server.descriptor.fullyQualifiedService == "visor.client.v1.Server")
        #expect(Visor_Client_V1_Server.Method.Watch.descriptor.fullyQualifiedMethod == "visor.client.v1.Server/Watch")
        #expect(Visor_Client_V1_Sessions.Method.descriptors.map(\.method) == ["Watch", "Sync", "Earlier", "Send", "Approve", "Interrupt", "Stop"])
        // What a server of each implements.
        #expect(name((any Visor_Client_V1_Server.SimpleServiceProtocol).self).hasSuffix("SimpleServiceProtocol"))
        #expect(name((any Visor_Client_V1_Sessions.SimpleServiceProtocol).self).hasSuffix("SimpleServiceProtocol"))
    }

    private func name<T>(_ type: T.Type) -> String { String(describing: type) }
}
