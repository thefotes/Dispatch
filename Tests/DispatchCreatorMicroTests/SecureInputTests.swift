@testable import DispatchCreatorMicro
import Foundation
import XCTest

final class SecureInputTests: XCTestCase {
    /// Builds sessions from Foundation types, as the registry's CF values
    /// arrive after bridging.
    private func session(onConsole: Bool, secureInputPID: Int32?) -> NSDictionary {
        let session = NSMutableDictionary()
        session["kCGSSessionOnConsoleKey"] = onConsole ? kCFBooleanTrue : kCFBooleanFalse
        session["kCGSSessionUserNameKey"] = "someone" as NSString
        if let secureInputPID { session["kCGSSessionSecureInputPID"] = NSNumber(value: secureInputPID) }
        return session
    }

    func testOwnerComesFromTheSessionOnTheConsole() {
        let sessions: NSArray = [
            session(onConsole: false, secureInputPID: 111),
            session(onConsole: true, secureInputPID: 6314)
        ]
        XCTAssertEqual(SecureInput.ownerProcessID(inConsoleSessions: sessions), 6314)
    }

    func testNoOwnerWhenTheConsoleSessionRecordsNone() {
        let sessions: NSArray = [session(onConsole: true, secureInputPID: nil)]
        XCTAssertNil(SecureInput.ownerProcessID(inConsoleSessions: sessions))
    }

    func testNoOwnerWithoutAConsoleSessionOrRecord() {
        let offConsole: NSArray = [session(onConsole: false, secureInputPID: 111)]
        XCTAssertNil(SecureInput.ownerProcessID(inConsoleSessions: offConsole))
        XCTAssertNil(SecureInput.ownerProcessID(inConsoleSessions: nil))
        XCTAssertNil(SecureInput.ownerProcessID(inConsoleSessions: "unexpected" as NSString))
    }
}
