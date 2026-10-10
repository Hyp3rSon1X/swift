// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend -emit-module -enable-library-evolution -emit-module-path=%t/resilient_struct.swiftmodule -module-name=resilient_struct %S/../Inputs/resilient_struct.swift
// RUN: %target-swift-frontend -I %t -emit-ir -O %s | %FileCheck %s

// The offset of 'isSealed' depends on the size of the resilient 'Size' field,
// so it is read from a field offset global that the runtime initializes along
// with Segment's metadata. When creating a new instance, the offset must be
// loaded after the allocation, not merged with the load on the path that
// reads an existing instance (which would place the load above the metadata
// accessor and read the placeholder on first use).

import resilient_struct

final class Segment {
  var desired: Size
  var isSealed = false

  init(desired: Size) {
    self.desired = desired
  }
}

public final class Owner {
  var current: Segment?

  public init() {}

  public func offer(_ size: Size) -> Bool {
    if let segment = current, !segment.isSealed {
      segment.desired = size
      return true
    }
    current = Segment(desired: size)
    return false
  }
}

// CHECK-LABEL: define {{.*}} @"$s{{.*}}5OwnerC5offer{{.*}}"(
// CHECK:         [[OBJ:%[0-9]+]] = {{(tail )?}}call noalias ptr @swift_allocObject(ptr
// CHECK-NOT:   {{^[0-9a-zA-Z_.-]+:}}
// CHECK:         [[OFF:%[0-9a-z.]+]] = load [[INT:i(32|64)]], ptr @"$s{{.*}}7SegmentC8isSealedSbvpWvd"
// CHECK-NEXT:    [[ADDR:%[0-9]+]] = getelementptr inbounds i8, ptr [[OBJ]], [[INT]] [[OFF]]
// CHECK-NEXT:    store i8 0, ptr [[ADDR]]
