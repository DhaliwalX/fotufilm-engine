#if canImport(Dispatch)
import Dispatch
#endif

/// Independent rows use the host's worker pool where available. A browser worker runs the
/// same rows serially; it has no libdispatch and does not share engine state with the UI.
enum ParallelWork {
    static func forEach(iterations: Int, execute: (Int) -> Void) {
        #if canImport(Dispatch)
        DispatchQueue.concurrentPerform(iterations: iterations, execute: execute)
        #else
        for index in 0..<iterations { execute(index) }
        #endif
    }
}
