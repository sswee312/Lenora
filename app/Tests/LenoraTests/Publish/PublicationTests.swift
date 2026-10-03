import AVFoundation
import Foundation
import Testing
@testable import Lenora

struct PublicationTests {
    static let limits = PublishLimits(verticalAspects: ["9:16", "1:1", "4:5"], teaserSeconds: .init(min: 5, max: 30))
    static let tenSeconds = PublishProbe(byteCount: 1_000_000, durationSeconds: 10)

    static func record(_ options: PublishOptions = PublishOptions()) -> Publication {
        var record = Publication(id: UUID(), exportFilename: "cut.mp4", createdAt: Date(timeIntervalSince1970: 0),
                                 model: "cloudinary/publish", durationSeconds: 10, options: options, status: .uploading, outputs: [])
        record.request(options.roles, options: options)
        return record
    }

    static func state(_ json: String) throws -> JobState {
        try BackendCoding.decoder().decode(JobState.self, from: Data(json.utf8))
    }

    @Test func limitsComeFromTheModelUI() throws {
        let caps = try BackendCoding.decoder().decode(BackendCapabilities.self, from: ProtocolFixtures.data("Capabilities.cloudinaryFull"))
        let model = try #require(caps.models.first { $0.kind == "video.publish" })
        #expect(PublishLimits(model: model) == Self.limits)
        #expect(caps.models.filter { $0.kind != "video.publish" }.allSatisfy { PublishLimits(model: $0) == nil })
    }

    @Test func invertedTeaserRangeMakesPublishingUnavailable() throws {
        let text = String(decoding: try ProtocolFixtures.data("Capabilities.cloudinaryFull"), as: UTF8.self)
            .replacingOccurrences(of: "\"min\": 5", with: "\"min\": 40")
        let caps = try BackendCoding.decoder().decode(BackendCapabilities.self, from: Data(text.utf8))
        let model = try #require(caps.models.first { $0.kind == "video.publish" })
        #expect(PublishLimits(model: model) == nil)
    }

    @Test(arguments: [
        (PublishOptions(), PublishProbe(byteCount: 104_857_600, durationSeconds: 10), nil),
        (PublishOptions(), PublishProbe(byteCount: 104_857_601, durationSeconds: 10), PublishRefusal.tooLarge(byteCount: 104_857_601, maxBytes: 104_857_600)),
        (PublishOptions(), PublishProbe(byteCount: 1, durationSeconds: .nan), .unreadable),
        (PublishOptions(), PublishProbe(byteCount: 1, durationSeconds: 0), .unreadable),
        (PublishOptions(vertical: "16:9"), tenSeconds, .unsupportedAspect("16:9", allowed: ["9:16", "1:1", "4:5"])),
        (PublishOptions(vertical: "9:16"), tenSeconds, nil),
        (PublishOptions(teaserSeconds: 4), tenSeconds, .teaserOutOfRange(4, min: 5, max: 30)),
        (PublishOptions(teaserSeconds: 31), PublishProbe(byteCount: 1, durationSeconds: 60), .teaserOutOfRange(31, min: 5, max: 30)),
        (PublishOptions(teaserSeconds: 10), tenSeconds, .teaserTooLong(10, longest: 9)),
        (PublishOptions(teaserSeconds: 5), PublishProbe(byteCount: 1, durationSeconds: 5), .teaserTooLong(5, longest: nil)),
        (PublishOptions(teaserSeconds: 10), PublishProbe(byteCount: 1, durationSeconds: 10.5), nil),
        (PublishOptions(teaserSeconds: 9), tenSeconds, nil),
    ] as [(PublishOptions, PublishProbe, PublishRefusal?)])
    func limitsRefuseImpossibleRequests(options: PublishOptions, probe: PublishProbe, expected: PublishRefusal?) {
        #expect(Self.limits.refusal(for: options, probe: probe, maxBytes: 104_857_600) == expected)
    }

    @Test func missingLimitsRefuseThatOutput() {
        let none = PublishLimits(verticalAspects: nil, teaserSeconds: nil)
        #expect(none.refusal(for: PublishOptions(teaserSeconds: 5), probe: Self.tenSeconds, maxBytes: nil) == .teaserUnsupported)
        #expect(none.refusal(for: PublishOptions(vertical: "9:16"), probe: Self.tenSeconds, maxBytes: nil) == .unsupportedAspect("9:16", allowed: []))
    }

    @Test func partialStateMarksTheFailedOutput() throws {
        var record = Self.record(PublishOptions(vertical: "9:16", teaserSeconds: 15))
        record.apply(try BackendCoding.decoder().decode(JobState.self, from: ProtocolFixtures.data("JobState.publishPartial")))
        #expect(record.status == .partial)
        #expect(record.outputs.map(\.role) == PublishRole.allCases)
        #expect(record.outputs.filter { $0.status == .ready }.count == 4)
        let teaser = try #require(record.outputs.first { $0.role == .teaser })
        #expect(teaser.status == .failed && teaser.errorCode == "provider_error" && teaser.url == nil)
    }

    @Test func runningStateKeepsOutputsPending() throws {
        var record = Self.record()
        record.apply(try Self.state(#"{"jobId":"j","status":"running"}"#))
        #expect(record.status == .processing)
        #expect(record.outputs.allSatisfy { $0.status == .pending })
    }

    @Test func failedJobFailsEveryPendingOutput() throws {
        var record = Self.record()
        record.apply(try Self.state(#"{"jobId":"j","status":"failed","error":{"code":"provider_error","message":"Stream failed.","retryable":false}}"#))
        #expect(record.status == .failed && record.failure == PublishFailure(code: "provider_error", message: "Stream failed."))
        #expect(record.outputs.allSatisfy { $0.status == .failed && $0.errorCode == "provider_error" })
    }

    @Test func succeededWithAMissingRoleIsPartial() throws {
        var record = Self.record()
        record.apply(try Self.state(#"{"jobId":"j","status":"succeeded","results":[{"url":"https://x.test/s.m3u8","contentType":"application/vnd.apple.mpegurl","fileExtension":"m3u8","role":"stream"}]}"#))
        #expect(record.status == .partial)
        #expect(record.outputs.first { $0.role == .poster }?.status == .failed)
    }

    @Test func onlyMissingOrChangedOutputsAreRequestedAgain() throws {
        var record = Self.record(PublishOptions(vertical: "9:16"))
        record.apply(try BackendCoding.decoder().decode(JobState.self, from: ProtocolFixtures.data("JobState.publishPartial")))
        #expect(record.rolesToRequest(for: record.options) == [])
        #expect(record.rolesToRequest(for: record.options.merging(PublishOptions(teaserSeconds: 15))) == [.teaser])
        #expect(record.rolesToRequest(for: record.options.merging(PublishOptions(vertical: "1:1"))) == [.vertical])
    }

    @Test func unpublishingDropsEveryURL() throws {
        var record = Self.record()
        record.apply(try BackendCoding.decoder().decode(JobState.self, from: ProtocolFixtures.data("JobState.publishPartial")))
        record.markUnpublished()
        #expect(record.status == .unpublished && record.outputs.allSatisfy { $0.url == nil })
    }

    @Test(arguments: [("mp4", "video/mp4"), ("MOV", "video/quicktime"), ("fcpxml", nil), ("xml", nil)] as [(String, String?)])
    func onlyVideoExportsHaveAContentType(fileExtension: String, expected: String?) {
        let job = ExportJob(id: UUID(), projectID: "p", filename: "cut.\(fileExtension)", source: .manual,
                            outputURL: URL(fileURLWithPath: "/tmp/cut.\(fileExtension)"), createdAt: Date(),
                            status: .completed, progress: 1, error: nil, warnings: [], lenoraReport: nil)
        #expect(job.videoContentType == expected)
    }

    @Test func projectFileRoundTripsPublications() throws {
        var file = ProjectFile(timelines: [Timeline()])
        file.publications = [Self.record(PublishOptions(teaserSeconds: 5))]
        let decoded = try ProjectFile.decode(JSONEncoder().encode(file))
        #expect(decoded.publications == file.publications)
    }

    @Test func projectFileWithoutPublicationsStillDecodes() throws {
        let decoded = try ProjectFile.decode(JSONEncoder().encode(ProjectFile(timelines: [Timeline()])))
        #expect(decoded.publications == nil)
    }
}

@MainActor
struct PublishFailureTests {
    @Test(arguments: [
        (BackendError.unreachable(URL(string: "http://127.0.0.1:1")!), "backend_unreachable"),
        (.unauthorized, "unauthorized"),
        (.problem(BackendProblem(code: "rate_limited", detail: "Slow down.", status: 429, retryable: true)), "rate_limited"),
        (.invalidResponse(status: 502), "invalid_response"),
        (.uploadFailed(status: 500), "upload_failed"),
        (.uploadUnreachable, "upload_unreachable"),
    ])
    func backendErrorsKeepAStableCode(error: BackendError, code: String) {
        #expect(PublishFailure(error).code == code)
    }

    @Test func otherErrorsAreInternal() {
        #expect(PublishFailure(CocoaError(.fileReadUnknown)).code == "internal_error")
    }

    @Test func knownCodesRenderLocalizedCopyNotTheStoredText() {
        #expect(PublishFailure(code: "upload_interrupted", message: "stored").userMessage == L10n.string("Upload interrupted."))
        #expect(PublishFailure(code: "backend_unreachable", message: "stored").userMessage == L10n.string("Can't reach the backend."))
    }

    @Test func aBareCodeShowsTheGenericFailure() {
        #expect(PublishFailure(code: "rate_limited", message: "rate_limited").userMessage == L10n.string("Publishing failed."))
    }

    @Test func unknownCodesShowTheBackendTextVerbatim() {
        #expect(PublishFailure(code: "rate_limited", message: "Slow down.").userMessage == "Slow down.")
    }
}

@MainActor
struct PublishRefusalTests {
    @Test(arguments: [
        (PublishRefusal.unavailable, "unavailable"),
        (.notConfirmed, "invalid_request"),
        (.exportNotPublishable, "invalid_request"),
        (.unreadable, "invalid_request"),
        (.tooLarge(byteCount: 2, maxBytes: 1), "input_too_large"),
        (.unsupportedAspect("16:9", allowed: ["9:16"]), "invalid_request"),
        (.teaserUnsupported, "invalid_request"),
        (.teaserOutOfRange(4, min: 5, max: 30), "invalid_request"),
        (.teaserTooLong(10, longest: 9), "invalid_request"),
        (.notFound, "not_found"),
        (.busy, "invalid_request"),
        (.notUploaded, "invalid_request"),
        (.unpublished, "invalid_request"),
    ])
    func refusalsMapToStableCodes(refusal: PublishRefusal, code: String) {
        #expect(refusal.code == code)
        #expect(!refusal.message.isEmpty && !refusal.userMessage.isEmpty)
    }

    @Test func agentMessagesNameTheLimits() {
        #expect(PublishRefusal.tooLarge(byteCount: 2_000, maxBytes: 1_000).message == "The export is 2000 bytes; publishing accepts up to 1000 bytes.")
        #expect(PublishRefusal.unsupportedAspect("16:9", allowed: ["9:16", "1:1"]).message == "Vertical aspect 16:9 isn't supported. Allowed: 9:16, 1:1.")
    }

    @Test func unsupportedAspectNamesTheAllowedAspects() {
        let text = PublishRefusal.unsupportedAspect("16:9", allowed: ["9:16", "1:1"]).userMessage
        #expect(text.contains("16:9") && text.contains("9:16") && text.contains("1:1"))
    }

    @Test(arguments: [(10.0, 9), (10.5, 10), (5.0, nil), (1e300, 30)] as [(Double, Int?)])
    func longestTeaserFitsInsideTheVideoAndRange(durationSeconds: Double, longest: Int?) {
        #expect(PublicationTests.limits.longestTeaser(for: durationSeconds) == longest)
    }

    @Test func teaserTooLongNamesTheLongestAllowedTeaser() {
        let text = PublishRefusal.teaserTooLong(10, longest: 9).userMessage
        #expect(text.contains(9.secondsText(locale: AppLocalization.shared.activeLocale)))
    }

    @Test func teaserTooLongSaysWhenNoTeaserFits() {
        #expect(PublishRefusal.teaserTooLong(5, longest: nil).userMessage == L10n.string("This video is too short for a teaser."))
    }

    @Test(arguments: [(1, "1 second"), (15, "15 seconds")])
    func secondsTextIsPluralized(seconds: Int, expected: String) {
        #expect(seconds.secondsText(locale: Locale(identifier: "en_US")) == expected)
    }
}

struct PublishProbeTests {
    @Test(arguments: [CMTime.invalid, .indefinite, .positiveInfinity, .zero, CMTime(value: -1, timescale: 1)])
    func unusableDurationsAreUnreadable(_ duration: CMTime) {
        #expect(throws: PublishRefusal.unreadable) { try PublishProbe.seconds(of: duration) }
    }

    @Test func numericDurationIsInSeconds() throws {
        #expect(try PublishProbe.seconds(of: CMTime(value: 5, timescale: 2)) == 2.5)
    }

    @Test func readsSizeAndDurationOfARealVideo() async throws {
        let url = try await FixtureVideo.write(scenes: [.init(rgb: (0, 0, 0), seconds: 2)])
        defer { try? FileManager.default.removeItem(at: url) }
        let size = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let probe = try await PublishProbe.read(url)
        #expect(probe.byteCount == Int64(size) && probe.byteCount > 0)
        #expect(abs(probe.durationSeconds - 2) < 0.5)
    }

    @Test func unknownFileSizeIsUnreadable() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: PublishRefusal.unreadable) { try await PublishProbe.read(directory) }
    }
}
