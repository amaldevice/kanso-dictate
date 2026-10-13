import Foundation

/// Encodes raw audio samples into standard in-memory WAV (RIFF) container format.
public enum WAVWriter {
    /// Encodes normalized float samples [-1.0, 1.0] at 16kHz mono into standard 16-bit PCM WAV data.
    /// - Parameters:
    ///   - samples: Normalized 32-bit floating point audio samples [-1.0, 1.0].
    ///   - sampleRate: Sample rate in Hz (default 16,000 Hz).
    ///   - channels: Channel count (default 1 = mono).
    /// - Returns: Complete in-memory WAV data including standard 44-byte header.
    public static func createWAVData(
        from samples: [Float],
        sampleRate: UInt32 = 16_000,
        channels: UInt16 = 1
    ) -> Data {
        let bitsPerSample: UInt16 = 16
        let bytesPerSample: UInt32 = UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = channels * (bitsPerSample / 8)
        let byteRate: UInt32 = sampleRate * UInt32(blockAlign)
        
        let pcmDataSize = UInt32(samples.count) * bytesPerSample
        let riffChunkSize = 36 + pcmDataSize
        
        var data = Data(capacity: Int(44 + pcmDataSize))
        
        // 1. RIFF Header
        data.append(contentsOf: "RIFF".utf8)
        var riffChunkSizeLE = riffChunkSize.littleEndian
        withUnsafeBytes(of: &riffChunkSizeLE) { data.append(contentsOf: $0) }
        data.append(contentsOf: "WAVE".utf8)
        
        // 2. "fmt " Subchunk
        data.append(contentsOf: "fmt ".utf8)
        var subchunk1Size = UInt32(16).littleEndian
        withUnsafeBytes(of: &subchunk1Size) { data.append(contentsOf: $0) }
        
        var audioFormat = UInt16(1).littleEndian // 1 = Linear PCM
        withUnsafeBytes(of: &audioFormat) { data.append(contentsOf: $0) }
        
        var numChannelsLE = channels.littleEndian
        withUnsafeBytes(of: &numChannelsLE) { data.append(contentsOf: $0) }
        
        var sampleRateLE = sampleRate.littleEndian
        withUnsafeBytes(of: &sampleRateLE) { data.append(contentsOf: $0) }
        
        var byteRateLE = byteRate.littleEndian
        withUnsafeBytes(of: &byteRateLE) { data.append(contentsOf: $0) }
        
        var blockAlignLE = blockAlign.littleEndian
        withUnsafeBytes(of: &blockAlignLE) { data.append(contentsOf: $0) }
        
        var bitsPerSampleLE = bitsPerSample.littleEndian
        withUnsafeBytes(of: &bitsPerSampleLE) { data.append(contentsOf: $0) }
        
        // 3. "data" Subchunk
        data.append(contentsOf: "data".utf8)
        var dataSizeLE = pcmDataSize.littleEndian
        withUnsafeBytes(of: &dataSizeLE) { data.append(contentsOf: $0) }
        
        // 4. PCM 16-bit payload (clamp and scale from float [-1.0, 1.0])
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16Sample = Int16(clamped * 32767.0)
            var le = int16Sample.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        
        return data
    }
}
