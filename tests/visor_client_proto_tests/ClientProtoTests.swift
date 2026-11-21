// The client link's protos (protos/visor/client/v1): every message the
// calls carry goes through its encoding, binary and JSON, and comes back
// the same.

import Foundation
import SwiftProtobuf
import Testing
import VisorClientProto

@Suite struct ClientProtoTests {
    /// `message` encoded and decoded again, binary and JSON, is `message`.
    private func roundTrip<M: SwiftProtobuf.Message & Equatable>(_ message: M) throws {
        let bytes: Data = try message.serializedBytes()
        #expect(try M(serializedBytes: bytes) == message)
        #expect(try M(jsonString: message.jsonString()) == message)
    }

    @Test func testTheStateAndItsChangesComeBackTheSame() throws {
        var item = Visor_Client_V1_StatusItem()
        item.id = "t1"
        item.kind = .tasks
        item.label = "Tasks"
        item.running = true
        var task = Visor_Client_V1_TaskItem()
        task.title = "Test it"
        task.state = .active
        item.tasks = [task]

        var question = Visor_Client_V1_Question()
        question.question = "Which color?"
        question.header = "Color"
        var red = Visor_Client_V1_Question.Option()
        red.label = "Red"
        red.description_p = "warm"
        question.options = [red]
        question.multiSelect = true
        var approval = Visor_Client_V1_Approval()
        approval.id = "r1"
        approval.tool = "AskUserQuestion"
        approval.summary = "Which color?"
        approval.questions = [question]

        var responding = Visor_Client_V1_Responding()
        responding.id = "M"
        responding.text = "Café au lait 🙂"

        var state = Visor_Client_V1_SessionState()
        state.responding = [responding]
        state.status = [item]
        state.activity = "Bash: ls"
        state.busy = true
        state.approval = approval
        state.queued = ["And then?"]
        state.notice = "Forked elsewhere"
        state.signIn = "https://claude.ai/oauth"
        state.recordRevision = 42
        try roundTrip(state)
        #expect(state.hasApproval)

        // Each change the stream carries.
        var append = Visor_Client_V1_Append()
        append.id = "M"
        append.from = Int64("Café au lait 🙂".utf8.count)
        append.text = ", then"
        var settled = Visor_Client_V1_Settled()
        settled.id = "M"
        settled.recordRevision = 43
        var status = Visor_Client_V1_StatusList()
        status.items = [item]
        var waiting = Visor_Client_V1_ApprovalChange()
        waiting.approval = approval
        var queued = Visor_Client_V1_QueuedList()
        queued.messages = ["Again"]
        let changes: [Visor_Client_V1_SessionChange.OneOf_Change] = [
            .state(state), .append(append), .settled(settled), .status(status), .activity("Read: a.swift"),
            .busy(false), .approval(waiting), .approval(Visor_Client_V1_ApprovalChange()), .notice(""),
            .failure("The agent ended"), .queued(queued),
        ]
        for change in changes {
            var message = Visor_Client_V1_SessionChange()
            message.change = change
            try roundTrip(message)
        }
        // An answered approval is one with none, not an empty one.
        let answered = try Visor_Client_V1_ApprovalChange(serializedBytes: Visor_Client_V1_ApprovalChange().serializedBytes() as Data)
        #expect(!answered.hasApproval)
    }

    @Test func testRowsAndTheServerComeBackTheSame() throws {
        var row = Visor_Client_V1_Row()
        row.id = "M#2"
        row.role = .assistant
        row.text = "All 42 pass."
        row.activities = ["Bash: swift test"]
        row.toolName = ""
        row.images = ["/tmp/shot.png"]
        var size = Visor_Client_V1_ImageSize()
        size.width = 1170
        size.height = 2532
        row.imageSizes = [size]

        var sync = Visor_Client_V1_SyncRequest()
        sync.session = "A"
        sync.revision = 7
        sync.generation = 123_456_789
        sync.after = "u1"
        sync.wait = true
        try roundTrip(sync)
        var synced = Visor_Client_V1_SyncResponse()
        synced.revision = 8
        synced.generation = 123_456_789
        synced.rows = [row]
        synced.follow = ["u1"]
        synced.removed = ["x"]
        synced.later = true
        synced.follows = ""
        try roundTrip(synced)
        #expect(synced.hasFollows, "the thread's first, as against not known")
        var earlier = Visor_Client_V1_EarlierRequest()
        earlier.session = "A"
        earlier.before = "u1"
        try roundTrip(earlier)
        var page = Visor_Client_V1_EarlierResponse()
        page.rows = [row]
        page.more = true
        try roundTrip(page)

        // The server's list: each session as the wire protocol's JSON.
        var session = Visor_Client_V1_Session()
        session.id = "A"
        session.json = Data(#"{"id":"A","agent":"claude","cwd":"/tmp","title":"A","busy":true}"#.utf8)
        var list = Visor_Client_V1_SessionList()
        list.sessions = [session]
        var catalogs = Visor_Client_V1_CatalogList()
        catalogs.catalogs = [Data(#"{"agent":"claude","models":[]}"#.utf8)]
        var account = Visor_Client_V1_AccountChange()
        account.agent = "claude"
        account.json = Data(#"{"plan":"Subscription"}"#.utf8)
        for change in [Visor_Client_V1_ServerUpdate.OneOf_Change.sessions(list), .catalogs(catalogs), .account(account)] {
            var update = Visor_Client_V1_ServerUpdate()
            update.revision = 3
            update.change = change
            try roundTrip(update)
        }
        var watch = Visor_Client_V1_WatchServerRequest()
        watch.revision = 2
        try roundTrip(watch)
    }

    @Test func testTheCommandsComeBackTheSame() throws {
        var send = Visor_Client_V1_SendRequest()
        send.session = "A"
        send.text = "Run the tests"
        send.images = ["/tmp/a.png"]
        try roundTrip(send)
        var approve = Visor_Client_V1_ApproveRequest()
        approve.session = "A"
        approve.id = "r1"
        approve.allow = true
        approve.answers = ["Which color?": "Red, Blue"]
        try roundTrip(approve)
        var interrupt = Visor_Client_V1_InterruptRequest()
        interrupt.session = "A"
        try roundTrip(interrupt)
        var stop = Visor_Client_V1_StopRequest()
        stop.session = "A"
        try roundTrip(stop)
        var answer = Visor_Client_V1_CommandResponse()
        var session = Visor_Client_V1_Session()
        session.id = "A"
        session.json = Data("{}".utf8)
        answer.sessions.sessions = [session]
        try roundTrip(answer)
        var watch = Visor_Client_V1_WatchSessionRequest()
        watch.session = "A"
        try roundTrip(watch)
    }
}
