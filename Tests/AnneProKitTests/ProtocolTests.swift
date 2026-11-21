import Testing
@testable import AnneProKit

@Suite struct CRCTests {
    @Test func standardCheckValue() {
        // CRC-16/MODBUS check value for "123456789".
        #expect(CRC16.modbus(Array("123456789".utf8)) == 0x4B37)
    }

    @Test func emptyInput() {
        #expect(CRC16.modbus([UInt8]()) == 0xFFFF)
    }
}

@Suite struct FramingTests {
    /// msvisser's original packet builder, kept verbatim (minus logging) as a reference.
    /// It pads short final packets to 16 bytes; we pad to 20 like the official app.
    func msvisserPackets(prefix: [UInt8], data: [UInt8]) -> [[UInt8]] {
        let dataLen = UInt8(data.count), maxLen: UInt8 = 14
        let numPackets: UInt8 = dataLen / maxLen + (dataLen % maxLen == 0 ? 0 : 1)
        var index: UInt8 = 0, packetIndex: UInt8 = 0
        var packets: [[UInt8]] = []
        while index < dataLen {
            let thisLen = min(maxLen, dataLen - index)
            var current = prefix + [thisLen + 2, numPackets, packetIndex]
            for _ in 0..<thisLen {
                current.append(data[Int(index)])
                index += 1
            }
            while current.count < Int(maxLen) + 2 { current.append(0) }
            packetIndex += 1
            packets.append(current)
        }
        return packets
    }

    @Test func lightingPacketsMatchOriginalApp() {
        let payload = LightingProfile.horizontalRainbow().payload
        let ours = Framing.chunked(type: 9, op: 3, payload: payload)
        let theirs = msvisserPackets(prefix: [9, 215, 3], data: payload)
        #expect(ours.count == 16)
        #expect(ours.count == theirs.count)
        for (a, b) in zip(ours, theirs) {
            #expect(a.count == Framing.packetSize)
            #expect(Array(a.prefix(b.count)) == b)
            #expect(a.dropFirst(b.count).allSatisfy { $0 == 0 })
        }
    }

    @Test func layoutPacketsMatchOriginalApp() {
        let payload = KeyLayout.mac.payload
        let ours = Framing.chunked(type: 7, op: 2, payload: payload)
        let theirs = msvisserPackets(prefix: [7, 145, 2], data: payload)
        #expect(ours.count == 11)
        for (a, b) in zip(ours, theirs) {
            #expect(Array(a.prefix(b.count)) == b)
        }
    }

    @Test func singlePacketCommandsMatchOriginalApp() {
        #expect(Request.deviceInfo.packets == [[2, 1, 1]])
        #expect(Request.setLightingMode(.rainbow).packets == [[9, 2, 1, 14]])
        #expect(Request.setLightingMode(.custom).packets == [[9, 2, 1, 128]])
        #expect(Request.lightingMode.packets == [[9, 1, 8]])
        #expect(Request.customLighting.packets == [[9, 1, 9]])
        #expect(Request.customLightingID.packets == [[9, 1, 10]])
        #expect(Request.setBrightness(7).packets == [[9, 4, 2, 1, 7, 0]])
        #expect(Request.setBrightness(99).packets == [[9, 4, 2, 1, 10, 0]])
        #expect(Request.setBrightness(0).packets == [[9, 4, 2, 1, 1, 0]])
        #expect(Request.setLayoutMode(.mac).packets == [[7, 2, 3, 3]])
        #expect(Request.layoutMode.packets == [[7, 1, 4]])
        #expect(Request.customLayout.packets == [[7, 1, 5]])
    }

    @Test func repliesExpectHighBitOperation() {
        #expect(Request.deviceInfo.reply == ReplyKey(type: 2, op: 129))
        #expect(Request.customLighting.reply == ReplyKey(type: 9, op: 137))
        #expect(Request.customLayout.reply == ReplyKey(type: 7, op: 133))
        #expect(Request.uploadLighting(.init(repeating: .white)).reply == ReplyKey(type: 9, op: 131))
        #expect(Request.uploadLayout(.windows).reply == ReplyKey(type: 7, op: 130))
    }
}

@Suite struct AssemblerTests {
    @Test func reassemblesDeviceInfoCapturedByMsvisser() throws {
        // Real packets from an Anne Pro, quoted in msvisser's KeyboardController.swift.
        // The second one ends with two stale bytes past its declared length.
        var assembler = MessageAssembler()
        let first = assembler.feed([2, 15, 129, 10, 2, 0, 1, 2, 50, 55, 71, 1, 50, 48])
        let second = assembler.feed([2, 15, 129, 8, 2, 1, 54, 48, 52, 0, 54, 0, 50, 48])
        #expect(first == nil)
        let message = try #require(second)
        #expect(message.type == 2 && message.op == 129)
        #expect(message.data == [1, 2, 50, 55, 71, 1, 50, 48, 54, 48, 52, 0, 54, 0])

        let info = try #require(DeviceInfo(message))
        #expect(info.modelName == "Anne Pro")
        #expect(info.serial.count == 12)
    }

    @Test func roundTripsLightingThroughPackets() throws {
        let profile = LightingProfile.gradient(from: RGB(255, 0, 80), to: RGB(0, 200, 255))
        // The keyboard answers with the same chunk format, under the reply operation.
        let packets = Framing.chunked(type: 9, op: 137, payload: profile.payload)
        var assembler = MessageAssembler()
        var result: Message?
        for packet in packets { result = assembler.feed(packet) ?? result }
        let message = try #require(result)
        #expect(try LightingProfile(payload: message.data) == profile)
    }

    @Test func dropsMessageWhenChunkIsMissing() {
        let packets = Framing.chunked(type: 7, op: 133, payload: KeyLayout.windows.payload)
        var assembler = MessageAssembler()
        var results: [Message] = []
        for (index, packet) in packets.enumerated() where index != 4 {
            if let message = assembler.feed(packet) { results.append(message) }
        }
        #expect(results.isEmpty)
    }

    @Test func singlePacketReply() {
        var assembler = MessageAssembler()
        let mode = assembler.feed([9, 2, 136, 14])
        // Trailing junk beyond the declared length is ignored.
        let layout = assembler.feed([7, 2, 132, 3, 99, 99])
        #expect(mode == Message(type: 9, op: 136, data: [14]))
        #expect(layout == Message(type: 7, op: 132, data: [3]))
    }
}
