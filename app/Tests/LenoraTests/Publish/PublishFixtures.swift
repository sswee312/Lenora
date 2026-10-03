import Foundation
@testable import Lenora

enum PublishFixtures {
    static func state(_ status: JobStatus, roles: [PublishRole] = []) -> JobState {
        let results = roles.map {
            #"{"url":"https://cdn.test/\#($0.rawValue)","contentType":"video/mp4","fileExtension":"mp4","role":"\#($0.rawValue)"}"#
        }
        let resultsJSON = status == .succeeded ? "[" + results.joined(separator: ",") + "]" : "null"
        let json = #"{"jobId":"fake:1","status":"\#(status.rawValue)","results":\#(resultsJSON)}"#
        return try! BackendCoding.decoder().decode(JobState.self, from: Data(json.utf8))
    }

    static func readyRecord(_ options: PublishOptions = PublishOptions(), createdAt: Date = Date(timeIntervalSince1970: 0)) -> Publication {
        var record = Publication(id: UUID(), exportFilename: "cut.mp4", createdAt: createdAt,
                                 model: "cloudinary/publish", durationSeconds: 20, options: options,
                                 assetRef: "a", jobId: "fake:0", status: .processing, outputs: [])
        record.request(options.roles, options: options)
        record.apply(state(.succeeded, roles: options.roles))
        return record
    }
}
