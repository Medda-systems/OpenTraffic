import Foundation

guard CommandLine.arguments.count >= 4, CommandLine.arguments.count.isMultiple(of: 2) else {
    fputs("usage: pack_icns <output.icns> <fourcc> <input.png> [...]\n", stderr)
    exit(2)
}

func bigEndianBytes(_ value: UInt32) -> [UInt8] {
    let value = value.bigEndian
    return withUnsafeBytes(of: value) { Array($0) }
}

var body = Data()
var index = 2
while index < CommandLine.arguments.count {
    let type = CommandLine.arguments[index]
    let path = CommandLine.arguments[index + 1]
    guard type.utf8.count == 4 else {
        fputs("invalid ICNS type: \(type)\n", stderr)
        exit(1)
    }
    let payload = try Data(contentsOf: URL(fileURLWithPath: path))
    body.append(contentsOf: type.utf8)
    body.append(contentsOf: bigEndianBytes(UInt32(payload.count + 8)))
    body.append(payload)
    index += 2
}

var output = Data("icns".utf8)
output.append(contentsOf: bigEndianBytes(UInt32(body.count + 8)))
output.append(body)
try output.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
