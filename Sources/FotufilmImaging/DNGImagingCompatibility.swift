// Keep the imaging module's public spelling for existing clients. The parser is
// portable metadata code and also runs in the browser's native WASI worker.
#if canImport(FotufilmCore)
import FotufilmCore
public typealias DNGOpcodes = FotufilmCore.DNGOpcodes
#endif
