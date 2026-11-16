// RUN: %target-swift-frontend %s -emit-sil \
// RUN:   -target %target-swift-6.2-abi-triple \
// RUN:   -o /dev/null \
// RUN:   -verify \
// RUN:   -sil-verify-all \
// RUN:   -module-name test \
// RUN:   -enable-experimental-feature Lifetimes

// REQUIRES: swift_feature_Lifetimes

// Test dependencies on the standard library Span APIs.

// =============================================================================
// Span-providing properties
// =============================================================================

extension UnsafeRawBufferPointer {
  public var storage: RawSpan {
    @_lifetime(borrow self)
    get {
      let span = RawSpan(_unsafeBytes: self)
      return _overrideLifetime(span, borrowing: self)
    }
  }
}

func read(_ span: RawSpan) {}

func testUBPStorage(ubp: UnsafeRawBufferPointer) {
  // 'span' is valid within the lexical scope of variable 'ubp', which is the entire function.
  let span = ubp.storage
  read(span)
}

@_lifetime(borrow ubp)
func testUBPStorageReturn(ubp: UnsafeRawBufferPointer) -> RawSpan {
  // 'storage' can be returned since the function's return value also has a dependence on 'ubp'.
  return ubp.storage
}

@_lifetime(borrow ubp)
func testUBPStorageCopy(ubp: UnsafeRawBufferPointer) -> RawSpan {
  let localBuffer = ubp
  return localBuffer.storage // expected-error {{lifetime-dependent value escapes its scope}}
                             // expected-note  @-2{{it depends on the lifetime of variable 'localBuffer'}}
                             // expected-note  @-2{{this use causes the lifetime-dependent value to escape}}
}

func testUBPStorageEscape(array: [Int64]) {
  var span = RawSpan()  // expected-error{{lifetime-dependent variable 'span' escapes its scope}}
  array.withUnsafeBytes {  // expected-note{{it depends on the lifetime of argument '$0'}}
    span = $0.storage
  } // expected-note{{this use causes the lifetime-dependent value to escape}}
  read(span)
}

// =============================================================================
// Spans of a throwing call's result
// =============================================================================

enum MakeError: Error { case failed }

func makeArray(_ n: Int) throws -> [Int] { Array(repeating: 1, count: n) }

func makeArrayTyped(_ n: Int) throws(MakeError) -> [Int] { Array(repeating: 1, count: n) }

func total(_ span: Span<Int>) -> Int {
  var sum = 0
  for i in span.indices { sum += span[i] }
  return sum
}

// The array is the normal result of a try_apply. Its lifetime is extended over the span's use only on the normal
// path; the error path must not destroy it (swiftlang/swift#92412).
func testThrowingResultSpan(n: Int) throws -> Int {
  total(try makeArray(n).span)
}

func testTypedThrowingResultBytes(n: Int) throws(MakeError) {
  read(try makeArrayTyped(n).span.bytes)
}
