@testable import DispatchApp
import DispatchCreatorMicro
import XCTest

private actor FakeInputMonitoringRequester: InputMonitoringPermissionRequesting {
    private(set) var checkResult: InputMonitoringPermission
    var requestResult: InputMonitoringPermission
    private(set) var checkCount = 0
    private(set) var requestCount = 0

    init(checkResult: InputMonitoringPermission, requestResult: InputMonitoringPermission) {
        self.checkResult = checkResult
        self.requestResult = requestResult
    }

    func grantInSystemSettings() {
        checkResult = .granted
    }

    func check() async -> InputMonitoringPermission {
        checkCount += 1
        return checkResult
    }

    func request() async -> InputMonitoringPermission {
        requestCount += 1
        return requestResult
    }
}

@MainActor
final class InputMonitoringPermissionTests: XCTestCase {
    func testRequestPromptsOnlyWhenDenied() async {
        let requester = FakeInputMonitoringRequester(checkResult: .denied, requestResult: .granted)
        let model = AppModel(inputMonitoringRequester: requester)

        await model.requestInputMonitoringPermission()

        XCTAssertEqual(model.inputMonitoringPermission, .granted)
        let counts = await (requester.checkCount, requester.requestCount)
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
    }

    func testRequestSkipsPromptWhenAlreadyGranted() async {
        let requester = FakeInputMonitoringRequester(checkResult: .granted, requestResult: .granted)
        let model = AppModel(inputMonitoringRequester: requester)

        await model.requestInputMonitoringPermission()

        XCTAssertEqual(model.inputMonitoringPermission, .granted)
        let counts = await (requester.checkCount, requester.requestCount)
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 0)
    }

    func testDeniedRequestKeepsPermissionDenied() async {
        let requester = FakeInputMonitoringRequester(checkResult: .denied, requestResult: .denied)
        let model = AppModel(inputMonitoringRequester: requester)

        await model.requestInputMonitoringPermission()

        XCTAssertEqual(model.inputMonitoringPermission, .denied)
        let counts = await (requester.checkCount, requester.requestCount)
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
    }

    func testRefreshPicksUpGrantMadeOutsideTheApp() async {
        let requester = FakeInputMonitoringRequester(checkResult: .denied, requestResult: .denied)
        let model = AppModel(inputMonitoringRequester: requester)
        await model.refreshInputMonitoringPermission()
        XCTAssertEqual(model.inputMonitoringPermission, .denied)

        await requester.grantInSystemSettings()
        await model.refreshInputMonitoringPermission()

        XCTAssertEqual(model.inputMonitoringPermission, .granted)
        let requestCount = await requester.requestCount
        XCTAssertEqual(requestCount, 0)
    }
}
