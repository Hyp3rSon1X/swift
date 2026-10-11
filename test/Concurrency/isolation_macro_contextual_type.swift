// RUN: %empty-directory(%t)
// RUN: %target-swift-emit-silgen -parse-as-library -module-name test -target %target-swift-5.1-abi-triple -enable-upcoming-feature NonisolatedNonsendingByDefault %s | %FileCheck %s
// RUN: %target-swift-frontend -parse-as-library -module-name test -target %target-swift-5.1-abi-triple -enable-upcoming-feature NonisolatedNonsendingByDefault -emit-sil -warnings-as-errors %s -o /dev/null
// RUN: %target-swift-frontend -parse-as-library -module-name test -target %target-swift-5.1-abi-triple -enable-upcoming-feature NonisolatedNonsendingByDefault -O -emit-ir %s -o /dev/null

// RUN: not %target-swift-frontend -parse-as-library -module-name test -target %target-swift-5.1-abi-triple -enable-upcoming-feature NonisolatedNonsendingByDefault -typecheck -DTEST_DIAGNOSTICS %s > %t/diagnostics.txt 2>&1
// RUN: %FileCheck %s --check-prefix CHECK-DIAGS < %t/diagnostics.txt

// REQUIRES: concurrency
// REQUIRES: swift_feature_NonisolatedNonsendingByDefault

// `#isolation` takes its type from context. In code that is
// `nonisolated(nonsending)` and in actor initializers, SILGen synthesizes the
// isolation value as `(any Actor)?` and has to convert it to that type.

func takeAnyObject(_ x: AnyObject?) {}
func takeAny(_ x: Any) {}
func takeOptionalAny(_ x: Any?) {}
func takeConcreteActor(_ x: A?) {}
func takeComposition(_ x: (any Actor & P)?) {}
func takeDoubleActor(_ x: (any Actor)??) {}
func takeActor(_ x: any Actor) {}

func run(_ body: @escaping @Sendable () async -> Bool) async -> Bool {
  await body()
}

// CHECK-LABEL: sil hidden [ossa] @$s4test21toAnyObjectNonsendingyyYaF :
// CHECK:       bb0([[IMPLICIT_ACTOR:%.*]] : @guaranteed $Builtin.ImplicitActor):
// CHECK:         [[ACTOR:%.*]] = implicitactor_to_opaqueisolation_cast [[IMPLICIT_ACTOR]]
// CHECK:         [[ACTOR_COPY:%.*]] = copy_value [[ACTOR]]
// CHECK:         switch_enum [[ACTOR_COPY]], case #Optional.some!enumelt: [[SOME:bb[0-9]+]], case #Optional.none!enumelt: [[NONE:bb[0-9]+]]
// CHECK:       [[SOME]]([[EXISTENTIAL:%.*]] : @owned $any Actor):
// CHECK:         [[OPENED:%.*]] = open_existential_ref [[EXISTENTIAL]]
// CHECK:         [[OBJECT:%.*]] = init_existential_ref [[OPENED]] : {{.*}}, $AnyObject
// CHECK:         enum $Optional<AnyObject>, #Optional.some!enumelt, [[OBJECT]]
// CHECK:       [[NONE]]:
// CHECK:         enum $Optional<AnyObject>, #Optional.none!enumelt
// CHECK:       bb3([[RESULT:%.*]] : @owned $Optional<AnyObject>):
// CHECK:         [[FN:%.*]] = function_ref @$s4test13takeAnyObjectyyyXlSgF :
// CHECK:         apply [[FN]]([[RESULT]]) : $@convention(thin) (@guaranteed Optional<AnyObject>) -> ()
// CHECK:       } // end sil function '$s4test21toAnyObjectNonsendingyyYaF'
nonisolated(nonsending) func toAnyObjectNonsending() async {
  takeAnyObject(#isolation)
}

// CHECK-LABEL: sil hidden [ossa] @$s4test15toAnyNonsendingyyYaF :
// CHECK:       bb0([[IMPLICIT_ACTOR:%.*]] : @guaranteed $Builtin.ImplicitActor):
// CHECK:         [[ACTOR:%.*]] = implicitactor_to_opaqueisolation_cast [[IMPLICIT_ACTOR]]
// CHECK:         [[BOX:%.*]] = alloc_stack $Any
// CHECK:         [[ADDR:%.*]] = init_existential_addr [[BOX]], $Optional<any Actor>
// CHECK:         [[ACTOR_COPY:%.*]] = copy_value [[ACTOR]]
// CHECK:         store [[ACTOR_COPY]] to [init] [[ADDR]]
// CHECK:         [[FN:%.*]] = function_ref @$s4test7takeAnyyyypF :
// CHECK:         apply [[FN]]([[BOX]]) : $@convention(thin) (@in_guaranteed Any) -> ()
// CHECK:       } // end sil function '$s4test15toAnyNonsendingyyYaF'
//   The conversion to `Any` does not warn about an implicit Optional-to-Any
//   coercion (see -warnings-as-errors above).
nonisolated(nonsending) func toAnyNonsending() async {
  takeAny(#isolation)
}

// CHECK-LABEL: sil hidden [ossa] @$s4test23toOptionalAnyNonsendingyyYaF :
// CHECK:         implicitactor_to_opaqueisolation_cast
// CHECK:         switch_enum
// CHECK:         open_existential_ref
// CHECK:         init_existential_addr {{%.*}}, $@opened({{.*}}, any Actor) Self
// CHECK:         [[FN:%.*]] = function_ref @$s4test15takeOptionalAnyyyypSgF :
// CHECK:         apply [[FN]]({{%.*}}) : $@convention(thin) (@in_guaranteed Optional<Any>) -> ()
// CHECK:       } // end sil function '$s4test23toOptionalAnyNonsendingyyYaF'
nonisolated(nonsending) func toOptionalAnyNonsending() async {
  takeOptionalAny(#isolation)
}

//   A more optional type gets the isolation value injected, so that a nil
//   isolation becomes `.some(nil)`.
// CHECK-LABEL: sil hidden [ossa] @$s4test23toDoubleActorNonsendingyyYaF :
// CHECK:         [[ACTOR:%.*]] = implicitactor_to_opaqueisolation_cast
// CHECK-NEXT:    [[OUTER:%.*]] = enum $Optional<Optional<any Actor>>, #Optional.some!enumelt, [[ACTOR]]
// CHECK:         function_ref @$s4test15takeDoubleActoryyScA_pSgSgF :
// CHECK:       } // end sil function '$s4test23toDoubleActorNonsendingyyYaF'
nonisolated(nonsending) func toDoubleActorNonsending() async {
  takeDoubleActor(#isolation)
}

// The closure is `nonisolated(nonsending)` by default, and its `#isolation`
// gets the type `AnyObject?` from the `===` operator.
// CHECK-LABEL: sil private [ossa] @$s4test5probeSbyYaFSbyYaYbYCcfU_ :
// CHECK:         implicitactor_to_opaqueisolation_cast
// CHECK:         init_existential_ref {{%.*}} : {{.*}}, $AnyObject
// CHECK:       bb3([[LHS:%.*]] : @owned $Optional<AnyObject>):
// CHECK:         [[FN:%.*]] = function_ref @$ss3eeeoiySbyXlSg_ABtF :
// CHECK:         apply [[FN]]([[LHS]], {{%.*}})
// CHECK:       } // end sil function '$s4test5probeSbyYaFSbyYaYbYCcfU_'
@MainActor func probe() async -> Bool {
  await run { #isolation === MainActor.shared }
}

protocol P {}

actor A: P {
  var x: Int

  // The isolation of an actor initializer is flow-sensitive: nil before
  // `self` is initialized and `self` afterwards. It is cast to an optional of
  // the actor type and converted from there.
  // CHECK-LABEL: sil hidden [ossa] @$s4test1ACACyYacfc :
  // CHECK:         [[ISOLATION:%.*]] = builtin "flowSensitiveSelfIsolation"<A>({{%.*}}) : $Optional<any Actor>
  // CHECK:         [[CAST:%.*]] = unchecked_ref_cast [[ISOLATION]] to $Optional<A>
  // CHECK:         function_ref @$s4test17takeConcreteActoryyAA1ACSgF :
  // CHECK:         [[ISOLATION:%.*]] = builtin "flowSensitiveSelfIsolation"<A>({{%.*}}) : $Optional<any Actor>
  // CHECK:         [[CAST:%.*]] = unchecked_ref_cast [[ISOLATION]] to $Optional<A>
  // CHECK:         switch_enum [[CAST]]
  // CHECK:         init_existential_ref {{%.*}} : $A : $A, $any Actor & P
  // CHECK:         function_ref @$s4test15takeComposition
  //   A more optional type gets the isolation value injected.
  // CHECK:         [[ISOLATION:%.*]] = builtin "flowSensitiveSelfIsolation"<A>({{%.*}}) : $Optional<any Actor>
  // CHECK:         [[CAST:%.*]] = unchecked_ref_cast [[ISOLATION]] to $Optional<A>
  // CHECK:         switch_enum [[CAST]]
  // CHECK:         enum $Optional<any Actor>, #Optional.none!enumelt
  // CHECK:       bb{{[0-9]+}}([[INNER:%.*]] : @owned $Optional<any Actor>):
  // CHECK:         enum $Optional<Optional<any Actor>>, #Optional.some!enumelt, [[INNER]]
  // CHECK:         function_ref @$s4test15takeDoubleActoryyScA_pSgSgF :
  // CHECK:         [[ISOLATION:%.*]] = builtin "flowSensitiveSelfIsolation"<A>({{%.*}}) : $Optional<any Actor>
  // CHECK:         [[CAST:%.*]] = unchecked_ref_cast [[ISOLATION]] to $Optional<A>
  // CHECK:         unchecked_ref_cast [[CAST]] to $Optional<AnyObject>
  // CHECK:         function_ref @$s4test13takeAnyObjectyyyXlSgF :
  // CHECK:         [[ISOLATION:%.*]] = builtin "flowSensitiveSelfIsolation"<A>({{%.*}}) : $Optional<any Actor>
  // CHECK:         [[CAST:%.*]] = unchecked_ref_cast [[ISOLATION]] to $Optional<A>
  // CHECK:         [[BOX:%.*]] = alloc_stack $Any
  // CHECK:         [[ADDR:%.*]] = init_existential_addr [[BOX]], $Optional<A>
  // CHECK:         store [[CAST]] to [init] [[ADDR]]
  // CHECK:         function_ref @$s4test7takeAnyyyypF :
  //   A non-optional type cannot represent the flow-sensitive isolation value,
  //   so this uses `self`.
  // CHECK-NOT:     flowSensitiveSelfIsolation
  // CHECK:         init_existential_ref {{%.*}} : $A : $A, $any Actor
  // CHECK:         function_ref @$s4test9takeActoryyScA_pF :
  // CHECK:       } // end sil function '$s4test1ACACyYacfc'
  init() async {
    takeConcreteActor(#isolation)
    takeComposition(#isolation)
    takeDoubleActor(#isolation)
    x = 0
    takeAnyObject(#isolation)
    takeAny(#isolation)
    takeActor(#isolation)
  }
}

#if TEST_DIAGNOSTICS
// The isolation of a `nonisolated(nonsending)` function is only known at run
// time, so `#isolation` cannot be converted to a concrete type there.
nonisolated(nonsending) func badContextualTypes() async {
  // CHECK-DIAGS: error: cannot convert value of type '(any Actor)?' to expected argument type 'Int?'
  // CHECK-DIAGS: note: in expansion of macro 'isolation' here
  // CHECK-DIAGS: let _: Int? = #isolation
  let _: Int? = #isolation

  // CHECK-DIAGS: error: cannot convert value of type '(any Actor)?' to expected argument type 'MainActor?'
  // CHECK-DIAGS: note: in expansion of macro 'isolation' here
  // CHECK-DIAGS: let _: MainActor? = #isolation
  let _: MainActor? = #isolation
}

// https://github.com/swiftlang/swift/issues/92798: `!=` infers a metatype for
// `#isolation`. This is diagnosed like in isolated code.
nonisolated(nonsending) func compareWithNil() async -> Bool {
  // CHECK-DIAGS: error: cannot convert value of type '(any Actor)?' to expected argument type '(any (~Copyable & ~Escapable).Type)?'
  // CHECK-DIAGS: note: in expansion of macro 'isolation' here
  // CHECK-DIAGS: #isolation != nil
  #isolation != nil
}
#endif
