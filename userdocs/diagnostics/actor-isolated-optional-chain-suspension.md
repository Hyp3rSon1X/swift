# Mutating actor-isolated state through an optional chain across a suspension point (ActorIsolatedOptionalChainSuspension)

## Overview

An optional-chained mutation of actor-isolated state keeps its access to that state open while the rest of the expression is evaluated. If the rest of the expression suspends, other tasks can run on the actor and change the same state, and those changes are lost or corrupted when the mutation completes. To resolve this warning, move the `await` into a local constant before the mutation.

For example:

```swift
struct Entry {
  var estimate = 0
  var waiters = 0
}

func computeEstimate(_ id: Int) async -> Int {
  try? await Task.sleep(for: .seconds(1))
  return 42
}

actor Scheduler {
  var entries: [Int: Entry] = [:]

  func refresh(_ id: Int) async {
    entries[id]?.estimate = await computeEstimate(id)
  }

  func addWaiter(_ id: Int) {
    entries[id]?.waiters += 1
  }
}
```

Building the above code produces a warning about the access to `entries`:

```
|   func refresh(_ id: Int) async {
|     entries[id]?.estimate = await computeEstimate(id)
|                |            |- warning: actor-isolated property 'entries' is accessed across a suspension point in an optional-chained mutation; the mutation may lose concurrent updates; this will be an error in a future Swift language mode [#ActorIsolatedOptionalChainSuspension]
|                |            `- note: move the 'await' into a local constant before the optional-chained mutation
|                `- note: optional chaining begins the access to 'entries' here, before the suspension point
|   }
```

The right-hand side of an optional-chained assignment is only evaluated if the optional is not `nil`, so the optional has to be accessed and checked first. The access to `entries[id]` begins at the `?` and lasts until the assignment completes, which is after `computeEstimate` returns. The same is true for compound assignments such as `entries[id]?.estimate += await computeEstimate(id)`, for the arguments of a mutating method called through the chain such as `entries[id]?.update(await computeEstimate(id))`, and for subscript indices after the `?`.

While `refresh` is suspended, the actor is free to run `addWaiter`. Dynamic exclusivity checking does not detect conflicting accesses from different tasks. The dictionary's subscript has moved the entry out of its storage for the duration of the access, so the increment from `addWaiter` is overwritten when `refresh` resumes and writes the entry back. If the dictionary is modified in other ways during the suspension, for example by removing or inserting entries, the write-back can corrupt memory.

```swift
// Task 1: refresh(1)                     | // Task 2
entries[1]?.estimate = await ...          |
// begins access to entries[1]            |
// suspends...                            |
//                                        | addWaiter(1)
//                                        | // entries[1]?.waiters is now 1
// resumes, computeEstimate returns 42    |
// writes back entries[1]                 |
// (estimate: 42, waiters: 0)             |
// addWaiter(1) was silently lost!        |
```

Evaluate the asynchronous part first, then perform the mutation synchronously:

```swift
func refresh(_ id: Int) async {
  let estimate = await computeEstimate(id)
  entries[id]?.estimate = estimate
}
```

Because the mutation is synchronous, no other task can run on the actor while it is in progress. Note that the entry may have been removed during the suspension, in which case the optional chain skips the assignment.

This warning will become an error in a future language mode.

## See also

- [Optional Chaining](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/optionalchaining)
- [Calling a mutating async actor-isolated method (ActorIsolatedMutatingAsync)](actor-isolated-mutating-async.md)
- [Overlapping accesses, but operation requires exclusive access (ExclusivityViolation)](exclusivity-violation.md)
