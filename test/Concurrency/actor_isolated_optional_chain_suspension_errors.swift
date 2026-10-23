// RUN: %target-swift-frontend -target %target-swift-5.1-abi-triple -parse-as-library -typecheck -verify -swift-version 6 -Werror ActorIsolatedOptionalChainSuspension %s
// RUN: %if swift7 %{ %target-swift-frontend -target %target-swift-5.1-abi-triple -parse-as-library -typecheck -verify -swift-version 7 %s %}

// REQUIRES: concurrency

// The diagnostic is a warning until the next language mode, and it can be
// promoted to an error with its diagnostic group.

struct Entry {
  var x = 0
}

actor Box {
  var entries: [Int: Entry] = [:]

  func slow() async -> Int { 0 }

  func assignment(_ k: Int) async {
    entries[k]?.x = await slow()
    // expected-error@-1 {{actor-isolated property 'entries' is accessed across a suspension point in an optional-chained mutation; the mutation may lose concurrent updates}}
    // expected-note@-2 {{optional chaining begins the access to 'entries' here, before the suspension point}}
    // expected-note@-3 {{move the 'await' into a local constant before the optional-chained mutation}}
  }
}
