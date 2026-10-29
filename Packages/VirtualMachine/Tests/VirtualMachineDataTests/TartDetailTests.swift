import Foundation
@testable import VirtualMachineData
import XCTest

final class TartDetailTests: XCTestCase {
    func testCurrentTartStringSizeDoesNotDiscardConfiguration() throws {
        let detail = try Tart.decodeDetails("""
        {"OS":"darwin","CPU":4,"Memory":8192,"Disk":100,"Size":"24.125",
         "Running":true,"State":"running"}
        """, name: "manually-created")
        XCTAssertEqual(detail.name, "manually-created")
        XCTAssertEqual(detail.cpu, 4)
        XCTAssertEqual(detail.memory, 8_192)
        XCTAssertEqual(detail.os, "darwin")
        XCTAssertEqual(detail.sizeGB, 24.125)
        XCTAssertEqual(detail.diskGB, 100)
        XCTAssertEqual(detail.running, true)
    }

    func testOlderNumericSizeAndMissingOptionalFields() throws {
        let detail = try Tart.decodeDetails("""
        {"Disk":50,"Size":12.5,"State":"stopped","Running":false}
        """, name: "old-image")
        XCTAssertEqual(detail.sizeGB, 12.5)
        XCTAssertEqual(detail.running, false)
        XCTAssertNil(detail.cpu)
        XCTAssertNil(detail.memory)
        XCTAssertNil(detail.os)
    }
}
