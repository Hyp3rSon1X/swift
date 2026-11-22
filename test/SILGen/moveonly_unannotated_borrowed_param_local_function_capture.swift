// RUN: %target-swift-emit-sil -verify %s

// An unannotated closure parameter is borrowed if the closure's type says so,
// or if neither the parameter nor the closure's type specifies an ownership.
// A local function may capture it like an explicitly `borrowing` one, and an
// escaping closure that captures it is diagnosed instead of crashing SILGen.

struct Handle: ~Copyable {
  borrowing func check() {}
}

func take(_ h: borrowing Handle) {}

func run(_ f: @escaping () -> Void) { f() }

func withHandle<T>(_ body: (borrowing Handle) -> T) -> T {
  let handle = Handle()
  return body(handle)
}

func captureInLocalFunction() {
  withHandle { handle in
    func invoke() {
      handle.check()
    }
    invoke()
  }
}

func captureExplicitlyBorrowingInLocalFunction() {
  withHandle { (handle: borrowing Handle) in
    func invoke() {
      handle.check()
    }
    invoke()
  }
}

func captureInferredInLocalFunction() {
  let g = { h in
    take(h)
    func local() {
      h.check()
    }
    local()
  }
  g(Handle())
}

func captureInferredInEscapingClosure() {
  let g = { h in
    // expected-error @-1 {{'h' cannot be captured by an escaping closure since it is a borrowed parameter}}
    take(h)
    run { // expected-note {{closure capturing 'h' here}}
      h.check()
    }
  }
  g(Handle())
}
