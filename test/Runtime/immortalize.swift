// RUN: %target-run-simple-swift | %FileCheck %s
// REQUIRES: executable_test
// UNSUPPORTED: use_os_stdlib
// UNSUPPORTED: back_deployment_runtime

// _swift_stdlib_immortalize is declared in SwiftShims, so Swift code calls it
// through the C declaration, as swift-collections does. On WebAssembly the
// call does not link (or traps) if the runtime defines the function with a
// different calling convention than the header declares.

import SwiftShims

var deinitCount = 0

final class Canary {
  deinit { deinitCount += 1 }
}

do {
  let object = Canary()
  let unmanaged = Unmanaged.passUnretained(object)
  _swift_stdlib_immortalize(unmanaged.toOpaque())
  let immortalCount = _getRetainCount(object)

  // Retains and releases, balanced or not, must leave the reference count of
  // an immortal object unchanged.
  unmanaged.release()
  // CHECK: release: unchanged
  print("release:", _getRetainCount(object) == immortalCount ? "unchanged" : "changed")

  for _ in 0..<1000 {
    _ = unmanaged.retain()
    unmanaged.release()
  }
  // CHECK: retain/release pairs: unchanged
  print("retain/release pairs:",
        _getRetainCount(object) == immortalCount ? "unchanged" : "changed")

  for _ in 0..<10 {
    unmanaged.release()
  }
  // CHECK: releases: unchanged
  print("releases:", _getRetainCount(object) == immortalCount ? "unchanged" : "changed")

  _fixLifetime(object)
}

// An immortal object is never freed.
// CHECK: deinit count: 0
print("deinit count:", deinitCount)
