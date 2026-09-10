import Foundation
import FotufilmEditModel

var arguments = Array(CommandLine.arguments.dropFirst())
var check = false
var engineRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
var consumerRoot: URL?
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--check": check = true
    case "--engine":
        engineRoot = URL(fileURLWithPath: arguments.removeFirst(), isDirectory: true)
    case "--consumer":
        consumerRoot = URL(fileURLWithPath: arguments.removeFirst(), isDirectory: true)
    default:
        FileHandle.standardError.write(Data("unknown argument \(argument)\n".utf8))
        exit(2)
    }
}

let outputs = ControlsExport.outputs(engineRoot: engineRoot, consumerRoot: consumerRoot)
var stale: [String] = []
for output in outputs {
    let existing = try? String(contentsOf: output.path, encoding: .utf8)
    let expected = output.render(existing: existing)
    guard let expected else {
        stale.append("\(output.path.path): missing regions")
        continue
    }
    if existing == expected { continue }
    if check {
        stale.append(output.path.path)
        continue
    }
    try FileManager.default.createDirectory(at: output.path.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try expected.write(to: output.path, atomically: true, encoding: .utf8)
    print("wrote \(output.path.path)")
}
if !stale.isEmpty {
    for path in stale { FileHandle.standardError.write(Data("stale: \(path)\n".utf8)) }
    exit(1)
}
print(check ? "\(outputs.count) generated files are current" : "\(outputs.count) generated files checked")
