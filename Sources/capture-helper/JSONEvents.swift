import Foundation

func writeData(_ data: Data, toStderr: Bool = false) {
    let handle = toStderr ? FileHandle.standardError : FileHandle.standardOutput
    handle.write(data)
}

func writeString(_ value: String, toStderr: Bool = false) {
    writeData(Data(value.utf8), toStderr: toStderr)
}

func jsonLineData(_ object: [String: Any]) -> Data {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    var line = data
    line.append(0x0A)
    return line
}

func emitJSONLine(_ object: [String: Any], toStderr: Bool = false) {
    writeData(jsonLineData(object), toStderr: toStderr)
}

func emitJSONObject(_ object: [String: Any], toStderr: Bool = false) {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    writeData(data, toStderr: toStderr)
    writeString("\n", toStderr: toStderr)
}

func log(_ type: String, _ message: String) {
    emitJSONLine(["type": type, "msg": message], toStderr: true)
}

func logEvent(_ pairs: (String, Any)...) {
    var object: [String: Any] = [:]
    for (key, value) in pairs {
        object[key] = value
    }
    emitJSONLine(object, toStderr: true)
}
