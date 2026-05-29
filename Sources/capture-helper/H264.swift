import Foundation
import CoreMedia

let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

func extractParameterSets(from format: CMFormatDescription) -> Data {
    var result = Data()
    var paramCount: Int = 0
    if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &paramCount, nalUnitHeaderLengthOut: nil) == noErr {
        for index in 0..<paramCount {
            var ptr: UnsafePointer<UInt8>?
            var size: Int = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                result.append(contentsOf: startCode)
                result.append(ptr, count: size)
            }
        }
    }
    return result
}

func lengthPrefixedToAnnexB(_ data: Data) -> Data {
    var result = Data()
    var offset = 0
    while offset + 4 <= data.count {
        let length = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 |
            Int(data[offset + 2]) << 8 | Int(data[offset + 3])
        offset += 4
        guard length > 0, offset + length <= data.count else { break }
        result.append(contentsOf: startCode)
        result.append(data[offset..<offset + length])
        offset += length
    }
    return result
}
