import Foundation
import FotufilmEditModel
import FotufilmCore

#if os(WASI)
// A reactor lives in one browser worker. Requests and responses have explicit ownership;
// the UI copies a response before asking for another profile.
private var input: UnsafeMutablePointer<UInt8>?
private var inputCount = 0
private var output: UnsafeMutablePointer<UInt8>?
private var outputCount = 0

@_expose(wasm, "profile_input")
@_cdecl("profile_input")
func profileInput(_ count: Int) -> UnsafeMutablePointer<UInt8>? {
    input?.deallocate()
    input = nil
    inputCount = 0
    guard count > 0, count <= 8 * 1024 * 1024 else { return nil }
    input = .allocate(capacity: count)
    inputCount = count
    return input
}

@_expose(wasm, "profile_prepare")
@_cdecl("profile_prepare")
func profilePrepare() -> Int32 {
    output?.deallocate()
    output = nil
    outputCount = 0
    let bytes: Data
    let status: Int32
    do {
        guard let input, inputCount > 0 else {
            throw WebRequestError.missingInput
        }
        let request = try JSONDecoder().decode(WebProfileRequest.self,
            from: Data(bytes: input, count: inputCount))
        bytes = try request.prepare()
        status = 0
    } catch {
        bytes = Data(String(describing: error).utf8)
        status = 1
    }
    input?.deallocate()
    input = nil
    inputCount = 0
    output = .allocate(capacity: bytes.count)
    outputCount = bytes.count
    bytes.copyBytes(to: output!, count: bytes.count)
    return status
}

@_expose(wasm, "profile_output")
@_cdecl("profile_output")
func profileOutput() -> UnsafeMutablePointer<UInt8>? { output }

@_expose(wasm, "profile_output_size")
@_cdecl("profile_output_size")
func profileOutputSize() -> Int { outputCount }

private enum WebRequestError: Error { case missingInput }
#else
// The same protocol on the command line provides a native reference for browser verification.
do {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    if CommandLine.arguments.contains("--catalogue") {
        let definitions = try JSONDecoder().decode([String: FilmStockDefinition].self, from: input)
        var catalogue: [String: [String: Any]] = [:]
        for (id, definition) in definitions {
            let stock = try definition.validated().stock
            catalogue[id] = [
                "available": EditorControlCatalogue.controls(for: stock, on: .web).map { $0.field.rawValue },
                "nativeFormat": definition.nativeFormatID ?? FilmFormat.houseDefaultID,
            ]
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: catalogue, options: [.sortedKeys]))
    } else {
        let request = try JSONDecoder().decode(WebProfileRequest.self, from: input)
        FileHandle.standardOutput.write(try request.prepare())
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
#endif
