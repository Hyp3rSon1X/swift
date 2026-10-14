// RUN: %target-swift-frontend -emit-sil -o /dev/null -verify -swift-version 6 -target %target-swift-6.0-abi-triple -parse-as-library %s
// RUN: %target-swift-frontend -emit-sil -o /dev/null -verify -swift-version 6 -target %target-swift-6.0-abi-triple -parse-as-library -enable-upcoming-feature NonisolatedNonsendingByDefault %s

// REQUIRES: concurrency
// REQUIRES: swift_feature_NonisolatedNonsendingByDefault

// In nonisolated(nonsending) code, `#isolation` is the isolation of the
// caller. Passing it to an isolated parameter, explicitly, as a default
// argument or through the `next(isolation:)` call of a for-await loop, does
// not cross an isolation boundary, so the caller can use non-Sendable results.

final class NonSendable { // expected-note 2 {{class 'NonSendable' does not conform to the 'Sendable' protocol}}
  var x = 0
}

actor A {}

func pass<T>(
  _ value: T, isolation: isolated (any Actor)? = #isolation
) async -> T {
  value
}

func passSynchronously<T>(
  _ value: T, isolation: isolated (any Actor)? = #isolation
) -> T {
  value
}

struct NonSendableSequence: AsyncSequence {
  struct AsyncIterator: AsyncIteratorProtocol {
    mutating func next() async -> NonSendable? { nil }
  }

  func makeAsyncIterator() -> AsyncIterator { AsyncIterator() }
}

// The shape of the expansion of Swift Testing's `#expect(processExitsWith:)`.
func requiringAwait<T>(
  _ value: consuming T, isolation: isolated (any Actor)? = #isolation
) async -> T {
  value
}

func work() {}

nonisolated(nonsending) func defaultArgument() async -> Int {
  let value = await pass(NonSendable())
  return value.x
}

nonisolated(nonsending) func explicitArgument() async -> Int {
  let value = await pass(NonSendable(), isolation: #isolation)
  return value.x
}

nonisolated(nonsending) func synchronousCallee() async -> Int {
  let first = passSynchronously(NonSendable())
  let second = passSynchronously(NonSendable(), isolation: #isolation)
  return first.x + second.x
}

nonisolated(nonsending) func forAwait() async -> Int {
  var sum = 0
  for await value in NonSendableSequence() {
    sum += value.x
  }
  return sum
}

nonisolated(nonsending) func iteratorNext() async -> Int {
  var iterator = NonSendableSequence().makeAsyncIterator()
  return await iterator.next(isolation: #isolation)?.x ?? 0
}

nonisolated(nonsending) func closureResult() async {
  _ = await requiringAwait({ _ = NonSendable() })()
}

nonisolated(nonsending) func inClosure() async -> Int {
  let closure: nonisolated(nonsending) () async -> Int = {
    let value = await pass(NonSendable())
    return value.x
  }
  return await closure()
}

// With NonisolatedNonsendingByDefault, these are nonisolated(nonsending);
// otherwise they are @concurrent and `#isolation` is nil.

func defaultArgumentByDefault() async -> Int {
  let value = await pass(NonSendable())
  return value.x
}

func explicitArgumentByDefault() async -> Int {
  let value = await pass(NonSendable(), isolation: #isolation)
  return value.x
}

func synchronousCalleeByDefault() async -> Int {
  passSynchronously(NonSendable()).x
}

func forAwaitByDefault() async -> Int {
  var sum = 0
  for await value in NonSendableSequence() {
    sum += value.x
  }
  return sum
}

@Sendable func closureResultByDefault() async {
  _ = await requiringAwait({ work() })()
}

// Callers with other isolation were not affected.

@concurrent func forAwaitConcurrent() async -> Int {
  var sum = 0
  for await value in NonSendableSequence() {
    sum += value.x
  }
  return sum
}

@MainActor func forAwaitMainActor() async -> Int {
  var sum = 0
  for await value in NonSendableSequence() {
    sum += value.x
  }
  return sum
}

// Passing an actor other than `#isolation` still crosses an isolation
// boundary.

nonisolated(nonsending) func otherActor(_ a: A) async -> Int {
  let value = await pass(NonSendable(), isolation: a) // expected-error {{non-Sendable 'NonSendable'-typed result can not be returned from actor-isolated global function 'pass(_:isolation:)' to}}
  return value.x
}

nonisolated(nonsending) func mainActor() async -> Int {
  let value = await pass(NonSendable(), isolation: MainActor.shared) // expected-error {{non-Sendable 'NonSendable'-typed result can not be returned from main actor-isolated global function 'pass(_:isolation:)' to}}
  return value.x
}
