// The REST side of the relay and of enrolling: a client's report and what
// it is to carry (`POST /api/relay`), a message it carries here
// (`/api/relay/deliver`), what became of one it carried from here
// (`/api/relay/receipt`), and the connection codes a client shows to add
// this server elsewhere (`GET /api/codes`).

import Foundation
import VisorProtocol

extension VisorServer {
    /// A client's report (`report`): kept, and answered with the messages
    /// waiting for the servers it reports (`relayed`).
    func restRelay(_ call: RESTCall) -> HTTPResponse {
        guard let report = call.body.report else { return HTTPResponse(400, Envelope.error("A report is required").encoded()) }
        takeReport(report)
        var e = Envelope(type: "relay")
        e.relayed = relayedMessages(for: report)
        return .json(e.encoded())
    }

    /// A message carried here (the one in `relayed`): what became of it
    /// (`receipt`), the same however often it is carried.
    func restRelayDeliver(_ call: RESTCall) -> HTTPResponse {
        guard let message = call.body.relayed?.first else { return HTTPResponse(400, Envelope.error("A message is required").encoded()) }
        guard let receipt = takeRelayed(message) else {
            return HTTPResponse(409, Envelope.error("That message is for another server").encoded())
        }
        var e = Envelope(type: "relay")
        e.receipt = receipt
        return .json(e.encoded())
    }

    /// What became of a message from here where it went (`receipt`).
    func restRelayReceipt(_ call: RESTCall) -> HTTPResponse {
        guard let receipt = call.body.receipt else { return HTTPResponse(400, Envelope.error("A receipt is required").encoded()) }
        takeReceipt(receipt)
        return .json(Envelope(type: "relay").encoded())
    }

    /// The connection codes, as the menu bar app shows them: the QR
    /// code's, and one leading with each kind of path.
    func restCodes(_ call: RESTCall) -> HTTPResponse {
        guard let codes = connectionCodes else { return HTTPResponse(503, Envelope.error("No connection code yet").encoded()) }
        var e = Envelope(type: "codes")
        e.codes = codes
        return .json(e.encoded())
    }
}
