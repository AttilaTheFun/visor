// A runner's job as the dispatcher keeps it on disk (JobQueue+Store): the
// fields this server sets on a job, so a server that restarts gives its
// runners the jobs they hold, and its moved sessions' agents find their
// sessions.

import AgentProtocol
import Foundation

struct StoredJob: Codable, Equatable {
    var uuid: String
    var dispatcherURL: String
    var harness: String
    var title: String
    var workingDirectory: String
    var model: String
    var effort: String
    var prompt: String
    var driverURL: String
    var resumeSessionID: String
    var sources: [Source]
    var labels: [String]

    struct Source: Codable, Equatable {
        var repository: String
        var ref: String
        var name: String
    }

    init(_ job: AgentProtocol_V1_Job) {
        uuid = job.agent.uuid
        dispatcherURL = job.agent.dispatcherURL
        harness = job.harness
        title = job.title
        workingDirectory = job.workingDirectory
        model = job.model
        effort = job.effort
        prompt = job.prompt
        driverURL = job.driverURL
        resumeSessionID = job.resumeSessionID
        sources = job.sources.map { Source(repository: $0.repository, ref: $0.ref, name: $0.name) }
        labels = job.labels
    }

    var job: AgentProtocol_V1_Job {
        var job = AgentProtocol_V1_Job()
        job.agent.uuid = uuid
        job.agent.dispatcherURL = dispatcherURL
        job.harness = harness
        job.title = title
        job.workingDirectory = workingDirectory
        job.model = model
        job.effort = effort
        job.prompt = prompt
        job.driverURL = driverURL
        job.resumeSessionID = resumeSessionID
        job.sources = sources.map { source in .with { $0.repository = source.repository; $0.ref = source.ref; $0.name = source.name } }
        job.labels = labels
        return job
    }
}
