import XCTest
@testable import JetKVMCore

final class EngineProtocolTests: XCTestCase {
    func testFramesRoundTripAcrossChunkBoundaries() throws {
        var stream = Data()
        stream.append(EngineProtocol.key(hid: 4, pressed: true))
        stream.append(EngineProtocol.absolutePointer(x: 16000, y: -1, buttons: 1))
        stream.append(EngineProtocol.wheel(y: -2, x: 1))
        stream.append(EngineProtocol.relativePointer(dx: -1, dy: 300, buttons: 0))

        var parser = FrameParser()
        var frames: [(FrameType?, Data)] = []
        // Feed one byte at a time: pipes deliver arbitrary chunks.
        for byte in stream {
            frames += try parser.feed(Data([byte]))
        }
        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(frames[0].0, .key)
        XCTAssertEqual([UInt8](frames[0].1), [4, 1])
        XCTAssertEqual(frames[1].0, .absPointer)
        XCTAssertEqual([UInt8](frames[1].1), [0, 0, 0x3e, 0x80, 0xff, 0xff, 0xff, 0xff, 1])
        XCTAssertEqual([UInt8](frames[2].1), [0xfe, 1])
        XCTAssertEqual(frames[3].0, .relPointer)
        XCTAssertEqual([UInt8](frames[3].1), [0xff, 0xff, 0x01, 0x2c, 0])
    }

    func testRejectsOversizedFrames() {
        var parser = FrameParser()
        XCTAssertThrowsError(try parser.feed(Data([0x7f, 0xff, 0xff, 0xff])))
    }

    func testParsesAccessUnitHeader() {
        var payload = Data([2, 1, 0, 0, 0x30, 0x39])
        payload.append(contentsOf: [0, 0, 0, 0, 0, 0, 0x03, 0xe8])
        payload.append(contentsOf: [0, 0, 0, 1, 0x26])
        guard let (header, data) = AccessUnitHeader.parse(payload) else {
            return XCTFail("parse failed")
        }
        XCTAssertEqual(header.codec, .h265)
        XCTAssertTrue(header.keyframe)
        XCTAssertEqual(header.rtpTimestamp, 12345)
        XCTAssertEqual(header.receivedUnixNano, 1000)
        XCTAssertEqual([UInt8](data), [0, 0, 0, 1, 0x26])
    }

    func testCommandEncodesLikeGo() throws {
        let data = try JSONEncoder().encode(EngineCommand(id: 7, cmd: "connect", baseURL: "jetkvm.local", offerH265: true))
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(object["cmd"] as? String, "connect")
        XCTAssertEqual(object["baseURL"] as? String, "jetkvm.local")
        XCTAssertEqual(object["offerH265"] as? Bool, true)
        XCTAssertNil(object["password"])
        let connect = try JSONSerialization.jsonObject(with: JSONEncoder().encode(EngineCommand(cmd: "connect", clientRefresh: true))) as! [String: Any]
        XCTAssertEqual(connect["clientRefresh"] as? Bool, true)
    }

    func testGameModeCommandEncodesLikeGo() throws {
        let on = try JSONSerialization.jsonObject(with: JSONEncoder().encode(EngineCommand(cmd: "setGameMode", gameMode: true))) as! [String: Any]
        XCTAssertEqual(on["cmd"] as? String, "setGameMode")
        XCTAssertEqual(on["gameMode"] as? Bool, true)
        let none = try JSONSerialization.jsonObject(with: JSONEncoder().encode(EngineCommand(cmd: "ping"))) as! [String: Any]
        XCTAssertNil(none["gameMode"])
        let json = #"{"Phase":"connected","Status":"connected","GameMode":true,"RelativeMouseOff":true}"#
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.GameMode, true)
        XCTAssertEqual(snapshot.RelativeMouseOff, true)
        // Game Mode's status reads the live encoder from MinQP (0 or absent: stock firmware).
        let live = try JSONDecoder().decode(SessionSnapshot.self, from: Data(#"{"Phase":"connected","Status":"connected","QualityLevel":"game","MinQP":22,"RelativeMouseOff":false}"#.utf8))
        XCTAssertEqual(live.MinQP, 22)
        XCTAssertEqual(live.RelativeMouseOff, false)
    }

    func testGameQualityLevelIsNeverALadderLevel() {
        XCTAssertEqual(QualityLevelName.ladderLevel("game"), "maximum")
        XCTAssertEqual(QualityLevelName.ladderLevel("balanced"), "balanced")
        XCTAssertNil(QualityLevelName.ladderLevel(nil))
        XCTAssertNil(QualityLevelName.ladderLevel(""))
    }

    func testSnapshotCarriesTheStillRefreshLevel() throws {
        let json = #"{"Phase":"connected","Status":"connected","ClientRefresh":true,"MinQP":10,"StillQP":1}"#
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.ClientRefresh, true)
        XCTAssertEqual(snapshot.MinQP, 10)
        XCTAssertEqual(snapshot.StillQP, 1)
    }
}

final class AnnexBTests: XCTestCase {
    func testSplitsH264ParameterSetsAndPrefixesSlices() {
        let au = Data([0, 0, 0, 1, 0x09, 0xf0, // AUD
                       0, 0, 0, 1, 0x67, 0x64, 0x1f, // SPS
                       0, 0, 1, 0x68, 0xee, // PPS
                       0, 0, 0, 1, 0x65, 0x88, 0x84]) // IDR
        let split = AnnexB.split(au, codec: .h264)
        XCTAssertEqual(split.parameterSets.map { [UInt8]($0) }, [[0x67, 0x64, 0x1f], [0x68, 0xee]])
        XCTAssertEqual([UInt8](split.lengthPrefixed), [0, 0, 0, 3, 0x65, 0x88, 0x84])
        XCTAssertTrue(split.isKeyframe)
    }

    func testSplitsH265ParameterSets() {
        let au = Data([0, 0, 0, 1, 0x40, 0x01, // VPS (32)
                       0, 0, 0, 1, 0x42, 0x01, // SPS (33)
                       0, 0, 0, 1, 0x44, 0x01, // PPS (34)
                       0, 0, 0, 1, 0x26, 0x01, 0xaf]) // IDR_W_RADL (19)
        let split = AnnexB.split(au, codec: .h265)
        XCTAssertEqual(split.parameterSets.count, 3)
        XCTAssertTrue(split.isKeyframe)
        XCTAssertEqual([UInt8](split.lengthPrefixed), [0, 0, 0, 3, 0x26, 0x01, 0xaf])
    }

    func testPFrameIsNotKeyframe() {
        let split = AnnexB.split(Data([0, 0, 1, 0x41, 0x9a]), codec: .h264)
        XCTAssertFalse(split.isKeyframe)
        XCTAssertTrue(split.parameterSets.isEmpty)
    }
}

final class KeyMapTests: XCTestCase {
    func testLettersAndModifiers() {
        XCTAssertEqual(KeyMap.hidUsage(keyCode: 0x00, isISO: false, remote: .mac), 0x04) // A
        XCTAssertEqual(KeyMap.hidUsage(keyCode: 0x24, isISO: true, remote: .pc), 0x28) // Return
        XCTAssertEqual(KeyMap.modifierUsage[0x37], 0xE3) // left ⌘ → left GUI
        XCTAssertEqual(KeyMap.modifierUsage[0x3D], 0xE6) // right ⌥ → AltGr
    }

    func testISOKeyboardSwapsSectionAndGraveForPCs() {
        // Top-left key (§ / ^) must be the PC grave position on ISO boards.
        XCTAssertEqual(KeyMap.hidUsage(keyCode: 0x0A, isISO: true, remote: .pc), 0x35)
        XCTAssertEqual(KeyMap.hidUsage(keyCode: 0x32, isISO: true, remote: .pc), 0x64)
        XCTAssertEqual(KeyMap.hidUsage(keyCode: 0x32, isISO: false, remote: .pc), 0x35)
    }

    func testMacRemoteGetsKeyCodesUnchanged() {
        // A Mac maps 0x35 back to kVK_ANSI_Grave and 0x64 to kVK_ISO_Section
        // (verified: on a German Mac, 0x64 types ^ and 0x35 types <).
        for isISO in [false, true] {
            XCTAssertEqual(KeyMap.hidUsage(keyCode: 0x32, isISO: isISO, remote: .mac), 0x35)
            XCTAssertEqual(KeyMap.hidUsage(keyCode: 0x0A, isISO: isISO, remote: .mac), 0x64)
        }
    }

    func testPCProfileSwapsCommandAndControl() {
        XCTAssertEqual(ModifierProfile.pc.apply(0xE3), 0xE0)
        XCTAssertEqual(ModifierProfile.pc.apply(0xE0), 0xE3)
        XCTAssertEqual(ModifierProfile.mac.apply(0xE3), 0xE3)
        XCTAssertEqual(ModifierProfile.pc.apply(0x04), 0x04)
    }

    /// Keys by position, as on a PC keyboard: ⌃ Ctrl, ⌥ Windows, ⌘ Alt.
    func testPCLayoutProfileMatchesPCKeyPositions() {
        let p = ModifierProfile.pcLayout
        XCTAssertEqual(p.apply(0xE0), 0xE0, "⌃ stays Ctrl")
        XCTAssertEqual(p.apply(0xE2), 0xE3, "⌥ sends Windows")
        XCTAssertEqual(p.apply(0xE3), 0xE2, "⌘ sends Alt")
        XCTAssertEqual(p.apply(0xE6), 0xE7, "right ⌥ sends right Windows")
        XCTAssertEqual(p.apply(0xE7), 0xE6, "right ⌘ sends right Alt")
        XCTAssertEqual(p.apply(0xE1), 0xE1)
        XCTAssertEqual(p.apply(0x04), 0x04)
        XCTAssertEqual(KeyMap.hidUsage(keyCode: 0x0A, isISO: true, remote: .pcLayout),
                       KeyMap.hidUsage(keyCode: 0x0A, isISO: true, remote: .pc), "ISO keys as for any PC")
    }
}

final class GeometryTests: XCTestCase {
    func testFitLetterboxesAndSnaps() {
        let layout = VideoLayout.compute(videoWidth: 1920, videoHeight: 1080, drawableWidth: 2000, drawableHeight: 2000, mode: .fit)
        XCTAssertEqual(layout.width, 2000)
        XCTAssertEqual(layout.height, 1125)
        XCTAssertEqual(layout.y, 437)
        XCTAssertFalse(layout.nearest)
    }

    func testPixelExactIsOnePhysicalPixel() {
        let layout = VideoLayout.compute(videoWidth: 1920, videoHeight: 1080, drawableWidth: 3024, drawableHeight: 1964, mode: .pixelExact, pointScale: 2)
        XCTAssertEqual(layout.width, 1920)
        XCTAssertEqual(layout.x, 552)
        XCTAssertTrue(layout.nearest)
    }

    func testActualSizeIsOnePointPerRemotePixel() {
        // Retina: a 1080p remote is 3840 physical pixels wide, the size a
        // 1080p monitor shows it at.
        let layout = VideoLayout.compute(videoWidth: 1920, videoHeight: 1080, drawableWidth: 6016, drawableHeight: 2400, mode: .actualSize, pointScale: 2)
        XCTAssertEqual(layout.width, 3840)
        XCTAssertEqual(layout.x, 1088)
        XCTAssertEqual(layout.y, 120)
        XCTAssertTrue(layout.nearest)
    }

    func testActualSizePansWhenLargerThanTheView() {
        let left = VideoLayout.compute(videoWidth: 1920, videoHeight: 1080, drawableWidth: 2000, drawableHeight: 2160, mode: .actualSize, pointScale: 2, pan: (0, 0.5))
        XCTAssertEqual(left.x, 0)
        let right = VideoLayout.compute(videoWidth: 1920, videoHeight: 1080, drawableWidth: 2000, drawableHeight: 2160, mode: .actualSize, pointScale: 2, pan: (1, 0.5))
        XCTAssertEqual(right.x, -1840)
        // The pointer at the view's right edge reaches the remote's right edge.
        XCTAssertEqual(right.absolutePosition(px: 2000, py: 0)?.0, 32767)
        let middle = VideoLayout.compute(videoWidth: 1920, videoHeight: 1080, drawableWidth: 2000, drawableHeight: 2160, mode: .actualSize, pointScale: 2, pan: (0.5, 0.5))
        XCTAssertEqual(middle.absolutePosition(px: 1000, py: 1080)?.0, 16384)
        XCTAssertEqual(middle.visibleRect(drawableWidth: 2000, drawableHeight: 2160), PixelRect(width: 2000, height: 2160))
    }

    func testChangedPixelsMapToTheDestinationTheyReach() {
        // 2400×1012 full screen on a 5K2K display: 2.507×, letterboxed.
        let layout = VideoLayout.compute(videoWidth: 2400, videoHeight: 1012, drawableWidth: 6016, drawableHeight: 2538, mode: .fit)
        XCTAssertEqual(layout.visibleRect(drawableWidth: 6016, drawableHeight: 2538), PixelRect(x0: 0, y0: 0, x1: 6016, y1: 2537))
        let caret = PixelRect(x0: 1000, y0: 500, x1: 1002, y1: 520)
        let reached = layout.destinationRect(of: caret, videoWidth: 2400, videoHeight: 1012, reach: 3)
        XCTAssertEqual(reached, PixelRect(x0: 2499, y0: 1245, x1: 2520, y1: 1312))
        XCTAssertEqual(layout.destinationRect(of: .empty, videoWidth: 2400, videoHeight: 1012, reach: 3), .empty)
    }

    func testPixelRects() {
        let a = PixelRect(x0: 2, y0: 3, x1: 7, y1: 4)
        XCTAssertEqual(a.union(.empty), a)
        XCTAssertEqual(a.union(PixelRect(x0: 0, y0: 5, x1: 1, y1: 9)), PixelRect(x0: 0, y0: 3, x1: 7, y1: 9))
        XCTAssertEqual(a.intersection(PixelRect(x0: 7, y0: 0, x1: 9, y1: 9)), .empty)
        XCTAssertEqual(a.outset(by: 2).intersection(PixelRect(width: 8, height: 8)), PixelRect(x0: 0, y0: 1, x1: 8, y1: 6))
        XCTAssertEqual(a.cells(of: 2), PixelRect(x0: 1, y0: 1, x1: 4, y1: 2))
        XCTAssertEqual(PixelRect.empty.outset(by: 3), .empty)
    }

    func testPreferredContentSizeUsesPointsAndFitsTheScreen() {
        let size = preferredContentSize(videoWidth: 1920, videoHeight: 1080, pointScale: 2, mode: .actualSize, available: (3008, 1200), extraHeight: 22)
        XCTAssertEqual(size?.width, 1920)
        XCTAssertEqual(size?.height, 1102)
        let small = preferredContentSize(videoWidth: 1920, videoHeight: 1080, pointScale: 2, mode: .actualSize, available: (1512, 900), extraHeight: 22)
        XCTAssertEqual(small?.width, 1512)
        XCTAssertEqual(small?.height, 873)
        let exact = preferredContentSize(videoWidth: 1920, videoHeight: 1080, pointScale: 2, mode: .pixelExact, available: (3008, 1200), extraHeight: 22)
        XCTAssertEqual(exact?.width, 960)
    }

    func testMatchWindowIsActualSizeOnceMatchedAndFitsOtherwise() {
        // Remote took the view's size, rounded down: one pixel per point.
        let matched = VideoLayout.compute(videoWidth: 1504, videoHeight: 944, drawableWidth: 3022, drawableHeight: 1894, mode: .matchWindow, pointScale: 2)
        XCTAssertEqual([matched.x, matched.y, matched.width, matched.height], [7, 3, 3008, 1888])
        // Not yet (or beyond the device's limits): fills the view.
        let pending = VideoLayout.compute(videoWidth: 1920, videoHeight: 1080, drawableWidth: 3008, drawableHeight: 1692, mode: .matchWindow, pointScale: 2)
        XCTAssertEqual([pending.width, pending.height], [3008, 1692])
        let larger = VideoLayout.compute(videoWidth: 1920, videoHeight: 1040, drawableWidth: 4800, drawableHeight: 2600, mode: .matchWindow, pointScale: 2)
        XCTAssertEqual([larger.width, larger.height], [4800, 2600])
    }

    func testMatchWindowScaleSetsPointsPerRemotePixel() {
        // 200%: a 1504×944 remote matched to a 3008×1888-point view.
        let doubled = VideoLayout.compute(videoWidth: 1504, videoHeight: 944, drawableWidth: 6020, drawableHeight: 3780,
                                          mode: .matchWindow, pointScale: 2, matchScale: 2)
        XCTAssertEqual([doubled.width, doubled.height], [6016, 3776])
        XCTAssertTrue(doubled.nearest)
        // 50%: half a point per remote pixel, one physical pixel on Retina.
        let half = VideoLayout.compute(videoWidth: 2048, videoHeight: 1152, drawableWidth: 2048, drawableHeight: 1152,
                                       mode: .matchWindow, pointScale: 2, matchScale: 0.5)
        XCTAssertEqual([half.width, half.height], [2048, 1152])
        let window = preferredContentSize(videoWidth: 1504, videoHeight: 944, pointScale: 2, mode: .matchWindow, matchScale: 1.5,
                                          available: (3008, 1600), extraHeight: 0)
        XCTAssertEqual(window?.width, 2256)
        XCTAssertEqual(window?.height, 1416)
    }

    func testIntegerScaleUsesWholeMultiples() {
        let layout = VideoLayout.compute(videoWidth: 1280, videoHeight: 720, drawableWidth: 3000, drawableHeight: 2000, mode: .integer)
        XCTAssertEqual(layout.width, 2560)
        XCTAssertTrue(layout.nearest)
    }

    func testAbsolutePositionClampsToVideo() {
        let layout = VideoLayout(x: 100, y: 50, width: 1000, height: 500, nearest: false)
        XCTAssertEqual(layout.absolutePosition(px: 100, py: 50)?.0, 0)
        XCTAssertEqual(layout.absolutePosition(px: 1100, py: 550)?.1, 32767)
        XCTAssertEqual(layout.absolutePosition(px: 600, py: 300)?.0, 16384)
        XCTAssertEqual(layout.absolutePosition(px: -50, py: 9000)?.1, 32767)
    }

    func testScrollAccumulatorKeepsFractions() {
        var acc = ScrollAccumulator(pointsPerTick: 10)
        var total = 0
        for _ in 0..<25 {
            total += Int(acc.add(deltaX: 0, deltaY: 1, precise: true).y)
        }
        XCTAssertEqual(total, 2, "25 points at 10 points per tick is 2 ticks, remainder kept")
        XCTAssertEqual(acc.add(deltaX: 0, deltaY: 5, precise: true).y, 1)
        XCTAssertEqual(acc.add(deltaX: 0, deltaY: -3, precise: false).y, -3)
    }
}

final class BarcodeTests: XCTestCase {
    func testDecodesEmulatorBarcode() {
        let width = 640, height = 16
        var luma = [UInt8](repeating: 16, count: width * height)
        func cell(_ i: Int, _ v: UInt8) {
            for y in 0..<8 { for x in 0..<8 { luma[y * width + i * 8 + x] = v } }
        }
        let ms: Int64 = 1_760_000_000_123
        cell(0, 235); cell(1, 16)
        for i in 0..<48 { cell(i + 2, (ms >> (47 - i)) & 1 == 1 ? 235 : 16) }
        let decoded = luma.withUnsafeBufferPointer {
            TimestampBarcode.decode(luma: $0.baseAddress!, stride: width, width: width, height: height)
        }
        XCTAssertEqual(decoded, ms)
    }
}

final class DeviceLibraryTests: XCTestCase {
    func testStoreRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("devices.json")
        let store = DeviceStore(url: url)
        var device = Device(name: "Server", addresses: ["10.0.0.5", "server.tailnet.ts.net"], deviceID: "abc")
        device.lastConnected = Date(timeIntervalSince1970: 1_760_000_000)
        store.upsert(device)
        try store.save()
        let reloaded = DeviceStore(url: url)
        XCTAssertEqual(reloaded.devices, [device])
        XCTAssertEqual(reloaded.device(matchingAddress: "SERVER.tailnet.ts.net")?.id, device.id)
        XCTAssertEqual(device.credentialAccount, "abc")
    }

    func testParseAddresses() {
        XCTAssertEqual(Device.parseAddresses(" 10.0.0.5, jetkvm.local  kvm.ts.net\n"), ["10.0.0.5", "jetkvm.local", "kvm.ts.net"])
    }

    func testProbePrefersEarlierAddressWithinWindow() async {
        // The VPN name answers first, the LAN IP (preferred) shortly after.
        // A window far wider than the gap: a loaded CI runner wakes sleepers late.
        let result = await AddressProbe.choose(addresses: ["lan", "vpn"], expectedDeviceID: "dev", preferenceWindow: .seconds(1)) { address in
            try? await Task.sleep(for: .milliseconds(address == "lan" ? 60 : 10))
            return DeviceIdentity(deviceId: "dev", authMode: nil)
        }
        XCTAssertEqual(try? result.get().address, "lan")
    }

    func testProbeFallsBackWhenPreferredIsDown() async {
        let result = await AddressProbe.choose(addresses: ["lan", "vpn"], expectedDeviceID: nil, preferenceWindow: .milliseconds(50)) { address in
            if address == "lan" {
                try? await Task.sleep(for: .seconds(5)) // unreachable: times out
                return nil
            }
            return DeviceIdentity(deviceId: "dev", authMode: nil)
        }
        XCTAssertEqual(try? result.get().address, "vpn")
    }

    func testProbeAcceptsUnknownIdentityBehindLogin() async {
        // Password-protected firmware answers GET /device only after login.
        let result = await AddressProbe.choose(addresses: ["lan"], expectedDeviceID: "real") { _ in
            DeviceIdentity(deviceId: nil, authMode: "password")
        }
        XCTAssertEqual(try? result.get().address, "lan")
        XCTAssertNil(try? result.get().identity.deviceId)
    }

    func testProbePrefersConfirmedIdentityOverUnknown() async {
        // The LAN address now answers 401 (another, password-protected
        // device); the VPN name confirms the saved ID 20 ms later, well within
        // the window even when a loaded CI runner wakes sleepers late.
        let result = await AddressProbe.choose(addresses: ["lan", "vpn"], expectedDeviceID: "dev", preferenceWindow: .seconds(1)) { address in
            if address == "lan" { return DeviceIdentity(deviceId: nil, authMode: "password") }
            try? await Task.sleep(for: .milliseconds(20))
            return DeviceIdentity(deviceId: "dev", authMode: nil)
        }
        XCTAssertEqual(try? result.get().address, "vpn")
    }

    func testProbeRejectsImpostor() async {
        let result = await AddressProbe.choose(addresses: ["evil"], expectedDeviceID: "real") { _ in
            DeviceIdentity(deviceId: "other", authMode: "password")
        }
        guard case .failure(.identityMismatch(expected: "real", found: "other")) = result else {
            return XCTFail("impostor accepted: \(result)")
        }
    }

    // MARK: Serial console, virtual media, certificate pinning

    func testSerialFilterStripsEscapesAcrossChunks() {
        var filter = SerialTextFilter()
        var out = filter.feed("\u{1B}[1;32mok\u{1B}[")
        out += filter.feed("0m done\r")
        out += filter.feed("\nnext\u{07}line\r\n\u{1B}]0;title\u{07}end")
        XCTAssertEqual(out, "ok done\nnextline\nend")
    }

    func testSerialFilterSurvivesAnUnterminatedSequence() {
        // Line noise at the wrong baud rate opens an OSC that never ends.
        var filter = SerialTextFilter()
        var out = filter.feed("noise\u{1B}]garbage")
        out += filter.feed("\nline one\nline two\n")
        XCTAssertEqual(out, "noise\nline one\nline two\n")
        var long = SerialTextFilter()
        let text = long.feed("\u{1B}[" + String(repeating: "1;", count: 200)) + long.feed("after")
        XCTAssertTrue(text.hasSuffix("after"), "a held-back sequence is bounded: \(text.suffix(20))")
    }

    func testSerialFilterLineEndingsAndCharsetEscapes() {
        var filter = SerialTextFilter()
        XCTAssertEqual(filter.feed("a\r\r\nb\u{1B}(Bc\r"), "a\nbc")
        XCTAssertEqual(filter.feed("\nd"), "\nd", "CR LF split across chunks is one line break")
    }

    func testSerialFilterTurnsLoneCarriageReturnIntoNewline() {
        var filter = SerialTextFilter()
        XCTAssertEqual(filter.feed("a\rb\n"), "a\nb\n")
    }

    func testStorageFilesDecodeGoTimes() throws {
        let json = #"{"files":[{"filename":"debian.iso","size":8192,"createdAt":"2026-10-10T15:04:05.123456789+02:00"},{"filename":"x.img.incomplete","size":1,"createdAt":"2026-10-10T13:04:05Z"}]}"#
        let files = try JSONDecoder().decode(StorageFiles.self, from: Data(json.utf8)).files
        XCTAssertEqual(files.map(\.filename), ["debian.iso", "x.img.incomplete"])
        XCTAssertNotNil(files[0].createdAt)
        XCTAssertNotNil(files[1].createdAt)
        XCTAssertTrue(files[1].isIncomplete)
    }

    func testCertificatePinChecksTheChainsAuthority() {
        let leaf = Data("leaf".utf8), ca = Data("device-ca".utf8)
        // Chains here stand for what SecTrust built, i.e. already linked by
        // signatures (a forged leaf yields a chain without the CA).
        XCTAssertTrue(CertificatePin.accepts(chain: [leaf, ca], pin: nil), "first use")
        XCTAssertTrue(CertificatePin.accepts(chain: [Data("other-leaf".utf8), ca], pin: CertificatePin.fingerprint(ca)))
        XCTAssertFalse(CertificatePin.accepts(chain: [Data("forged-leaf".utf8)], pin: CertificatePin.fingerprint(ca)))
        XCTAssertFalse(CertificatePin.accepts(chain: [leaf, Data("evil-ca".utf8)], pin: CertificatePin.fingerprint(ca)))
        XCTAssertFalse(CertificatePin.accepts(chain: [], pin: nil))
        // Same algorithm as the engine (sha256 hex).
        XCTAssertEqual(CertificatePin.fingerprint(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testSerialSettingsRoundTripOneField() throws {
        var settings = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"BaudRate":9600,"Parity":"none","Buttons":[]}"#.utf8))
        settings["BaudRate"] = .number(115200)
        XCTAssertEqual(settings["BaudRate"]?.numberValue, 115200)
        XCTAssertEqual(settings["Parity"]?.stringValue, "none")
    }
}

final class RemoteDisplayTests: XCTestCase {
    /// JetKVM 0.5.9's default EDID, as getEDID returns it.
    static let defaultEDID = "00FFFFFFFFFFFF0028B4010001EEFFC0302301038047287856EE91A3544C99260F5054000000D1C081C0318001010101010101010101023A801871382D40582C4500C48E2100001E773300A050D02B2030203500122C2100001A000000FD00174C0F5111000A202020202020000000FC004A65744B564D2076310A20202001D5020322D1431004012309070783010000E200CFE40D100401E305000065030C001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000CF"

    func testSizeFollowsTheViewInWholeSteps() {
        typealias S = RemoteDisplay.Size
        XCTAssertEqual(RemoteDisplay.size(fitting: 1504, 944), S(width: 1504, height: 944))
        XCTAssertEqual(RemoteDisplay.size(fitting: 1511, 947), S(width: 1504, height: 944))
        // Beyond the limits: the largest size of the same shape the pixel
        // clock allows at 60 Hz.
        XCTAssertEqual(RemoteDisplay.size(fitting: 2400, 1300), S(width: 2144, height: 1160))
        XCTAssertEqual(RemoteDisplay.size(fitting: 500, 300), S(width: 656, height: 400))
        // Wider than the minimum height allows: narrows until it streams
        // (this once looped forever).
        XCTAssertEqual(RemoteDisplay.size(fitting: 3000, 300), S(width: 3008, height: 400))
        // A 40" 21:9 display in full screen (3008×1269 points), with and
        // without the status bar.
        XCTAssertEqual(RemoteDisplay.size(fitting: 3008, 1247), S(width: 2448, height: 1012))
        XCTAssertEqual(RemoteDisplay.size(fitting: 3008, 1269), S(width: 2432, height: 1024))
        XCTAssertEqual(RemoteDisplay.size(fitting: 2560, 1600), S(width: 1984, height: 1240))
        for (w, h) in [(5000.0, 2000.0), (2400, 1300), (1700, 1700), (4000, 900), (2300, 1000)] {
            let size = RemoteDisplay.size(fitting: w, h)
            XCTAssertLessThanOrEqual(RemoteDisplay.timing(for: size).pixelClockKHz, RemoteDisplay.maxPixelClockKHz, "\(size)")
            XCTAssertLessThanOrEqual(size.width, RemoteDisplay.maximum.width)
            XCTAssertLessThanOrEqual(size.height, RemoteDisplay.maximum.height)
        }
    }

    func testModeTakesTheLargestPictureThenTheHighestRate() {
        typealias S = RemoteDisplay.Size
        typealias M = RemoteDisplay.Mode
        let large = 8 << 20
        // The same size at the highest rate that carries it (120 Hz would
        // exceed the encoder).
        XCTAssertEqual(RemoteDisplay.mode(fitting: 1504, 944, captureMaxBytes: large), M(S(width: 1504, height: 944), refresh: 90))
        XCTAssertEqual(RemoteDisplay.mode(fitting: 1280, 720, captureMaxBytes: large), M(S(width: 1280, height: 720), refresh: 120))
        // The 40" full screen: 1:1 at 40 Hz with the fork's capture buffers,
        // the largest stock buffers allow otherwise.
        XCTAssertEqual(RemoteDisplay.mode(fitting: 3008, 1268, captureMaxBytes: large), M(S(width: 3008, height: 1268), refresh: 40))
        XCTAssertEqual(RemoteDisplay.mode(fitting: 3008, 1247), M(S(width: 2736, height: 1132), refresh: 40))
        // A fixed rate: the largest size of the shape at that rate.
        XCTAssertEqual(RemoteDisplay.mode(fitting: 3008, 1247, refresh: 60, captureMaxBytes: large), M(S(width: 2448, height: 1012)))
        XCTAssertEqual(RemoteDisplay.mode(fitting: 3008, 1247, refresh: 50, captureMaxBytes: large), M(S(width: 2704, height: 1120), refresh: 50))
        XCTAssertEqual(RemoteDisplay.mode(fitting: 3008, 1269, refresh: 120, captureMaxBytes: large), M(S(width: 1664, height: 700), refresh: 120))
        XCTAssertEqual(RemoteDisplay.mode(fitting: 3008, 1247, refresh: 30, captureMaxBytes: large), M(S(width: 2832, height: 1172), refresh: 30))
        for (w, h) in [(6016.0, 2538.0), (3000, 300), (2400, 1350), (900, 3000)] {
            for refresh in RemoteDisplay.refreshRates {
                let mode = RemoteDisplay.mode(fitting: w, h, refresh: refresh, captureMaxBytes: large)
                XCTAssertTrue(RemoteDisplay.fits(mode.size, refresh: refresh, captureMaxBytes: large) || mode.size.width == RemoteDisplay.minimum.width,
                              "\(w)×\(h) at \(refresh) Hz: \(mode)")
            }
        }
    }

    /// Timings at other rates measured to stream cleanly (2026-10-11). At
    /// 33 Hz or less the pixel clock sits just under the bridge's slower
    /// 109.7 Mpx/s CSI rate.
    func testOtherRefreshTimingsMatchTheOnesVerifiedOnTheDevice() {
        for (w, h, hz, hTotal, vTotal, clock) in [(2560, 1080, 30, 2720, 1317, 107470), (3008, 1268, 25, 3168, 1357, 107470),
                                                  (2800, 1172, 30, 2960, 1210, 107450), (2496, 1044, 50, 3080, 1069, 164630)] {
            let t = RemoteDisplay.timing(for: .init(width: w, height: h), refresh: hz)
            XCTAssertEqual([t.hTotal, t.vTotal, t.pixelClockKHz], [hTotal, vTotal, clock], "\(w)×\(h) at \(hz) Hz")
        }
        XCTAssertFalse(RemoteDisplay.fits(.init(width: 3008, height: 1268), refresh: 30, captureMaxBytes: 8 << 20),
                       "needs a pixel clock above the slow link")
        XCTAssertFalse(RemoteDisplay.fits(.init(width: 3008, height: 1268), refresh: 25),
                       "larger than stock capture buffers")
    }

    /// Timings measured to stream cleanly on a JetKVM with a Mac host
    /// (width, height, h blank, v blank, v sync, pixel clock kHz).
    func testTimingsMatchTheOnesVerifiedOnTheDevice() {
        let verified = [
            (1504, 944, 1168, 27, 10, 155670), (1024, 600, 2768, 19, 10, 140830),
            (1920, 1080, 512, 31, 5, 162120), (1920, 1200, 272, 35, 6, 162430),
            (960, 540, 2640, 98, 5, 137810), (800, 500, 2200, 212, 6, 128160),
            (640, 400, 1760, 389, 6, 113620),
            // Wider than 1920 (2026-10-11, fork firmware, Mac mini host).
            (2176, 900, 792, 26, 10, 164900), (2160, 912, 768, 26, 10, 164790),
            (2112, 1168, 168, 34, 10, 164430), (2048, 1152, 256, 33, 5, 163810),
            (2448, 1024, 160, 30, 10, 164930),
        ]
        for (w, h, hBlank, vBlank, vSync, clock) in verified {
            let t = RemoteDisplay.timing(for: .init(width: w, height: h))
            XCTAssertEqual([t.hBlank, t.vBlank, t.vSync, t.pixelClockKHz], [hBlank, vBlank, vSync, clock], "\(w)×\(h)")
            XCTAssertLessThanOrEqual(t.hTotal * 4, w * 15, "line at most 3.75 widths")
            XCTAssertLessThanOrEqual(t.pixelClockKHz, 165_000)
        }
    }

    func testEDIDAdvertisesOnlyTheNewModeAndKeepsTheDisplay() throws {
        let base = try XCTUnwrap(RemoteDisplay.bytes(hex: Self.defaultEDID))
        let edid = try RemoteDisplay.edid(base, advertising: .init(width: 1504, height: 944))
        // The exact bytes the device and a Mac host accepted.
        XCTAssertEqual(RemoteDisplay.hex(edid), "00FFFFFFFFFFFF0028B4010001EEFFC0302301038028197856EE91A3544C99260F505400000001010101010101010101010101010101CF3CE09054B01B3030203A008EFA1000001A000000FD00174C0F5111000A202020202020000000FC004A65744B564D2076310A202020000000100000000000000000000000000000016102031ED02309070783010000E200CFE40D100401E305000065030C001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002C")
        XCTAssertEqual(RemoteDisplay.preferredSize(edid), .init(width: 1504, height: 944))
        XCTAssertEqual(Array(edid[8..<18]), Array(base[8..<18]), "same vendor, product, serial, date")
        for block in 0..<2 {
            XCTAssertEqual(edid[block * 128 ..< block * 128 + 128].reduce(0) { ($0 + Int($1)) & 0xFF }, 0)
        }
        // Applying it again (the next resize starts from the device's EDID)
        // only changes the timing.
        XCTAssertEqual(try RemoteDisplay.edid(edid, advertising: .init(width: 1504, height: 944)), edid)
        let other = try RemoteDisplay.edid(edid, advertising: .init(width: 1920, height: 1200))
        XCTAssertEqual(try RemoteDisplay.edid(base, advertising: .init(width: 1920, height: 1200)), other)
        XCTAssertThrowsError(try RemoteDisplay.edid([1, 2, 3], advertising: .init(width: 1504, height: 944)))
    }
}

final class JetKVMSetupTests: XCTestCase {
    private let fork = FirmwareBuild(kind: .blitzkvm, tag: "release/0.5.9-fork.4", sha256: String(repeating: "ab", count: 32), size: 1)
    private let stock = FirmwareBuild(kind: .stock, tag: "release/0.5.9", sha256: String(repeating: "ef", count: 32), size: 1)

    func testFirmwareState() {
        let bundled = [fork, stock]
        XCTAssertEqual(FirmwareState.evaluate(hasEncoderControl: true, appVersion: "0.5.9", installedSHA256: String(repeating: "AB", count: 32),
                                              bundled: bundled), .bundled(fork))
        XCTAssertEqual(FirmwareState.evaluate(hasEncoderControl: false, appVersion: "0.5.9", installedSHA256: String(repeating: "ef", count: 32),
                                              bundled: bundled), .bundled(stock))
        XCTAssertEqual(FirmwareState.evaluate(hasEncoderControl: true, appVersion: "0.5.9", installedSHA256: String(repeating: "cd", count: 32),
                                              bundled: bundled), .otherBlitzKVM)
        XCTAssertEqual(FirmwareState.evaluate(hasEncoderControl: true, appVersion: "0.5.9", installedSHA256: nil, bundled: bundled), .unverified)
        XCTAssertEqual(FirmwareState.evaluate(hasEncoderControl: false, appVersion: "0.5.10", installedSHA256: String(repeating: "cd", count: 32),
                                              bundled: bundled), .stock("0.5.10"))
        XCTAssertEqual(fork.title, "BlitzKVM 0.5.9-fork.4")
        XCTAssertEqual(stock.title, "JetKVM 0.5.9")
        XCTAssertEqual(fork.fileName, "release-0.5.9-fork.4.xz")
    }

    func testFirmwareGoesToTheJetKVMAsGzip() throws {
        // A binary's worth of mixed data, shipped as xz like the bundled builds.
        let binary = Data((0..<3_000_000).map { $0 % 7 == 0 ? UInt8.random(in: 0...255) : UInt8($0 % 251) })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let xz = dir.appendingPathComponent("build.xz"), gz = dir.appendingPathComponent("build.gz")
        try ((binary as NSData).compressed(using: .lzma) as Data).write(to: xz)
        try FirmwareBuild.gzip(xz: xz, to: gz)
        // What the JetKVM runs on it: gunzip -c.
        let gunzip = Process()
        gunzip.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        gunzip.arguments = ["-c", gz.path]
        let out = Pipe()
        gunzip.standardOutput = out
        try gunzip.run()
        let unzipped = out.fileHandleForReading.readDataToEndOfFile()
        gunzip.waitUntilExit()
        XCTAssertEqual(gunzip.terminationStatus, 0)
        XCTAssertEqual(unzipped, binary)
        XCTAssertThrowsError(try FirmwareBuild.gzip(xz: gz, to: dir.appendingPathComponent("not-xz.gz")))
    }

    /// The builds `make firmware` bundled, as the JetKVM receives them: the
    /// pinned binary after gunzip.
    func testBundledFirmwareArrivesAsPinned() throws {
        let macos = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = macos.appendingPathComponent("build/firmware")
        let builds = try FirmwareBuild.manifest(Data(contentsOf: macos.appendingPathComponent("Support/Firmware.json")))
            .filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.fileName).path) }
        guard !builds.isEmpty else { throw XCTSkip("no bundled firmware (make firmware)") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for build in builds {
            let gz = dir.appendingPathComponent("\(build.version).gz")
            try FirmwareBuild.gzip(xz: folder.appendingPathComponent(build.fileName), to: gz)
            let sum = Process()
            sum.executableURL = URL(fileURLWithPath: "/bin/sh")
            sum.arguments = ["-c", "gunzip -c \"$0\" | shasum -a 256", gz.path]
            let out = Pipe()
            sum.standardOutput = out
            try sum.run()
            let line = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            sum.waitUntilExit()
            XCTAssertEqual(line.split(separator: " ").first.map(String.init), build.sha256, build.title)
        }
    }

    func testInstallGuardVerdict() {
        XCTAssertEqual(InstallGuard.verdict(statusOutput: "disarmed\n"), .none)
        XCTAssertEqual(InstallGuard.verdict(statusOutput: "armed 0\n"), .pending, "armed, the restart still to come")
        XCTAssertEqual(InstallGuard.verdict(statusOutput: "armed 1\nSun Oct 18 13:43:15 UTC 2026 boot 1: app answering\n"), .pending)
        XCTAssertEqual(InstallGuard.verdict(statusOutput: "armed 0\nSun Oct 18 13:48:25 UTC 2026 boot 1: app healthy\n"), .healthy)
        XCTAssertEqual(InstallGuard.verdict(statusOutput: "disarmed\nSun Oct 18 13:46:01 UTC 2026 rollback: boot 1: app not answering\n"),
                       .rolledBack)
        XCTAssertEqual(InstallGuard.verdict(statusOutput: "disarmed\nSun Oct 18 13:46:01 UTC 2026 rollback failed: no /userdata/jetkvm/jetkvm_app.backup\n"),
                       .rollbackFailed)
        XCTAssertEqual(InstallGuard.verdict(statusOutput: ""), .none)
    }

    /// Stock JetKVMs have no /userdata/init.d until something creates it.
    func testInstallGuardCommandCreatesInitDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let install = Process()
        install.executableURL = URL(fileURLWithPath: "/bin/sh")
        install.arguments = ["-c", InstallGuard.installCommand.replacingOccurrences(of: "/userdata", with: root.path)]
        let input = Pipe()
        install.standardInput = input
        try install.run()
        input.fileHandleForWriting.write(Data("#!/bin/sh\n".utf8))
        try input.fileHandleForWriting.close()
        install.waitUntilExit()
        XCTAssertEqual(install.terminationStatus, 0)
        let script = InstallGuard.script.replacingOccurrences(of: "/userdata", with: root.path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script), script)
    }

    /// The app ships the fork's guard unchanged, and BusyBox's sh can parse it.
    func testBundledInstallGuard() throws {
        let macos = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bundled = macos.appendingPathComponent("Support/InstallGuard.sh")
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/sh")
        check.arguments = ["-n", bundled.path]
        try check.run()
        check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0, "sh -n \(bundled.path)")
        let script = try String(contentsOf: bundled, encoding: .utf8)
        for path in [InstallGuard.marker, InstallGuard.log, "/userdata/jetkvm/jetkvm_app.backup"] {
            XCTAssertTrue(script.contains(path), path)
        }
        let fork = macos.appendingPathComponent("../../kvm/scripts/fork/install_guard.sh")
        guard FileManager.default.fileExists(atPath: fork.path) else { throw XCTSkip("no wottpal/kvm checkout next to this one") }
        XCTAssertEqual(script, try String(contentsOf: fork, encoding: .utf8), "Support/InstallGuard.sh differs from the fork's guard")
    }

    func testFirmwareManifest() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Support/Firmware.json")
        let builds = try FirmwareBuild.manifest(Data(contentsOf: url))
        XCTAssertEqual(builds.map(\.kind), [.blitzkvm, .stock], "the recommended build first")
        XCTAssertTrue(builds.allSatisfy { $0.sha256.count == 64 && $0.size > 0 })
    }

    func testTailscaleState() throws {
        func state(_ json: String) throws -> TailscaleState {
            TailscaleState(try JSONDecoder().decode(TailscaleStatus.self, from: Data(json.utf8)))
        }
        XCTAssertEqual(try state(#"{"installed":false,"running":false,"controlURL":"https://controlplane.tailscale.com"}"#), .notInstalled)
        XCTAssertEqual(try state(#"{"installed":true,"running":false,"backendState":"NeedsLogin","authURL":"https://login.tailscale.com/a/x"}"#),
                       .needsLogin(URL(string: "https://login.tailscale.com/a/x")))
        XCTAssertEqual(try state(#"{"installed":true,"running":false,"backendState":"Stopped"}"#), .stopped("Stopped"))
        XCTAssertEqual(try state(#"{"installed":true,"running":true,"backendState":"Running","self":{"hostName":"mac-mini-jetkvm","dnsName":"mac-mini-jetkvm.example.ts.net.","tailscaleIPs":["100.64.0.10"],"online":true,"os":"linux"}}"#),
                       .running("mac-mini-jetkvm.example.ts.net"))
        XCTAssertEqual(try state(#"{"installed":true,"running":true,"self":{"dnsName":"","tailscaleIPs":["100.64.0.10"]}}"#), .running("100.64.0.10"))
    }

    func testTailscaleHostname() {
        XCTAssertEqual(TailscaleStatus.hostname(forDevice: "Mac mini"), "mac-mini-jetkvm")
        XCTAssertEqual(TailscaleStatus.hostname(forDevice: "  Rack KVM #2 "), "rack-kvm-2")
        XCTAssertEqual(TailscaleStatus.hostname(forDevice: "Büro-PC"), "buro-pc-jetkvm")
        XCTAssertEqual(TailscaleStatus.hostname(forDevice: "!!"), "jetkvm")
    }

    func testTailscaleRelease() throws {
        let json = #"{"Tarballs":{"386":"tailscale_1.104.1_386.tgz","arm":"tailscale_1.104.1_arm.tgz"},"TarballsVersion":"1.104.1","Version":"1.104.1"}"#
        let release = try JSONDecoder().decode(TailscaleRelease.self, from: Data(json.utf8))
        XCTAssertEqual(release.version, "1.104.1")
        XCTAssertEqual(release.url.absoluteString, "https://pkgs.tailscale.com/stable/tailscale_1.104.1_arm.tgz")
        XCTAssertEqual(release.checksumURL.absoluteString, "https://pkgs.tailscale.com/stable/tailscale_1.104.1_arm.tgz.sha256")
        XCTAssertThrowsError(try JSONDecoder().decode(TailscaleRelease.self, from: Data(#"{"Tarballs":{},"TarballsVersion":"1"}"#.utf8)))
    }

    func testSSHHelpers() {
        XCTAssertEqual(JetKVMSSH.host(of: "https://kvm.example:8443"), "kvm.example")
        XCTAssertEqual(JetKVMSSH.host(of: "192.168.1.40"), "192.168.1.40")
        XCTAssertEqual(JetKVMSSH.host(of: "mac-mini-jetkvm.example.ts.net"), "mac-mini-jetkvm.example.ts.net")
        let hash = String(repeating: "Ab", count: 32)
        XCTAssertEqual(JetKVMSSH.sha256(fromSumOutput: "\(hash)  /userdata/jetkvm/jetkvm_app.update.part\n"), hash.lowercased())
        XCTAssertNil(JetKVMSSH.sha256(fromSumOutput: "sha256sum: can't open 'x': No such file or directory"))
        let args = JetKVMSSH.arguments(host: "10.0.0.2", hostKeyAlias: "0123456789abcdef", privateKey: "/k", knownHosts: "/kh", command: "true")
        XCTAssertEqual(args.suffix(2), ["root@10.0.0.2", "true"])
        XCTAssertTrue(args.contains("HostKeyAlias=0123456789abcdef"))
        XCTAssertTrue(args.contains("BatchMode=yes"))
    }

    func testTailscaleRelay() {
        let json = #"{"Peer":{"k1":{"TailscaleIPs":["100.70.1.2","fd7a:115c:a1e0::2"],"CurAddr":"","Relay":"fra"},"k2":{"TailscaleIPs":["100.70.1.3"],"CurAddr":"192.168.1.9:41641","Relay":"fra"}}}"#
        XCTAssertEqual(TailscaleCLIStatus.relay(statusJSON: Data(json.utf8), to: "100.70.1.2"), "fra")
        XCTAssertNil(TailscaleCLIStatus.relay(statusJSON: Data(json.utf8), to: "100.70.1.3"), "direct")
        XCTAssertNil(TailscaleCLIStatus.relay(statusJSON: Data(json.utf8), to: "100.70.1.4"), "no such peer")
    }

    func testSetupSummary() throws {
        let earlier = SetupSummary(firmwareUpToDate: true, tailscaleConnected: false, passwordSet: false)
        let now = SetupSummary(firmwareUpToDate: nil, tailscaleConnected: true, passwordSet: false).merged(over: earlier)
        XCTAssertEqual(now, SetupSummary(firmwareUpToDate: true, tailscaleConnected: true, passwordSet: false))
        XCTAssertEqual(now.done, 2)
        XCTAssertFalse(now.isComplete)
        // A library written before the summary existed still loads.
        let old = #"[{"id":"x","name":"Mac mini","addresses":["192.168.1.40"],"modifierProfile":"mac","invertScroll":false}]"#
        XCTAssertNil(try JSONDecoder().decode([Device].self, from: Data(old.utf8)).first?.setup)
    }

    func testAddAddress() {
        var device = Device(name: "Mac mini", addresses: ["192.168.1.40"])
        XCTAssertTrue(device.addAddress("mac-mini-jetkvm.example.ts.net"))
        XCTAssertFalse(device.addAddress("MAC-MINI-JETKVM.example.ts.net"))
        XCTAssertEqual(device.addresses, ["192.168.1.40", "mac-mini-jetkvm.example.ts.net"])
    }

    func testDeviceGameModeRoundTrips() throws {
        var device = Device(name: "Mac mini", addresses: ["192.168.1.40"])
        XCTAssertFalse(device.isGameMode)
        device.isGameMode = true
        let decoded = try JSONDecoder().decode(Device.self, from: JSONEncoder().encode(device))
        XCTAssertTrue(decoded.isGameMode)
        // Off is stored as no key at all.
        device.isGameMode = false
        XCTAssertNil(device.gameMode)
        // A library written before Game Mode existed loads with it off.
        let old = #"{"id":"x","name":"Mac mini","addresses":["192.168.1.40"],"modifierProfile":"mac","invertScroll":false}"#
        XCTAssertFalse(try JSONDecoder().decode(Device.self, from: Data(old.utf8)).isGameMode)
    }
}

final class DoubleCommandPressTests: XCTestCase {
    func testDoublePress() {
        var press = DoubleCommandPress()
        XCTAssertFalse(press.flagsChanged(commandDown: true, othersDown: false, at: 0))
        XCTAssertFalse(press.flagsChanged(commandDown: false, othersDown: false, at: 0.08))
        XCTAssertTrue(press.flagsChanged(commandDown: true, othersDown: false, at: 0.25))
        // A third press starts over.
        XCTAssertFalse(press.flagsChanged(commandDown: true, othersDown: false, at: 0.3))
    }

    func testTooSlowOrInterrupted() {
        var press = DoubleCommandPress()
        _ = press.flagsChanged(commandDown: true, othersDown: false, at: 0)
        XCTAssertFalse(press.flagsChanged(commandDown: true, othersDown: false, at: 0.6), "too slow")
        press.keyPressed() // ⌘Tab
        XCTAssertFalse(press.flagsChanged(commandDown: true, othersDown: false, at: 0.7))
        XCTAssertFalse(press.flagsChanged(commandDown: true, othersDown: true, at: 0.8), "⌘⇧ is a shortcut")
        XCTAssertFalse(press.flagsChanged(commandDown: true, othersDown: false, at: 0.9))
    }
}

final class PointerRestTests: XCTestCase {
    func testHidesOnceAfterRestingAndAgainAfterTheNextMove() {
        var rest = PointerRest()
        XCTAssertEqual(rest.decide(at: 5, buttonsHeld: false), .idle, "never moved")
        rest.moved(at: 10)
        XCTAssertEqual(rest.decide(at: 10.1, buttonsHeld: false), .wait(until: 10 + PointerRest.delay))
        XCTAssertEqual(rest.decide(at: 10 + PointerRest.delay, buttonsHeld: false), .hide)
        XCTAssertEqual(rest.decide(at: 11, buttonsHeld: false), .idle, "hidden already")
        rest.moved(at: 12)
        XCTAssertEqual(rest.decide(at: 12.2, buttonsHeld: false), .hide)
    }

    func testEachMovePushesTheRestBack() {
        var rest = PointerRest()
        rest.moved(at: 1)
        rest.moved(at: 1.1)
        XCTAssertEqual(rest.decide(at: 1 + PointerRest.delay, buttonsHeld: false), .wait(until: 1.1 + PointerRest.delay))
    }

    func testAHeldButtonKeepsItVisibleUntilTheRelease() {
        var rest = PointerRest()
        rest.moved(at: 1) // button down
        XCTAssertEqual(rest.decide(at: 3, buttonsHeld: true), .idle)
        rest.moved(at: 4) // button up
        XCTAssertEqual(rest.decide(at: 4.1, buttonsHeld: false), .wait(until: 4 + PointerRest.delay))
        XCTAssertEqual(rest.decide(at: 4.2, buttonsHeld: false), .hide)
    }
}
