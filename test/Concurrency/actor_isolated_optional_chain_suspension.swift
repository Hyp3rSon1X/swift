// RUN: %target-swift-frontend -target %target-swift-5.1-abi-triple -parse-as-library -typecheck -verify -verify-additional-prefix swift5- -swift-version 5 %s
// RUN: %target-swift-frontend -target %target-swift-5.1-abi-triple -parse-as-library -typecheck -verify -verify-additional-prefix swift5- -swift-version 5 -strict-concurrency=complete %s
// RUN: %target-swift-frontend -target %target-swift-5.1-abi-triple -parse-as-library -typecheck -verify -verify-additional-prefix swift6- -swift-version 6 %s

// REQUIRES: concurrency

// An optional-chained mutation begins its access to the base at the '?',
// before the parts of the expression that are only evaluated when the base is
// not nil. When one of those parts suspends, other tasks run on the actor
// while the access to its state is still in progress.

struct Entry {
  var x = 0
  var list: [Int] = []
  var inner: Inner? = nil
  var handler: (@Sendable () async -> Int)? = nil

  struct Inner { var y = 0 }

  mutating func set(_ value: Int) { x = value }
  mutating func setAsync(_ value: Int) async { x = value }
  mutating func setHandler(_ handler: @escaping @Sendable () async -> Int) {
    self.handler = handler
  }
  func describe(_ value: Int) -> String { "\(x) \(value)" }
}

final class Ref {
  var value = 0
}

final class Holder {
  var entries: [Int: Entry] = [:]
}

final class SafeHolder: @unchecked Sendable {
  var entries: [Int: Entry] = [:]
}

protocol Mutable {
  mutating func mutate(_ value: Int)
}

struct Counter: Mutable {
  var value = 0
  mutating func mutate(_ value: Int) { self.value = value }
}

func compute() async -> Int { 0 }
func computeThrowing() async throws -> Int { 0 }
func update(_ value: inout Int) async {}

infix operator <-- : AssignmentPrecedence
func <-- (lhs: inout Int, rhs: Int) { lhs = rhs }

actor Other {
  var count = 0
  func value() -> Int { count }
}

actor Box {
  var entries: [Int: Entry] = [:] // expected-note {{property declared here}}
  var opt: Entry? = nil
  var state = State()
  var ref: Ref? = nil
  let other = Other()
  let holder = Holder()
  var holderVar = Holder()
  var holderOpt: Holder? = nil
  let safeHolder = SafeHolder()
  var safeHolderVar = SafeHolder()
  nonisolated(unsafe) var unsafeHolder = Holder()
  var mutable: (any Mutable)? = nil
  var tuple: (Entry?, Int) = (nil, 0)

  var computed: Entry? {
    get { opt }
    set { opt = newValue }
  }

  struct State {
    var entries: [Int: Entry] = [:]
    var count = 0
  }

  subscript(key: Int) -> Entry? {
    get { entries[key] }
    set { entries[key] = newValue }
  }

  func slow() async -> Int { 0 }

  func assignment(_ k: Int) async {
    entries[k]?.x = await slow()
    // expected-warning@-1:21 {{actor-isolated property 'entries' is accessed across a suspension point in an optional-chained mutation; the mutation may lose concurrent updates}}
    // expected-note@-2:15 {{optional chaining begins the access to 'entries' here, before the suspension point}}
    // expected-note@-3:21 {{move the 'await' into a local constant before the optional-chained mutation}}
  }

  func compoundAssignment(_ k: Int) async {
    entries[k]?.x += await slow()
    // expected-warning@-1:22 {{actor-isolated property 'entries' is accessed across a suspension point}}
    // expected-note@-2:15 {{optional chaining begins the access to 'entries' here}}
    // expected-note@-3:22 {{move the 'await' into a local constant}}

    entries[k]?.x <-- await slow()
    // expected-warning@-1:23 {{actor-isolated property 'entries' is accessed across a suspension point}}
    // expected-note@-2:15 {{optional chaining begins the access to 'entries' here}}
    // expected-note@-3:23 {{move the 'await' into a local constant}}
  }

  func mutatingCall(_ k: Int) async {
    entries[k]?.set(await slow())
    // expected-warning@-1:21 {{actor-isolated property 'entries' is accessed across a suspension point}}
    // expected-note@-2:15 {{optional chaining begins the access to 'entries' here}}
    // expected-note@-3:21 {{move the 'await' into a local constant}}

    entries[k]?.list.append(await slow())
    // expected-warning@-1:29 {{actor-isolated property 'entries' is accessed across a suspension point}}
    // expected-note@-2:15 {{optional chaining begins the access to 'entries' here}}
    // expected-note@-3:29 {{move the 'await' into a local constant}}
  }

  func indexAfterTheChain(_ k: Int) async {
    entries[k]?.list[await slow()] = 1
    // expected-warning@-1:22 {{actor-isolated property 'entries' is accessed across a suspension point}}
    // expected-note@-2:15 {{optional chaining begins the access to 'entries' here}}
    // expected-note@-3:22 {{move the 'await' into a local constant}}

    entries[k]?.list[await slow()] += 1
    // expected-warning@-1:22 {{actor-isolated property 'entries' is accessed across a suspension point}}
    // expected-note@-2:15 {{optional chaining begins the access to 'entries' here}}
    // expected-note@-3:22 {{move the 'await' into a local constant}}
  }

  func optionalStoredProperty() async {
    opt?.x = await slow()
    // expected-warning@-1:14 {{actor-isolated property 'opt' is accessed across a suspension point}}
    // expected-note@-2:8 {{optional chaining begins the access to 'opt' here}}
    // expected-note@-3:14 {{move the 'await' into a local constant}}

    self.opt?.set(await slow())
    // expected-warning@-1:19 {{actor-isolated property 'opt' is accessed across a suspension point}}
    // expected-note@-2:13 {{optional chaining begins the access to 'opt' here}}
    // expected-note@-3:19 {{move the 'await' into a local constant}}

    opt?.inner?.y = await slow()
    // expected-warning@-1:21 {{actor-isolated property 'opt' is accessed across a suspension point}}
    // expected-note@-2:8 {{optional chaining begins the access to 'opt' here}}
    // expected-note@-3:21 {{move the 'await' into a local constant}}
  }

  func nestedStorage(_ k: Int) async {
    state.entries[k]?.x = await slow()
    // expected-warning@-1:27 {{actor-isolated property 'state' is accessed across a suspension point}}
    // expected-note@-2:21 {{optional chaining begins the access to 'state' here}}
    // expected-note@-3:27 {{move the 'await' into a local constant}}
  }

  func actorSubscript(_ k: Int) async {
    self[k]?.x = await slow()
    // expected-warning@-1:18 {{actor-isolated subscript 'subscript(_:)' is accessed across a suspension point}}
    // expected-note@-2:12 {{optional chaining begins the access to 'subscript(_:)' here}}
    // expected-note@-3:18 {{move the 'await' into a local constant}}
  }

  func otherSuspensionPoints(_ k: Int) async throws {
    // 'await' covering the whole assignment.
    await entries[k]?.x = slow()
    // expected-warning@-1:27 {{actor-isolated property 'entries' is accessed across a suspension point}}
    // expected-note@-2:21 {{optional chaining begins the access to 'entries' here}}
    // expected-note@-3:27 {{move the 'await' into a local constant}}

    entries[k]?.x = try await computeThrowing()
    // expected-warning@-1:25 {{actor-isolated property 'entries' is accessed across a suspension point}}
    // expected-note@-2:15 {{optional chaining begins the access to 'entries' here}}
    // expected-note@-3:25 {{move the 'await' into a local constant}}

    // Implicitly asynchronous accesses to another actor.
    entries[k]?.x = await other.value()
    // expected-warning@-1:21 {{actor-isolated property 'entries' is accessed across a suspension point}}
    // expected-note@-2:15 {{optional chaining begins the access to 'entries' here}}
    // expected-note@-3:21 {{move the 'await' into a local constant}}

    entries[k]?.x = await other.count
    // expected-warning@-1:21 {{actor-isolated property 'entries' is accessed across a suspension point}}
    // expected-note@-2:15 {{optional chaining begins the access to 'entries' here}}
    // expected-note@-3:21 {{move the 'await' into a local constant}}

    async let value = slow()
    entries[k]?.x = await value
    // expected-warning@-1:21 {{actor-isolated property 'entries' is accessed across a suspension point}}
    // expected-note@-2:15 {{optional chaining begins the access to 'entries' here}}
    // expected-note@-3:21 {{move the 'await' into a local constant}}
  }

  func otherAccessPaths(_ k: Int) async {
    mutable?.mutate(await slow())
    // expected-warning@-1:21 {{actor-isolated property 'mutable' is accessed across a suspension point}}
    // expected-note@-2:12 {{optional chaining begins the access to 'mutable' here}}
    // expected-note@-3:21 {{move the 'await' into a local constant}}

    computed?.x = await slow()
    // expected-warning@-1:19 {{actor-isolated property 'computed' is accessed across a suspension point}}
    // expected-note@-2:13 {{optional chaining begins the access to 'computed' here}}
    // expected-note@-3:19 {{move the 'await' into a local constant}}

    tuple.0?.x = await slow()
    // expected-warning@-1:18 {{actor-isolated property 'tuple' is accessed across a suspension point}}
    // expected-note@-2:12 {{optional chaining begins the access to 'tuple' here}}
    // expected-note@-3:18 {{move the 'await' into a local constant}}

    entries[k]?[keyPath: \Entry.x] = await slow()
    // expected-warning@-1:38 {{actor-isolated property 'entries' is accessed across a suspension point}}
    // expected-note@-2:15 {{optional chaining begins the access to 'entries' here}}
    // expected-note@-3:38 {{move the 'await' into a local constant}}

    entries[k]?.x = await { await compute() }()
    // expected-warning@-1:21 {{actor-isolated property 'entries' is accessed across a suspension point}}
    // expected-note@-2:15 {{optional chaining begins the access to 'entries' here}}
    // expected-note@-3:21 {{move the 'await' into a local constant}}

    _ = (entries[k]?.x = await slow())
    // expected-warning@-1:26 {{actor-isolated property 'entries' is accessed across a suspension point}}
    // expected-note@-2:20 {{optional chaining begins the access to 'entries' here}}
    // expected-note@-3:26 {{move the 'await' into a local constant}}
  }

  // A non-Sendable class instance that is only reachable from the actor's
  // state is protected by the actor too.
  func classInstanceOwnedByTheActor(_ k: Int) async {
    holder.entries[k]?.x = await slow()
    // expected-warning@-1:28 {{actor-isolated property 'holder' is accessed across a suspension point}}
    // expected-note@-2:22 {{optional chaining begins the access to 'holder' here}}
    // expected-note@-3:28 {{move the 'await' into a local constant}}

    holderVar.entries[k]?.list.append(await slow())
    // expected-warning@-1:39 {{actor-isolated property 'holderVar' is accessed across a suspension point}}
    // expected-note@-2:25 {{optional chaining begins the access to 'holderVar' here}}
    // expected-note@-3:39 {{move the 'await' into a local constant}}

    holderOpt?.entries[k]?.x += await slow()
    // expected-warning@-1:33 {{actor-isolated property 'holderOpt' is accessed across a suspension point}}
    // expected-note@-2:26 {{optional chaining begins the access to 'holderOpt' here}}
    // expected-note@-3:33 {{move the 'await' into a local constant}}
  }

  func inheritedIsolation(_ k: Int) {
    Task {
      self.entries[k]?.x = await self.slow()
      // expected-warning@-1:28 {{actor-isolated property 'entries' is accessed across a suspension point}}
      // expected-note@-2:22 {{optional chaining begins the access to 'entries' here}}
      // expected-note@-3:28 {{move the 'await' into a local constant}}
    }
  }

  // MARK: Not diagnosed

  func hoisted(_ k: Int) async {
    let value = await slow()
    entries[k]?.x = value
    entries[k]?.x += value
    entries[k]?.set(value)
  }

  func noSuspension(_ k: Int) {
    entries[k]?.x = 1
    entries[k]?.x += 1
    entries[k]?.set(2)
    opt?.x = entries.count
  }

  func accessBeginsAfterTheRightHandSide(_ k: Int) async {
    entries[k]!.x = await slow()
    entries[k]!.x += await slow()
    entries[k]!.set(await slow())
    entries[k, default: Entry()].x = await slow()
    entries[k, default: Entry()].x += await slow()
    state.count = await slow()
    state.count += await slow()
    opt!.x = await slow()
  }

  func suspensionBeforeTheChain() async {
    entries[await slow()]?.x = 1
    state.entries[await slow()]?.x += 1
  }

  func referenceThroughTheChain() async {
    // Only the reference is read; the class property is set after the
    // suspension.
    ref?.value = await slow()
    ref?.value += await slow()
  }

  func closuresAreNotEvaluatedInPlace(_ k: Int) {
    entries[k]?.handler = { await compute() }
    entries[k]?.setHandler { await self.slow() }
  }

  func reads(_ k: Int) async -> String? {
    let x = entries[k]?.x
    _ = x
    _ = entries[k]?.describe(await slow())
    return opt?.describe(await slow())
  }

  func classInstancesNotOwnedByTheActor(_ k: Int) async {
    let local = Holder()
    local.entries[k]?.x = await slow()
    // Sendable classes protect their own state.
    safeHolder.entries[k]?.x = await slow()
    safeHolderVar.entries[k]?.x = await slow()
    unsafeHolder.entries[k]?.x = await slow()
  }

  func localState(_ k: Int) async {
    var local: [Int: Entry] = entries
    local[k]?.x = await slow()
    local[k]?.x += await slow()
    local[k]?.set(await slow())
    var localOpt = opt
    localOpt?.x = await slow()
    entries = local
    opt = localOpt
  }

  nonisolated func nonisolatedContext(_ k: Int) async {
    var copy = await entries
    copy[k]?.x = await compute()
  }

  // Already rejected because the access is held across the async call itself.
  func asyncMutation(_ k: Int) async {
    await entries[k]?.setAsync(await slow())
    // expected-swift5-warning@-1 {{cannot call mutating async function 'setAsync' on actor-isolated property 'entries'}}
    // expected-swift6-error@-2 {{cannot call mutating async function 'setAsync' on actor-isolated property 'entries'}}
    // expected-note@-3 {{'entries' can be concurrently accessed during mutation, risking data races}}

    await update(&entries[k, default: Entry()].x)
    // expected-error@-1 {{actor-isolated property 'entries' cannot be passed 'inout' to 'async' function call}}
  }
}

func isolatedParameter(_ box: isolated Box, _ k: Int) async {
  box.entries[k]?.x = await compute()
  // expected-warning@-1:23 {{actor-isolated property 'entries' is accessed across a suspension point}}
  // expected-note@-2:17 {{optional chaining begins the access to 'entries' here}}
  // expected-note@-3:23 {{move the 'await' into a local constant}}
}

func nonisolatedFunction(_ box: Box, _ k: Int) async {
  var entries = await box.entries
  entries[k]?.x = await compute()
}

@MainActor var globalEntries: [Int: Entry] = [:]

@MainActor func mainActorSlow() async -> Int { 0 }

@MainActor func globalActorIsolatedGlobal(_ k: Int) async {
  globalEntries[k]?.x = await mainActorSlow()
  // expected-warning@-1:25 {{actor-isolated var 'globalEntries' is accessed across a suspension point}}
  // expected-note@-2:19 {{optional chaining begins the access to 'globalEntries' here}}
  // expected-note@-3:25 {{move the 'await' into a local constant}}

  globalEntries[k]?.list.append(await compute())
  // expected-warning@-1:33 {{actor-isolated var 'globalEntries' is accessed across a suspension point}}
  // expected-note@-2:19 {{optional chaining begins the access to 'globalEntries' here}}
  // expected-note@-3:33 {{move the 'await' into a local constant}}

  let value = await mainActorSlow()
  globalEntries[k]?.x = value
}

@MainActor final class Model {
  var entries: [Int: Entry] = [:]
  static var shared: [Int: Entry] = [:]
  let holder = Holder()

  func update(_ k: Int) async {
    entries[k]?.x += await compute()
    // expected-warning@-1:22 {{actor-isolated property 'entries' is accessed across a suspension point}}
    // expected-note@-2:15 {{optional chaining begins the access to 'entries' here}}
    // expected-note@-3:22 {{move the 'await' into a local constant}}

    Model.shared[k]?.x = await compute()
    // expected-warning@-1:26 {{actor-isolated static property 'shared' is accessed across a suspension point}}
    // expected-note@-2:20 {{optional chaining begins the access to 'shared' here}}
    // expected-note@-3:26 {{move the 'await' into a local constant}}

    holder.entries[k]?.x = await compute()
    // expected-warning@-1:28 {{actor-isolated property 'holder' is accessed across a suspension point}}
    // expected-note@-2:22 {{optional chaining begins the access to 'holder' here}}
    // expected-note@-3:28 {{move the 'await' into a local constant}}
  }
}
