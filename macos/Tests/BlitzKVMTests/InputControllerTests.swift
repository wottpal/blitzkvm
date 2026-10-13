import JetKVMCore
import XCTest
@testable import BlitzKVM

final class InputControllerTests: XCTestCase {
    /// A matched 1504-wide remote on a 1512 pt Retina screen in full screen:
    /// 8 px of margin left and right of the video.
    private let layout = VideoLayout(x: 8, y: 0, width: 3008, height: 1896, nearest: true)

    private func pointerReports(_ moves: [(Double, Double, UInt8)]) -> [Data] {
        let input = InputController()
        var sent: [Data] = []
        input.send = { sent.append($0) }
        for (px, py, buttons) in moves { input.mouse(at: (px, py), in: layout, buttons: buttons) }
        return sent
    }

    func testTheMarginKeepsThePointerOnTheVideoEdge() {
        // A fast move: the last event inside the video is 8 px short of its
        // edge, the next one is in the margin.
        let sent = pointerReports([(3008, 948, 0), (3022, 948, 0)])
        XCTAssertEqual(sent.last, EngineProtocol.absolutePointer(x: 32767, y: 16384, buttons: 0))
    }

    func testRepeatedReportsAreSentOnce() {
        let sent = pointerReports([(1000, 500, 0), (1000, 500, 0), (1000, 500, 1), (1000, 500, 1), (1000, 500, 0)])
        XCTAssertEqual(sent.count, 3)
    }
}
