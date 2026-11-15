// RUN: %target-swift-frontend -emit-sil -Onone -parse-as-library -module-name test %s | %FileCheck %s
// RUN: %target-swift-frontend -emit-sil -O -sil-verify-all -parse-as-library -module-name test -primary-file %s | %FileCheck --check-prefix=OPT %s
// RUN: %target-swift-frontend -emit-ir -O -parse-as-library -module-name test -primary-file %s -o /dev/null
// RUN: %target-swift-frontend -emit-ir -Osize -parse-as-library -module-name test -primary-file %s -o /dev/null

// The -O runs use -primary-file: in whole-module mode `value()` is optimized
// differently and the crash did not reproduce.

// A mutating method of a noncopyable struct calls a rethrows function with a
// non-throwing closure, so the error block of its try_apply ends in
// `unreachable`. The move-only address checker must not destroy `self.box`
// there: `self` is inout and still live at the `unreachable`. Once `value()`
// was inlined into `run()`, that destroy turned into a `load [take]` of
// `self.box` inside the `load_borrow` of `self.box` that replaced the local
// `box`, and the SIL verifier failed with "read-only scope invalidated by a
// local write".

struct Root {
  var x = 0

  @inline(never)
  mutating func update(_ body: (inout Int) throws -> Int) rethrows -> Int {
    try body(&x)
  }
}

final class Box {
  var root = Root()
}

struct Sink: ~Copyable {
  let box: Box
  var count = 0

  // OPT-LABEL: sil hidden @$s4test4SinkV3runyyF : $@convention(method) (@inout Sink) -> () {
  // OPT:         return
  // OPT-LABEL: } // end sil function '$s4test4SinkV3runyyF'
  mutating func run() {
    let box = self.box
    box.root.x += 1
    count += value()
  }

  // CHECK-LABEL: sil hidden @$s4test4SinkV5valueSiyF : $@convention(method) (@inout Sink) -> Int {
  // CHECK:         try_apply {{%.*}}({{%.*}}, {{%.*}}) : {{.*}}, normal bb1, error bb2
  // CHECK:       bb2({{%.*}} : $any Error):
  // CHECK-NOT:     destroy_addr
  // CHECK:         unreachable
  // CHECK-LABEL: } // end sil function '$s4test4SinkV5valueSiyF'
  mutating func value() -> Int {
    box.root.update { $0 }
  }
}
