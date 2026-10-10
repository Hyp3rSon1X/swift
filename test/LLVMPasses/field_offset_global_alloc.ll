; RUN: %swift-llvm-opt -passes=gvn %s | %FileCheck %s

; A field offset global of a class whose layout is only known at runtime holds
; a placeholder until the class metadata is initialized. Metadata accessors
; are readnone, so swift_allocObject is the earliest point at which a field
; offset of the new instance may be loaded.

target datalayout = "e-p:64:64:64-S128-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f16:16:16-f32:32:32-f64:64:64-f128:128:128-v64:64:64-v128:128:128-a0:0:64-s0:64:64-f80:128:128-n8:16:32:64"
target triple = "x86_64-apple-macosx10.9"

%swift.metadata_response = type { ptr, i64 }

@"$s4main7SegmentC8isSealedSbvpWvd" = hidden global i64 0, align 8
@"$s4main5OtherC5countSivpWvd" = hidden global i64 0, align 8
@counter = hidden global i64 0, align 8
@counter2 = hidden global i64 0, align 8

declare ptr @swift_allocObject(ptr, i64, i64) nounwind
declare swiftcc %swift.metadata_response @"$s4main7SegmentCMa"(i64) nounwind memory(none)

; The offset for the new instance must not be partially redundant with the
; one loaded for an existing instance.
; CHECK-LABEL: define i1 @no_pre_above_allocation(
; CHECK:      miss:
; CHECK-NOT:    load
; CHECK:        br label %alloc
; CHECK:      alloc:
; CHECK-NOT:    phi
; CHECK:        [[OBJ:%.*]] = call noalias ptr @swift_allocObject(
; CHECK-NEXT:   [[OFF:%.*]] = load i64, ptr @"$s4main7SegmentC8isSealedSbvpWvd"
; CHECK-NEXT:   getelementptr inbounds i8, ptr [[OBJ]], i64 [[OFF]]
define i1 @no_pre_above_allocation(ptr %existing) {
entry:
  %isnull = icmp eq ptr %existing, null
  br i1 %isnull, label %miss, label %check

miss:
  br label %alloc

check:
  %off0 = load i64, ptr @"$s4main7SegmentC8isSealedSbvpWvd", align 8
  %addr0 = getelementptr inbounds i8, ptr %existing, i64 %off0
  %sealed = load i1, ptr %addr0, align 1
  br i1 %sealed, label %alloc, label %done

alloc:
  %response = call swiftcc %swift.metadata_response @"$s4main7SegmentCMa"(i64 0) nounwind memory(none)
  %md = extractvalue %swift.metadata_response %response, 0
  %obj = call noalias ptr @swift_allocObject(ptr %md, i64 32, i64 7)
  %off1 = load i64, ptr @"$s4main7SegmentC8isSealedSbvpWvd", align 8
  %addr1 = getelementptr inbounds i8, ptr %obj, i64 %off1
  store i1 false, ptr %addr1, align 1
  br label %done

done:
  %r = phi i1 [ false, %check ], [ true, %alloc ]
  ret i1 %r
}

; CHECK-LABEL: define i64 @field_offset_reloaded_after_allocation(
; CHECK: load i64, ptr @"$s4main7SegmentC8isSealedSbvpWvd"
; CHECK: call noalias ptr @swift_allocObject(
; CHECK: load i64, ptr @"$s4main7SegmentC8isSealedSbvpWvd"
define i64 @field_offset_reloaded_after_allocation(ptr %md) {
  %a = load i64, ptr @"$s4main7SegmentC8isSealedSbvpWvd", align 8
  %obj = call noalias ptr @swift_allocObject(ptr %md, i64 32, i64 7)
  %b = load i64, ptr @"$s4main7SegmentC8isSealedSbvpWvd", align 8
  %s = add i64 %a, %b
  ret i64 %s
}

; Other memory is still not clobbered by an allocation.
; CHECK-LABEL: define i64 @other_globals_not_reloaded(
; CHECK: load i64, ptr @counter
; CHECK-NOT: load
; CHECK: ret
define i64 @other_globals_not_reloaded(ptr %md) {
  %a = load i64, ptr @counter, align 8
  %obj = call noalias ptr @swift_allocObject(ptr %md, i64 32, i64 7)
  %b = load i64, ptr @counter, align 8
  %s = add i64 %a, %b
  ret i64 %s
}

; Loads of the field offsets of different classes can be merged into a load
; through a phi or select of their globals (e.g. by SimplifyCFG sinking); such
; a load is still a field offset load.
; CHECK-LABEL: define i64 @phi_of_field_offsets_reloaded(
; CHECK:      join:
; CHECK-NEXT:   [[P:%.*]] = phi ptr
; CHECK-NEXT:   load i64, ptr [[P]]
; CHECK-NEXT:   call noalias ptr @swift_allocObject(
; CHECK-NEXT:   load i64, ptr [[P]]
define i64 @phi_of_field_offsets_reloaded(i1 %c, ptr %md) {
entry:
  br i1 %c, label %left, label %right

left:
  br label %join

right:
  br label %join

join:
  %p = phi ptr [ @"$s4main7SegmentC8isSealedSbvpWvd", %left ], [ @"$s4main5OtherC5countSivpWvd", %right ]
  %a = load i64, ptr %p, align 8
  %obj = call noalias ptr @swift_allocObject(ptr %md, i64 32, i64 7)
  %b = load i64, ptr %p, align 8
  %s = add i64 %a, %b
  ret i64 %s
}

; CHECK-LABEL: define i64 @select_of_field_offsets_reloaded(
; CHECK:      [[P:%.*]] = select i1 %c, ptr @"$s4main7SegmentC8isSealedSbvpWvd", ptr @"$s4main5OtherC5countSivpWvd"
; CHECK-NEXT: load i64, ptr [[P]]
; CHECK-NEXT: call noalias ptr @swift_allocObject(
; CHECK-NEXT: load i64, ptr [[P]]
define i64 @select_of_field_offsets_reloaded(i1 %c, ptr %md) {
  %p = select i1 %c, ptr @"$s4main7SegmentC8isSealedSbvpWvd", ptr @"$s4main5OtherC5countSivpWvd"
  %a = load i64, ptr %p, align 8
  %obj = call noalias ptr @swift_allocObject(ptr %md, i64 32, i64 7)
  %b = load i64, ptr %p, align 8
  %s = add i64 %a, %b
  ret i64 %s
}

; If only one of the underlying objects is a field offset global, the location
; may still be one.
; CHECK-LABEL: define i64 @select_of_field_offset_and_unknown_reloaded(
; CHECK:      [[P:%.*]] = select i1 %c, ptr @"$s4main7SegmentC8isSealedSbvpWvd", ptr %q
; CHECK-NEXT: load i64, ptr [[P]]
; CHECK-NEXT: call noalias ptr @swift_allocObject(
; CHECK-NEXT: load i64, ptr [[P]]
define i64 @select_of_field_offset_and_unknown_reloaded(i1 %c, ptr %q, ptr %md) {
  %p = select i1 %c, ptr @"$s4main7SegmentC8isSealedSbvpWvd", ptr %q
  %a = load i64, ptr %p, align 8
  %obj = call noalias ptr @swift_allocObject(ptr %md, i64 32, i64 7)
  %b = load i64, ptr %p, align 8
  %s = add i64 %a, %b
  ret i64 %s
}

; A phi or select of other globals is still not clobbered by an allocation.
; CHECK-LABEL: define i64 @phi_of_other_globals_not_reloaded(
; CHECK:      join:
; CHECK-NEXT:   [[P:%.*]] = phi ptr
; CHECK-NEXT:   load i64, ptr [[P]]
; CHECK-NOT:    load
; CHECK:        ret
define i64 @phi_of_other_globals_not_reloaded(i1 %c, ptr %md) {
entry:
  br i1 %c, label %left, label %right

left:
  br label %join

right:
  br label %join

join:
  %p = phi ptr [ @counter, %left ], [ @counter2, %right ]
  %a = load i64, ptr %p, align 8
  %obj = call noalias ptr @swift_allocObject(ptr %md, i64 32, i64 7)
  %b = load i64, ptr %p, align 8
  %s = add i64 %a, %b
  ret i64 %s
}
