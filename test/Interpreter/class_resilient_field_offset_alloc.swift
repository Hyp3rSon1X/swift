// RUN: %empty-directory(%t)

// RUN: %target-build-swift-dylib(%t/%target-library-name(resilient_struct)) -enable-library-evolution %S/../Inputs/resilient_struct.swift -emit-module -emit-module-path %t/resilient_struct.swiftmodule -module-name resilient_struct
// RUN: %target-codesign %t/%target-library-name(resilient_struct)

// RUN: %target-build-swift -O -wmo %s -I %t -L %t -lresilient_struct -o %t/main %target-rpath(%t)
// RUN: %target-codesign %t/main

// RUN: %target-run %t/main %t/%target-library-name(resilient_struct) | %FileCheck %s

// REQUIRES: executable_test

// The first Segment is allocated by the call that also initializes Segment's
// metadata, and with it the field offset global of 'isSealed' (its offset
// depends on the resilient 'Size'). The store of 'isSealed' into the new
// instance must use the initialized offset, not the placeholder, which would
// overwrite the object header.

import resilient_struct

final class Segment {
  var desired: Size
  var isSealed = false

  init(desired: Size) {
    self.desired = desired
  }
}

final class Owner {
  var current: Segment?

  @inline(never)
  func offer(_ size: Size) -> Bool {
    if let segment = current, !segment.isSealed {
      segment.desired = size
      return true
    }
    current = Segment(desired: size)
    return false
  }
}

// Same for a generic class, whose metadata is instantiated on first use.
final class GenericSegment<T> {
  var desired: Size
  var isSealed = false
  var extra: T

  init(desired: Size, extra: T) {
    self.desired = desired
    self.extra = extra
  }
}

final class GenericOwner {
  var current: GenericSegment<Int>?

  @inline(never)
  func offer(_ size: Size, _ extra: Int) -> Bool {
    if let segment = current, !segment.isSealed {
      segment.desired = size
      return true
    }
    current = GenericSegment(desired: size, extra: extra)
    return false
  }
}

// Read the class from the object header at runtime.
@_optimize(none)
func dynamicClass(of object: AnyObject) -> ObjectIdentifier {
  return ObjectIdentifier(type(of: object))
}

let owner = Owner()
_ = owner.offer(Size(w: 1, h: 2))
let first = owner.current!

// CHECK: header intact: true
print("header intact: \(dynamicClass(of: first) == ObjectIdentifier(Segment.self))")
// CHECK: isSealed: false, desired: 1x2
print("isSealed: \(first.isSealed), desired: \(first.desired.w)x\(first.desired.h)")

let genericOwner = GenericOwner()
_ = genericOwner.offer(Size(w: 3, h: 4), 5)
let genericFirst = genericOwner.current!

// CHECK: generic header intact: true
print("generic header intact: \(dynamicClass(of: genericFirst) == ObjectIdentifier(GenericSegment<Int>.self))")
// CHECK: generic isSealed: false, desired: 3x4, extra: 5
print("generic isSealed: \(genericFirst.isSealed), desired: \(genericFirst.desired.w)x\(genericFirst.desired.h), extra: \(genericFirst.extra)")
