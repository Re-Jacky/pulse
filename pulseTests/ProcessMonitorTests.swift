import XCTest
@testable import Pulse

final class ProcessMonitorTests: XCTestCase {
    private func buffer(argc: Int32, execPath: String, args: [String]) -> [CChar] {
        var bytes: [CChar] = []
        withUnsafeBytes(of: argc) { bytes.append(contentsOf: $0.map { CChar(bitPattern: $0) }) }
        bytes.append(contentsOf: execPath.utf8CString)
        for arg in args {
            bytes.append(contentsOf: arg.utf8CString)
        }
        return bytes
    }

    func testParseProcessArgsJoinsArgv() {
        var buf = buffer(argc: 3, execPath: "/opt/homebrew/bin/node", args: ["node", "server/netserver.mjs"])
        // argc says 3 but only 2 argv entries: parser stops at what exists.
        buf.append(contentsOf: "extra".utf8CString)
        let parsed = buf.withUnsafeBufferPointer {
            ProcessMonitor.parseProcessArgs($0, count: buf.count)
        }
        XCTAssertEqual(parsed, "node server/netserver.mjs extra")
    }

    func testParseProcessArgsSkipsPaddingNulls() {
        var buf = buffer(argc: 2, execPath: "/usr/bin/python3", args: [])
        buf.append(contentsOf: [0, 0])
        buf.append(contentsOf: "python3".utf8CString)
        buf.append(contentsOf: [0])
        buf.append(contentsOf: "-m http.server 8003".utf8CString)
        let parsed = buf.withUnsafeBufferPointer {
            ProcessMonitor.parseProcessArgs($0, count: buf.count)
        }
        XCTAssertEqual(parsed, "python3 -m http.server 8003")
    }

    func testParseProcessArgsRejectsInvalidHeader() {
        var zero: [CChar] = [0, 0, 0, 0]
        XCTAssertNil(
            zero.withUnsafeBufferPointer { ProcessMonitor.parseProcessArgs($0, count: zero.count) }
        )
        var tiny: [CChar] = [1, 0]
        XCTAssertNil(
            tiny.withUnsafeBufferPointer { ProcessMonitor.parseProcessArgs($0, count: tiny.count) }
        )
    }
}
