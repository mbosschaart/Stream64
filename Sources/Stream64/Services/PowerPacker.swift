import Foundation

/// Amiga PowerPacker 2.0 (`PP20`) decruncher.
///
/// Layout: `"PP20"` magic, 4-byte offset-width table, crunched bitstream,
/// trailing longword (3-byte big-endian decrunched length + 1-byte initial
/// bit-skip). Bits are read MSB-first from the end of the file backward;
/// output is written back-to-front (LZ77 literals + back-references).
enum PowerPacker {
    struct Limits: Equatable {
        var maximumPackedBytes = 16 * 1024 * 1024
        var maximumUnpackedBytes = 32 * 1024 * 1024

        static let `default` = Limits()
    }

    enum Error: LocalizedError, Equatable {
        case notPowerPacker
        case packedTooLarge(Int)
        case unpackedTooLarge(Int)
        case bitstreamUnderrun
        case outputOverrun
        case badBackReference

        var errorDescription: String? {
            switch self {
            case .notPowerPacker:
                return "Not a PowerPacker (PP20) file."
            case .packedTooLarge(let bytes):
                return "PowerPacker file is too large (\(bytes) bytes)."
            case .unpackedTooLarge(let bytes):
                return "PowerPacker expands beyond the safe size limit (\(bytes) bytes)."
            case .bitstreamUnderrun:
                return "PowerPacker bitstream ended early."
            case .outputOverrun:
                return "PowerPacker wrote past the declared output size."
            case .badBackReference:
                return "PowerPacker back-reference is out of range."
            }
        }
    }

    static func isPP20(_ data: Data) -> Bool {
        data.count >= 12 && data.starts(with: Data("PP20".utf8))
    }

    /// Return `data` unchanged unless it is a `PP20` stream, then decrunch.
    static func decrunchIfNeeded(
        _ data: Data,
        limits: Limits = .default
    ) throws -> Data {
        guard isPP20(data) else { return data }
        return try decrunch(data, limits: limits)
    }

    static func decrunch(
        _ data: Data,
        limits: Limits = .default
    ) throws -> Data {
        guard isPP20(data) else { throw Error.notPowerPacker }
        guard data.count <= limits.maximumPackedBytes else {
            throw Error.packedTooLarge(data.count)
        }

        let outLength =
            (Int(data[data.count - 4]) << 16)
            | (Int(data[data.count - 3]) << 8)
            | Int(data[data.count - 2])
        guard outLength > 0 else { throw Error.bitstreamUnderrun }
        guard outLength <= limits.maximumUnpackedBytes else {
            throw Error.unpackedTooLarge(outLength)
        }

        // Offset table + bitstream + trailer (magic stripped).
        let packed = data.subdata(in: 4..<data.count)
        return try unpack(packed, outLength: outLength)
    }

    private static func unpack(_ packed: Data, outLength: Int) throws -> Data {
        var out = [UInt8](repeating: 0, count: outLength)
        var bits = BackwardBits(packed)
        var dest = outLength

        let skip = UInt32(packed[packed.count - 1])
        _ = try bits.get(skip)

        while true {
            if try bits.get(1) == 0 {
                var count = 1
                while true {
                    let add = Int(try bits.get(2))
                    count += add
                    if add != 3 { break }
                }
                for _ in 0..<count {
                    guard dest > 0 else { throw Error.outputOverrun }
                    dest -= 1
                    out[dest] = UInt8(try bits.get(8))
                }
                if dest == 0 { break }
            }

            let index = Int(try bits.get(2))
            let offsetBits = UInt32(packed[index])
            var count = index + 2
            let offset: Int
            if count == 5 {
                if try bits.get(1) == 0 {
                    offset = Int(try bits.get(7))
                } else {
                    offset = Int(try bits.get(offsetBits))
                }
                while true {
                    let add = Int(try bits.get(3))
                    count += add
                    if add != 7 { break }
                }
            } else {
                offset = Int(try bits.get(offsetBits))
            }

            for _ in 0..<count {
                guard dest > 0 else { throw Error.outputOverrun }
                let source = dest + offset
                guard source < outLength else { throw Error.badBackReference }
                out[dest - 1] = out[source]
                dest -= 1
            }
            if dest == 0 { break }
        }

        return Data(out)
    }
}

private struct BackwardBits {
    let data: Data
    var bitpos: Int

    init(_ data: Data) {
        self.data = data
        // Start just before the trailing length/skip longword.
        self.bitpos = data.count * 8 - 32
    }

    mutating func get(_ n: UInt32) throws -> UInt32 {
        var result: UInt32 = 0
        for _ in 0..<n {
            guard bitpos > 0 else { throw PowerPacker.Error.bitstreamUnderrun }
            bitpos -= 1
            let byte = bitpos / 8
            let bit = 7 - (bitpos & 7)
            result = (result << 1) | UInt32((data[byte] >> bit) & 1)
        }
        return result
    }
}
