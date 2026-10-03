import Foundation

enum TestAudio {
    /// 16-bit mono PCM silence at 44.1 kHz in a new temporary file; the caller removes it.
    static func silentWav(durationSeconds: Double) throws -> URL {
        let sampleRate = 44_100
        let channels = 1
        let bitsPerSample = 16
        let sampleCount = Int(durationSeconds * Double(sampleRate))
        let dataSize = sampleCount * channels * bitsPerSample / 8

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        appendLE(UInt32(36 + dataSize), to: &data)
        data.append(contentsOf: "WAVEfmt ".utf8)
        appendLE(UInt32(16), to: &data)
        appendLE(UInt16(1), to: &data)
        appendLE(UInt16(channels), to: &data)
        appendLE(UInt32(sampleRate), to: &data)
        appendLE(UInt32(sampleRate * channels * bitsPerSample / 8), to: &data)
        appendLE(UInt16(channels * bitsPerSample / 8), to: &data)
        appendLE(UInt16(bitsPerSample), to: &data)
        data.append(contentsOf: "data".utf8)
        appendLE(UInt32(dataSize), to: &data)
        data.append(Data(repeating: 0, count: dataSize))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silent-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    private static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
