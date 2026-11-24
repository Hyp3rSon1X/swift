// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend -emit-module -parse-as-library -module-name M \
// RUN:   -o %t/M.swiftmodule %s -enable-deterministic-check 2>&1 | %FileCheck %s
// RUN: %target-sil-opt -enable-sil-verify-all %t/M.swiftmodule | %FileCheck %s --check-prefix=SIL

// Differentiability witnesses must be serialized in a deterministic order.

// CHECK: remark: produced matching output file '{{.*}}{{/|\\}}M.swiftmodule'

// The module must actually contain serialized witnesses, otherwise the check above proves nothing.
// SIL: sil_differentiability_witness

import _Differentiation

@inlinable
@differentiable(reverse)
public func f0(_ x: Float) -> Float { x * 1 }

@inlinable
@differentiable(reverse)
public func f1(_ x: Float) -> Float { x * 2 }

@inlinable
@differentiable(reverse)
public func f2(_ x: Float) -> Float { x * 3 }

@inlinable
@differentiable(reverse)
public func f3(_ x: Float) -> Float { x * 4 }

@inlinable
@differentiable(reverse)
public func f4(_ x: Float) -> Float { x * 5 }

@inlinable
@differentiable(reverse)
public func f5(_ x: Float) -> Float { x * 6 }

@inlinable
@differentiable(reverse)
public func f6(_ x: Float) -> Float { x * 7 }

@inlinable
@differentiable(reverse)
public func f7(_ x: Float) -> Float { x * 8 }

@inlinable
@differentiable(reverse)
public func f8(_ x: Float) -> Float { x * 9 }

@inlinable
@differentiable(reverse)
public func f9(_ x: Float) -> Float { x * 10 }

@inlinable
@differentiable(reverse)
public func f10(_ x: Float) -> Float { x * 11 }

@inlinable
@differentiable(reverse)
public func f11(_ x: Float) -> Float { x * 12 }

@inlinable
@differentiable(reverse)
public func f12(_ x: Float) -> Float { x * 13 }

@inlinable
@differentiable(reverse)
public func f13(_ x: Float) -> Float { x * 14 }

@inlinable
@differentiable(reverse)
public func f14(_ x: Float) -> Float { x * 15 }

@inlinable
@differentiable(reverse)
public func f15(_ x: Float) -> Float { x * 16 }
