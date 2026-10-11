// RUN: %target-run-simple-swift( -target %target-swift-5.1-abi-triple -parse-as-library -enable-upcoming-feature NonisolatedNonsendingByDefault) | %FileCheck %s
// RUN: %target-run-simple-swift( -target %target-swift-5.1-abi-triple -parse-as-library -enable-upcoming-feature NonisolatedNonsendingByDefault -O) | %FileCheck %s

// REQUIRES: concurrency
// REQUIRES: executable_test
// REQUIRES: concurrency_runtime
// REQUIRES: swift_feature_NonisolatedNonsendingByDefault

// UNSUPPORTED: back_deployment_runtime
// UNSUPPORTED: freestanding

// `#isolation` converted to its contextual type in nonisolated(nonsending)
// code and in actor initializers.

protocol P {}

func show(_ label: String, _ value: Any) { print(label, value) }

func run(_ body: @escaping @Sendable () async -> Bool) async -> Bool {
  await body()
}

@MainActor func onMainActor() async -> Bool {
  await run { #isolation === MainActor.shared }
}

@concurrent func onGenericExecutor() async -> Bool {
  await run { #isolation === MainActor.shared }
}

func describe(_ iso: (any Actor)??, _ object: AnyObject?, _ any: Any) -> String {
  "\(iso as Any) \(object as Any) \(any)"
}

func describeIsolation() async -> String {
  describe(#isolation, #isolation, #isolation)
}

actor A: P {
  var x: Int

  func identity() async -> Bool { await run { #isolation === self } }
  func isolation() async -> String { await describeIsolation() }

  init() async {
    show("concrete:", #isolation as A?)
    show("composition:", #isolation as (any Actor & P)?)
    show("double:", #isolation as (any Actor)??)
    x = 0
    show("concrete:", #isolation as A?)
    show("composition:", #isolation as (any Actor & P)?)
    show("double:", #isolation as (any Actor)??)
    show("anyobject:", #isolation as AnyObject?)
  }
}

@main struct Main {
  static func main() async {
    // CHECK: main: true
    print("main:", await onMainActor())
    // CHECK-NEXT: concurrent: false
    print("concurrent:", await onGenericExecutor())
    // CHECK-NEXT: main: Optional(Optional(Swift.MainActor)) Optional(Swift.MainActor) Optional(Swift.MainActor)
    print("main:", await describeIsolation())
    // CHECK-NEXT: concrete: nil
    // CHECK-NEXT: composition: nil
    // CHECK-NEXT: double: Optional(nil)
    // CHECK-NEXT: concrete: Optional(main.A)
    // CHECK-NEXT: composition: Optional(main.A)
    // CHECK-NEXT: double: Optional(Optional(main.A))
    // CHECK-NEXT: anyobject: Optional(main.A)
    let a = await A()
    // CHECK-NEXT: actor: true
    print("actor:", await a.identity())
    // CHECK-NEXT: actor: Optional(Optional(main.A)) Optional(main.A) Optional(main.A)
    print("actor:", await a.isolation())
  }
}
