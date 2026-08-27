import XCTest
@testable import LLMDictiOS

final class RecorderProtocolTests: XCTestCase {
    func testFragmentedInfoFrameProducesInfoEventAfterFinalChunk() throws {
        var parser = RecorderProtocolParser()
        let frame = makeInfoFrame(
            version: 1,
            state: 2,
            flags: 3,
            microphoneGain: 4,
            wavSize: 0x1020_3040
        )

        XCTAssertTrue(try parser.consume(slice(frame, 0..<5)).isEmpty)
        XCTAssertEqual(
            try parser.consume(slice(frame, 5..<12)),
            [.info(RecorderDeviceInfo(
                protocolVersion: 1,
                state: 2,
                flags: 3,
                microphoneGain: 4,
                wavSize: 0x1020_3040
            ))]
        )
    }

    func testHeaderPayloadAndEndAreParsedAcrossArbitraryChunks() throws {
        var parser = RecorderProtocolParser()
        let payload = Data("WAVPAYLD".utf8)
        let transferStart = makeTransferStartFrame(totalSize: UInt32(payload.count), offset: 0)
        var crc = RecorderCRC32()
        crc.update(with: payload)
        let transferEnd = makeTransferEndFrame(totalSize: UInt32(payload.count), crc32: crc.value)
        let stream = transferStart + payload + transferEnd

        let chunk1 = slice(stream, 0..<5)
        let chunk2 = slice(stream, 5..<14)
        let chunk3 = slice(stream, 14..<17)
        let chunk4 = slice(stream, 17..<24)
        let chunk5 = slice(stream, 24..<stream.count)

        XCTAssertTrue(try parser.consume(chunk1).isEmpty)
        XCTAssertEqual(try parser.consume(chunk2), [.transferStarted(totalSize: 8, offset: 0), .payload(Data("WA".utf8))])
        XCTAssertEqual(try parser.consume(chunk3), [.payload(Data("VPA".utf8))])
        XCTAssertEqual(try parser.consume(chunk4), [.payload(Data("YLD".utf8))])
        XCTAssertEqual(
            try parser.consume(chunk5),
            [.transferFinished(totalSize: 8, crc32: crc.value)]
        )
    }

    func testOversizedTransferIsRejected() throws {
        var parser = RecorderProtocolParser()
        let oversized = RecorderProtocolParser.maximumWAVSize + 1

        XCTAssertThrowsError(
            try parser.consume(makeTransferStartFrame(totalSize: oversized, offset: 0))
        ) { error in
            XCTAssertEqual(error as? RecorderProtocolError, .invalidTransferSize(oversized))
        }
    }

    func testCRC32KnownVectorMatchesReferenceValue() throws {
        var crc = RecorderCRC32()
        crc.update(with: Data("123456789".utf8))

        XCTAssertEqual(crc.value, 0xCBF4_3926)
    }

    private func makeInfoFrame(
        version: UInt8,
        state: UInt8,
        flags: UInt8,
        microphoneGain: UInt8,
        wavSize: UInt32
    ) -> Data {
        var data = Data("LDI1".utf8)
        data.append(version)
        data.append(state)
        data.append(flags)
        data.append(microphoneGain)
        data.appendLittleEndian(wavSize)
        return data
    }

    private func makeTransferStartFrame(totalSize: UInt32, offset: UInt32) -> Data {
        var data = Data("LDT1".utf8)
        data.appendLittleEndian(totalSize)
        data.appendLittleEndian(offset)
        return data
    }

    private func makeTransferEndFrame(totalSize: UInt32, crc32: UInt32) -> Data {
        var data = Data("LDE1".utf8)
        data.appendLittleEndian(totalSize)
        data.appendLittleEndian(crc32)
        return data
    }

    private func slice(_ data: Data, _ range: Range<Int>) -> Data {
        Data(data[range])
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
