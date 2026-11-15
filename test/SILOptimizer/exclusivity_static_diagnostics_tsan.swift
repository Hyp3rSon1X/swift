// RUN: %target-swift-frontend -emit-sil -verify %s -o /dev/null
// RUN: %target-swift-frontend -emit-sil -verify -sanitize=thread %s -o /dev/null

// REQUIRES: tsan_runtime

// Thread Sanitizer instrumentation must not change static exclusivity
// diagnostics. Accesses to disjoint stored properties of a noncopyable struct
// don't conflict, with or without instrumentation, and real conflicts are
// still diagnosed.

func takesTwoInouts<T>(_ p1: inout T, _ p2: inout T) { }

final class Box {
  var value = 0
}

struct Inner {
  var x = 0

  mutating func add(_ v: inout Int) { x += v }
}

struct NoncopyableSink: ~Copyable {
  let box: Box
  var inner = Inner()
  var other = Inner()

  // The modify of 'self.inner' doesn't overlap the read of 'self.box'.
  mutating func modifyWhileReadingLetClassRef() {
    inner.add(&box.value)
  }

  mutating func modifyDisjointStoredProperties() {
    takesTwoInouts(&inner, &other)
  }

  mutating func modifySameStoredPropertyTwice() {
    takesTwoInouts(&inner, &inner)
    // expected-error@-1{{overlapping accesses to 'self.inner', but modification requires exclusive access; consider copying to a local variable}}
    // expected-note@-2{{conflicting access is here}}
  }
}

struct CopyableSink {
  let box: Box
  var inner = Inner()

  mutating func modifyWhileReadingLetClassRef() {
    inner.add(&box.value)
  }
}
