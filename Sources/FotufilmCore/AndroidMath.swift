#if canImport(Android)
import Android

/// Single-precision math overloads missing from Swift on Android. Each wrapper calls Bionic's
/// corresponding `f` function and prevents implicit promotion to `Double`.

@_transparent public func acos(_ x: Float) -> Float { acosf(x) }
@_transparent public func asin(_ x: Float) -> Float { asinf(x) }
@_transparent public func atan(_ x: Float) -> Float { atanf(x) }
@_transparent public func atan2(_ y: Float, _ x: Float) -> Float { atan2f(y, x) }
@_transparent public func ceil(_ x: Float) -> Float { ceilf(x) }
@_transparent public func cos(_ x: Float) -> Float { cosf(x) }
@_transparent public func exp(_ x: Float) -> Float { expf(x) }
@_transparent public func exp2(_ x: Float) -> Float { exp2f(x) }
@_transparent public func expm1(_ x: Float) -> Float { expm1f(x) }
@_transparent public func floor(_ x: Float) -> Float { floorf(x) }
@_transparent public func hypot(_ x: Float, _ y: Float) -> Float { hypotf(x, y) }
@_transparent public func log(_ x: Float) -> Float { logf(x) }
@_transparent public func log10(_ x: Float) -> Float { log10f(x) }
@_transparent public func log1p(_ x: Float) -> Float { log1pf(x) }
@_transparent public func log2(_ x: Float) -> Float { log2f(x) }
@_transparent public func pow(_ x: Float, _ y: Float) -> Float { powf(x, y) }
@_transparent public func round(_ x: Float) -> Float { roundf(x) }
@_transparent public func sin(_ x: Float) -> Float { sinf(x) }
@_transparent public func sqrt(_ x: Float) -> Float { sqrtf(x) }
@_transparent public func tan(_ x: Float) -> Float { tanf(x) }
@_transparent public func tanh(_ x: Float) -> Float { tanhf(x) }
@_transparent public func trunc(_ x: Float) -> Float { truncf(x) }
#endif
