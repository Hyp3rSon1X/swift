// RUN: %target-run-simple-swift
// REQUIRES: executable_test

// _swift_stdlib_immortalize is declared in SwiftShims, so Swift code calls it
// through the C declaration, as swift-collections does. On WebAssembly the call
// does not link (or traps) if the runtime defines it with a different calling
// convention than the header declares.

import StdlibUnittest
import SwiftShims

var deinitCount = 0

final class Canary {
  deinit { deinitCount += 1 }
}

let ImmortalizeTests = TestSuite("Immortalize")

ImmortalizeTests.test("ImmortalObjectIsNotFreed") {
  do {
    let object = Canary()
    _swift_stdlib_immortalize(Unmanaged.passUnretained(object).toOpaque())
    // Releases without a matching retain must not free an immortal object.
    for _ in 0..<10 {
      Unmanaged.passUnretained(object).release()
    }
    _fixLifetime(object)
  }
  expectEqual(0, deinitCount)
}

runAllTests()
