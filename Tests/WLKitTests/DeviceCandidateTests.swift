import XCTest
@testable import WLKit

/// Which interface `WLDevice.connect` reaches for when the pad offers more
/// than one.
///
/// It offers more than one whenever it is on USB and paired over Bluetooth at
/// the same time, which is the ordinary state of a pad that has ever been
/// paired: macOS keeps the BLE node advertising alongside the wire. Both
/// nodes carry the vendor collection, so both open, and only one of them is
/// reliably listening. Picking the wrong one is the whole 2026-09-08 morning:
/// the app reported "connected" against a BLE session that had died in an
/// overnight sleep, and every off/on toggle re-latched it.
final class DeviceCandidateTests: XCTestCase {

    /// The pad as it actually enumerates: one interface per transport, all
    /// four collections on it, so the *primary* usage is keyboard (1) and the
    /// vendor pair appears only in DeviceUsagePairs.
    private func pad(_ id: UInt64, on transport: String) -> WLDevice.Candidate {
        WLDevice.Candidate(
            registryID: id,
            primaryUsagePage: 1,
            usagePages: [1, 12, WLDevice.vendorUsagePage],
            transport: transport
        )
    }

    func testTheCableWinsOverBluetooth() {
        let ordered = WLDevice.orderedCandidates([
            pad(2, on: "Bluetooth Low Energy"),
            pad(1, on: "USB")
        ])
        XCTAssertEqual(ordered.map(\.registryID), [1, 2])
    }

    /// Plain "Bluetooth" and "Bluetooth Low Energy" are both the pad's
    /// wireless node — macOS uses either string depending on how it paired.
    func testEveryBluetoothSpellingSortsLast() {
        for spelling in ["Bluetooth", "Bluetooth Low Energy", "BLE"] {
            let ordered = WLDevice.orderedCandidates([pad(2, on: spelling), pad(1, on: "USB")])
            XCTAssertEqual(ordered.map(\.registryID), [1, 2], "transport \"\(spelling)\"")
        }
    }

    /// An interface without the vendor collection is not a fallback, it is a
    /// trap: it opens, and every report id 6 write to it is dropped in
    /// silence.
    func testAnInterfaceWithoutTheVendorCollectionIsNotACandidate() {
        let keyboardOnly = WLDevice.Candidate(
            registryID: 9, primaryUsagePage: 1, usagePages: [1], transport: "USB")
        XCTAssertEqual(WLDevice.orderedCandidates([keyboardOnly]), [])
    }

    /// Today's firmware never produces this — all four collections share one
    /// interface — but a firmware that split the vendor collection onto its
    /// own would be the better match on the same transport.
    func testAVendorPrimaryInterfaceWinsWithinATransport() {
        let split = WLDevice.Candidate(
            registryID: 7,
            primaryUsagePage: WLDevice.vendorUsagePage,
            usagePages: [WLDevice.vendorUsagePage],
            transport: "USB"
        )
        let ordered = WLDevice.orderedCandidates([pad(1, on: "USB"), split])
        XCTAssertEqual(ordered.map(\.registryID), [7, 1])
    }

    /// Transport still outranks shape: a vendor-primary interface over the
    /// air loses to the cable, because the question the ordering answers is
    /// "which one will still be listening", not "which one is prettier".
    func testTransportOutranksShape() {
        let splitOverTheAir = WLDevice.Candidate(
            registryID: 7,
            primaryUsagePage: WLDevice.vendorUsagePage,
            usagePages: [WLDevice.vendorUsagePage],
            transport: "Bluetooth"
        )
        let ordered = WLDevice.orderedCandidates([splitOverTheAir, pad(1, on: "USB")])
        XCTAssertEqual(ordered.map(\.registryID), [1, 7])
    }

    /// `IOHIDManagerCopyDevices` returns a `Set`, whose iteration order is
    /// nondeterministic — so two runs used to open two different pads. The
    /// registry id is the tie-breaker that makes "which one did we get" a
    /// question with an answer.
    func testTheOrderIsTotalEvenWhenNothingElseSeparatesTwoInterfaces() {
        let both = [pad(41, on: "USB"), pad(17, on: "USB")]
        XCTAssertEqual(WLDevice.orderedCandidates(both).map(\.registryID), [17, 41])
        XCTAssertEqual(WLDevice.orderedCandidates(both.reversed()).map(\.registryID), [17, 41])
    }

    /// A transport nobody anticipated should sort between the two known ones
    /// rather than at either extreme: it is not the cable, but it is also not
    /// the one known to come back dead.
    func testAnUnknownTransportSitsBetweenTheCableAndTheAir() {
        let ordered = WLDevice.orderedCandidates([
            pad(3, on: "Bluetooth"),
            pad(2, on: "SPI"),
            pad(1, on: "USB")
        ])
        XCTAssertEqual(ordered.map(\.registryID), [1, 2, 3])
    }
}
