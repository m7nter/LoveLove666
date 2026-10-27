import XCTest
@testable import SecureVault

final class OSMPBFDownloadTests: XCTestCase {
    private let url = URL(string: "https://pbf-fixture.invalid/region.osm.pbf")!
    private func response(_ status: Int = 200, _ headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
    private var validator: OSMPBFDownloadPolicy.Validator {
        .init(sourceURL: url, response: response(200, ["ETag": "\"revision-1\""]))
    }

    func testLegacyPartialWithoutValidatorRestartsRatherThanMixingRevisions() {
        XCTAssertEqual(OSMPBFDownloadPolicy.resumeOffset(partialBytes: 100, sourceURL: url, validator: nil), 0)
        XCTAssertEqual(OSMPBFDownloadPolicy.resumeOffset(partialBytes: 100, sourceURL: url, validator: validator), 100)
        XCTAssertEqual(OSMPBFDownloadPolicy.resumeOffset(partialBytes: 100,
                         sourceURL: URL(string: "https://pbf-fixture.invalid/other.pbf")!, validator: validator), 0)
    }

    func testWeakETagNeedsLastModifiedBeforeResuming() {
        let weak = OSMPBFDownloadPolicy.Validator(sourceURL: url, response: response(200, ["ETag": "W/\"revision-1\""]))
        XCTAssertNil(weak.ifRange)
        let date = "Mon, 26 Oct 2026 10:00:00 GMT"
        let dated = OSMPBFDownloadPolicy.Validator(sourceURL: url, response: response(200, ["ETag": "W/\"revision-1\"", "Last-Modified": date]))
        XCTAssertEqual(dated.ifRange, date)
    }

    func testMatchingPartialResponseAppendsOnlyAtRequestedOffset() throws {
        let plan = try OSMPBFDownloadPolicy.responsePlan(response(206,
            ["Content-Range": "bytes 100-199/200", "Content-Length": "100", "ETag": "\"revision-1\""]),
            requestedOffset: 100, requestedValidator: validator)
        XCTAssertTrue(plan.append)
        XCTAssertEqual(plan.totalBytes, 200)
    }

    func testNewFullRevisionReplacesOldPartial() throws {
        let plan = try OSMPBFDownloadPolicy.responsePlan(response(200,
            ["Content-Length": "300", "ETag": "\"revision-2\""]), requestedOffset: 100, requestedValidator: validator)
        XCTAssertFalse(plan.append)
        XCTAssertEqual(plan.totalBytes, 300)
    }

    func testMismatchedRangeAndRevisionCannotBeAppended() {
        let headers = [
            ["Content-Range": "bytes 0-99/200", "ETag": "\"revision-1\""],
            ["Content-Range": "bytes 100-199/200", "ETag": "\"revision-2\""],
            ["Content-Range": "bytes 100-200/200", "ETag": "\"revision-1\""],
            ["Content-Range": "bytes 100-199/*", "ETag": "\"revision-1\""],
            ["Content-Range": "bytes 100-199/200", "Content-Length": "90", "ETag": "\"revision-1\""]
        ]
        for header in headers {
            XCTAssertThrowsError(try OSMPBFDownloadPolicy.responsePlan(response(206, header),
                                                                      requestedOffset: 100, requestedValidator: validator))
        }
    }

    func testPartialResponseWithoutRequestedRangeOrValidatorIsRejected() {
        let partial = response(206, ["Content-Range": "bytes 100-199/200"])
        XCTAssertThrowsError(try OSMPBFDownloadPolicy.responsePlan(partial, requestedOffset: 0, requestedValidator: validator))
        XCTAssertThrowsError(try OSMPBFDownloadPolicy.responsePlan(partial, requestedOffset: 100, requestedValidator: nil))
    }

    func testInvalidOrErrorResponseNeverClaimsCompletedDownload() {
        for status in [302, 403, 404, 416, 500] {
            XCTAssertThrowsError(try OSMPBFDownloadPolicy.responsePlan(response(status), requestedOffset: 100, requestedValidator: validator))
        }
    }

    func testValidatorSurvivesRelaunch() throws {
        let restored = try JSONDecoder().decode(OSMPBFDownloadPolicy.Validator.self, from: JSONEncoder().encode(validator))
        XCTAssertEqual(restored.ifRange, "\"revision-1\"")
        XCTAssertEqual(OSMPBFDownloadPolicy.resumeOffset(partialBytes: 123, sourceURL: url, validator: restored), 123)
    }
}
