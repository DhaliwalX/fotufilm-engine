import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

public struct CommandLineControlError: Error, CustomStringConvertible {
    public let description: String
}

public extension EditorControl {
    /// CLI values use the flag's units and limits, which may exceed a host slider's travel.
    func applyCommandLineValue(_ text: String, to options: inout FotufilmEngine.Options) throws {
        guard offered(on: .cli), let flag = commandLine, flag.generic,
              let binding = host?.binding ?? self.binding else { return }
        let value: EditorControlValue
        switch host?.kind {
        case .boolean?:
            value = .flag(flag.placeholder.isEmpty ? true : text != "0")
        case .choice(let menu, _)?:
            guard let choices = menu.fixedChoices,
                  let index = choices.firstIndex(where: { $0.id == text || $0.label == text }) else {
                throw CommandLineControlError(description:
                    "Unknown \(flag.flag) value '\(text)'. Choices: "
                        + (menu.fixedChoices ?? []).map(\.id).joined(separator: ", "))
            }
            value = .choice(index)
        default:
            guard let number = Double(text), number.isFinite, Float(number).isFinite else {
                throw CommandLineControlError(description:
                    "Invalid \(flag.flag) value '\(text)'; expected a finite number.")
            }
            if let range = flag.range ?? host?.clamp, !range.contains(number) {
                throw CommandLineControlError(description:
                    "Invalid \(flag.flag) value '\(text)'; expected \(range.lowerBound) to \(range.upperBound).")
            }
            let canonical = host.map {
                $0.binding == nil
                    ? $0.bridge.canonical(fromBridge: number * $0.paramScale + $0.paramOffset)
                    : number
            } ?? number
            value = .number(canonical)
        }
        binding.apply(value, to: &options)
    }
}
