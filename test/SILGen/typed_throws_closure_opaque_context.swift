// RUN: %target-swift-emit-silgen -target %target-swift-6.0-abi-triple %s | %FileCheck %s
// RUN: %target-swift-emit-ir -target %target-swift-6.0-abi-triple %s -o /dev/null
// RUN: %target-swift-emit-ir -target %target-swift-6.0-abi-triple -O %s -o /dev/null

// REQUIRES: concurrency

// A closure literal with a typed throws clause whose contextual type is
// fully opaque, such as an argument of generic type `T` or an array element,
// is emitted directly at the most general abstraction pattern. Its lowered
// function type throws the error indirectly, so the closure's entry block
// must have an indirect error argument. The prolog used to lower the thrown
// error against the concrete error type instead, which produced invalid SIL
// and crashed the compiler.

enum EnumError: Error { case a, b, c }
struct StructError: Error { var message: String }
final class ClassError: Error {}

func id<T>(_ x: T) -> T { x }
func idOptional<T>(_ x: T?) -> T? { x }
func idAsync<T>(_ x: T) async -> T { x }
func idPack<each T>(_ x: repeat each T) -> (repeat each T) { (repeat each x) }

protocol P {
  associatedtype A
  func take(_ a: A)
}
struct S: P {
  func take(_ a: () throws(EnumError) -> Int) {}
}
func take<X: P>(_ x: X, _ a: X.A) { x.take(a) }
func takeSome(_ x: some Any) {}

func thrower() throws(EnumError) -> Int { throw .b }

// CHECK-LABEL: sil hidden [ossa] @$s{{.*}}8testEnumyyF :
// CHECK-NOT:     thunk
// CHECK:         function_ref @$s{{.*}}8testEnumyyF{{.*}}fU_ : $@convention(thin) @substituted <τ_0_0, τ_0_1> () -> (@out τ_0_1, @error_indirect τ_0_0) for <EnumError, Int>
// CHECK-NOT:     thunk
// CHECK:         apply {{%.*}}<() throws(EnumError) -> Int>(
// CHECK:       } // end sil function '$s{{.*}}8testEnumyyF'

// CHECK-LABEL: sil private [ossa] @$s{{.*}}8testEnumyyF{{.*}}fU_ : $@convention(thin) @substituted <τ_0_0, τ_0_1> () -> (@out τ_0_1, @error_indirect τ_0_0) for <EnumError, Int> {
// CHECK:       bb0(%0 : $*Int, [[ERROR:%.*]] : $*EnumError):
// CHECK:         copy_addr [take] {{%.*}} to [init] [[ERROR]]
// CHECK:         throw_addr
// CHECK:       } // end sil function '$s{{.*}}8testEnumyyF{{.*}}fU_'
func testEnum() {
  _ = id({ () throws(EnumError) -> Int in throw .a })
}

// CHECK-LABEL: sil private [ossa] @$s{{.*}}10testReturnyyF{{.*}}fU_ : $@convention(thin) @substituted <τ_0_0, τ_0_1> () -> (@out τ_0_1, @error_indirect τ_0_0) for <EnumError, Int> {
// CHECK:       bb0(%0 : $*Int, %1 : $*EnumError):
// CHECK:         return
// CHECK:       } // end sil function '$s{{.*}}10testReturnyyF{{.*}}fU_'
func testReturn() {
  _ = id({ () throws(EnumError) -> Int in 42 })
}

// The indirect error argument comes before the parameters.
// CHECK-LABEL: sil private [ossa] @$s{{.*}}13testParameteryyF{{.*}}fU_ : $@convention(thin) @substituted <τ_0_0, τ_0_1, τ_0_2> (@in_guaranteed τ_0_0) -> (@out τ_0_2, @error_indirect τ_0_1) for <Int, EnumError, Int> {
// CHECK:       bb0(%0 : $*Int, [[ERROR:%.*]] : $*EnumError, %2 : $*Int):
// CHECK:         try_apply {{%.*}}() : $@convention(thin) () -> (Int, @error EnumError), normal [[NORMAL:bb[0-9]+]], error [[ERRORBB:bb[0-9]+]]
// CHECK:       [[ERRORBB]]([[E:%.*]] : $EnumError):
// CHECK:         store [[E]] to [trivial] [[ERROR]]
// CHECK:         throw_addr
// CHECK:       } // end sil function '$s{{.*}}13testParameteryyF{{.*}}fU_'
func testParameter() {
  _ = id({ (x: Int) throws(EnumError) -> Int in
    if x > 0 { return try thrower() }
    return x
  })
}

// CHECK-LABEL: sil private [ossa] @$s{{.*}}10testStructyyF{{.*}}fU_ : $@convention(thin) @substituted <τ_0_0, τ_0_1> () -> (@out τ_0_1, @error_indirect τ_0_0) for <StructError, Int> {
// CHECK:       bb0(%0 : $*Int, [[ERROR:%.*]] : $*StructError):
// CHECK:         copy_addr [take] {{%.*}} to [init] [[ERROR]]
// CHECK:         throw_addr
// CHECK:       } // end sil function '$s{{.*}}10testStructyyF{{.*}}fU_'
func testStruct() {
  _ = id({ () throws(StructError) -> Int in throw StructError(message: "s") })
}

// CHECK-LABEL: sil private [ossa] @$s{{.*}}9testClassyyF{{.*}}fU_ : $@convention(thin) @substituted <τ_0_0, τ_0_1> () -> (@out τ_0_1, @error_indirect τ_0_0) for <ClassError, Int> {
// CHECK:       bb0(%0 : $*Int, [[ERROR:%.*]] : $*ClassError):
// CHECK:         throw_addr
// CHECK:       } // end sil function '$s{{.*}}9testClassyyF{{.*}}fU_'
func testClass() {
  _ = id({ () throws(ClassError) -> Int in throw ClassError() })
}

// CHECK-LABEL: sil private [ossa] @$s{{.*}}9testArrayyyF{{.*}}fU_ : $@convention(thin) @substituted <τ_0_0, τ_0_1> () -> (@out τ_0_1, @error_indirect τ_0_0) for <StructError, Int> {
// CHECK:       bb0(%0 : $*Int, [[ERROR:%.*]] : $*StructError):
// CHECK:         throw_addr
// CHECK:       } // end sil function '$s{{.*}}9testArrayyyF{{.*}}fU_'
func testArray() {
  let _: [() throws(StructError) -> Int] = [
    { () throws(StructError) -> Int in throw StructError(message: "a") }
  ]
}

// CHECK-LABEL: sil private [ossa] @$s{{.*}}12testOptionalyyF{{.*}}fU_ : $@convention(thin) @substituted <τ_0_0, τ_0_1> () -> (@out τ_0_1, @error_indirect τ_0_0) for <EnumError, Int> {
// CHECK:       bb0(%0 : $*Int, [[ERROR:%.*]] : $*EnumError):
// CHECK:         throw_addr
// CHECK:       } // end sil function '$s{{.*}}12testOptionalyyF{{.*}}fU_'
func testOptional() {
  _ = idOptional({ () throws(EnumError) -> Int in throw .c })
}

// CHECK-LABEL: sil private [ossa] @$s{{.*}}9testAsyncyyYaF{{.*}}fU_ : $@convention(thin) @async @substituted <τ_0_0, τ_0_1> () -> (@out τ_0_1, @error_indirect τ_0_0) for <StructError, Int> {
// CHECK:       bb0(%0 : $*Int, [[ERROR:%.*]] : $*StructError):
// CHECK:         throw_addr
// CHECK:       } // end sil function '$s{{.*}}9testAsyncyyYaF{{.*}}fU_'
func testAsync() async {
  _ = await idAsync({ () async throws(StructError) -> Int in
    throw StructError(message: "async")
  })
}

// CHECK-LABEL: sil private [ossa] @$s{{.*}}11testCapture{{.*}}fU_ : $@convention(thin) @substituted <τ_0_0, τ_0_1, τ_0_2> (@in_guaranteed τ_0_0, EnumError) -> (@out τ_0_2, @error_indirect τ_0_1) for <Int, EnumError, Int> {
// CHECK:       bb0(%0 : $*Int, [[ERROR:%.*]] : $*EnumError, %2 : $*Int, %3 : @closureCapture $EnumError):
// CHECK:         throw_addr
// CHECK:       } // end sil function '$s{{.*}}11testCapture{{.*}}fU_'
func testCapture(_ e: EnumError) {
  _ = id({ (x: Int) throws(EnumError) -> Int in
    if x > 0 { throw e }
    return x
  })
}

// CHECK-LABEL: sil private [ossa] @$s{{.*}}18testGenericContext{{.*}}fU_ : $@convention(thin) <U> () -> (@out U, @error_indirect EnumError) {
// CHECK:       bb0(%0 : $*U, [[ERROR:%.*]] : $*EnumError):
// CHECK:         throw_addr
// CHECK:       } // end sil function '$s{{.*}}18testGenericContext{{.*}}fU_'
func testGenericContext<U>(_: U.Type) {
  _ = id({ () throws(EnumError) -> U in throw .a })
}

// CHECK-LABEL: sil private [ossa] @$s{{.*}}8testPackyyF{{.*}}fU_ : $@convention(thin) @substituted <τ_0_0, τ_0_1> () -> (@out τ_0_1, @error_indirect τ_0_0) for <EnumError, Int> {
// CHECK:       bb0(%0 : $*Int, [[ERROR:%.*]] : $*EnumError):
// CHECK:         throw_addr
// CHECK:       } // end sil function '$s{{.*}}8testPackyyF{{.*}}fU_'
func testPack() {
  _ = idPack(1, { () throws(EnumError) -> Int in throw .b })
}

// CHECK-LABEL: sil private [ossa] @$s{{.*}}18testAssociatedTypeyyF{{.*}}fU_ : $@convention(thin) @substituted <τ_0_0, τ_0_1> () -> (@out τ_0_1, @error_indirect τ_0_0) for <EnumError, Int> {
// CHECK:       bb0(%0 : $*Int, [[ERROR:%.*]] : $*EnumError):
// CHECK:         throw_addr
// CHECK:       } // end sil function '$s{{.*}}18testAssociatedTypeyyF{{.*}}fU_'
func testAssociatedType() {
  take(S(), { () throws(EnumError) -> Int in throw .c })
}

// CHECK-LABEL: sil private [ossa] @$s{{.*}}17testSomeParameteryyF{{.*}}fU_ : $@convention(thin) @substituted <τ_0_0, τ_0_1> () -> (@out τ_0_1, @error_indirect τ_0_0) for <EnumError, Int> {
// CHECK:       bb0(%0 : $*Int, [[ERROR:%.*]] : $*EnumError):
// CHECK:         throw_addr
// CHECK:       } // end sil function '$s{{.*}}17testSomeParameteryyF{{.*}}fU_'
func testSomeParameter() {
  takeSome({ () throws(EnumError) -> Int in throw .a })
}

// A generic error type was already thrown indirectly.
// CHECK-LABEL: sil private [ossa] @$s{{.*}}11testGeneric{{.*}}fU_ : $@convention(thin) <E where E : Error> (@in_guaranteed E) -> (@out Int, @error_indirect E) {
// CHECK:       bb0(%0 : $*Int, [[ERROR:%.*]] : $*E, %2 : @closureCapture $*E):
// CHECK:         throw_addr
// CHECK:       } // end sil function '$s{{.*}}11testGeneric{{.*}}fU_'
func testGeneric<E: Error>(_ e: E) {
  _ = id({ () throws(E) -> Int in throw e })
}

// An `any Error` error is still thrown directly.
// CHECK-LABEL: sil private [ossa] @$s{{.*}}11testUntypedyyF{{.*}}fU_ : $@convention(thin) @substituted <τ_0_0> () -> (@out τ_0_0, @error any Error) for <Int> {
// CHECK:       bb0(%0 : $*Int):
// CHECK:         alloc_existential_box $any Error, $EnumError
// CHECK:         throw {{%.*}}
// CHECK:       } // end sil function '$s{{.*}}11testUntypedyyF{{.*}}fU_'
func testUntyped() {
  _ = id({ () throws -> Int in throw EnumError.a })
}

// A closure that does not throw has neither an error result nor an indirect
// error argument.
// CHECK-LABEL: sil private [ossa] @$s{{.*}}9testNeveryyF{{.*}}fU_ : $@convention(thin) @substituted <τ_0_0> () -> @out τ_0_0 for <Int> {
// CHECK:       bb0(%0 : $*Int):
// CHECK-NOT:     "$error"
// CHECK-NOT:     throw
// CHECK:       } // end sil function '$s{{.*}}9testNeveryyF{{.*}}fU_'
func testNever() {
  _ = id({ () throws(Never) -> Int in 1 })
}

// CHECK-LABEL: sil private [ossa] @$s{{.*}}15testNonThrowingyyF{{.*}}fU_ : $@convention(thin) @substituted <τ_0_0> () -> @out τ_0_0 for <Int> {
// CHECK:       bb0(%0 : $*Int):
// CHECK-NOT:     "$error"
// CHECK-NOT:     throw
// CHECK:       } // end sil function '$s{{.*}}15testNonThrowingyyF{{.*}}fU_'
func testNonThrowing() {
  _ = id({ () -> Int in 1 })
}
