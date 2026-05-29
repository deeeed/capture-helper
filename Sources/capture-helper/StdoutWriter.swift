import Foundation

let writeQueue = DispatchQueue(label: "stdout-writer")

func writeStdout(_ data: Data) {
    writeQueue.sync {
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var written = 0
            while written < data.count {
                let bytePointer = baseAddress.assumingMemoryBound(to: UInt8.self).advanced(by: written)
                let count = data.count - written
                let n = Darwin.write(STDOUT_FILENO, bytePointer, count)
                if n <= 0 { break }
                written += n
            }
        }
    }
}
