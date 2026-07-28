import XCTest
@testable import Frigate

final class CameraDetailModelTests: XCTestCase {
    private let baseURL = URL(string: "https://nvr.local:8971")!
    private let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xD9])

    private func makeClient() -> FrigateClient {
        FrigateClient(baseURL: baseURL, session: mockProtocolSession())
    }

    private func httpResponse(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    @MainActor
    func testRefreshRequestsCameraAtDetailHeightAndLoads() async {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://nvr.local:8971/api/front_door/latest.jpg?height=720"
            )
            return (self.httpResponse(request.url!, 200), self.jpegBytes)
        }

        let model = CameraDetailModel(client: makeClient(), cameraName: "front_door")
        XCTAssertEqual(model.state, .loading)

        await model.refresh()

        XCTAssertEqual(model.state, .loaded(jpegBytes))
    }

    @MainActor
    func testRefreshMarksFailedOnServerError() async {
        MockURLProtocol.requestHandler = { request in
            (self.httpResponse(request.url!, 500), Data())
        }

        let model = CameraDetailModel(client: makeClient(), cameraName: "front_door")
        await model.refresh()

        XCTAssertEqual(model.state, .failed)
    }
}
