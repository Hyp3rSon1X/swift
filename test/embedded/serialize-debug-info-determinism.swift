// RUN: %empty-directory(%t)
// RUN: %{python} %utils/split_file.py -o %t %s

// Functions that are referenced only by debug scopes must be serialized in a
// deterministic order. Embedded Swift serializes debug info for every module
// except the stdlib; -parse-stdlib needs the explicit flag.

// RUN: %target-swift-frontend -emit-module -o %t/M.swiftmodule %t/M.swift -module-name M \
// RUN:   -parse-stdlib -enable-experimental-feature Embedded -wmo -O -experimental-serialize-debug-info \
// RUN:   -enable-deterministic-check 2>&1 | %FileCheck %s
// RUN: %empty-directory(%t/again)
// RUN: %target-swift-frontend -emit-module -o %t/again/M.swiftmodule %t/M.swift -module-name M \
// RUN:   -parse-stdlib -enable-experimental-feature Embedded -wmo -O -experimental-serialize-debug-info \
// RUN:   -enable-deterministic-check 2>&1 | %FileCheck %s
// RUN: cmp %t/M.swiftmodule %t/again/M.swiftmodule

// The helpers are inlined into entry() and then removed, so the module refers
// to them only from debug scopes. Check that a client sees those references,
// otherwise the determinism check above proves nothing.
// RUN: %target-swift-frontend -emit-sil -g -O -I %t %t/Client.swift -module-name Client \
// RUN:   -parse-stdlib -enable-experimental-feature Embedded -wmo | %FileCheck %s --check-prefix=CLIENT

// REQUIRES: swift_in_compiler
// REQUIRES: swift_feature_Embedded

// CHECK: remark: produced matching output file '{{.*}}{{/|\\}}M.swiftmodule'

// CLIENT: sil_scope {{.*}} parent @$e1M7helper0yAA3IntVADF
// CLIENT: sil_scope {{.*}} parent @$e1M8helper31yAA3IntVADF

// BEGIN M.swift

public struct Int { var v: Builtin.Int64 }

@inline(__always) func helper0(_ x: Int) -> Int { return x }
@inline(__always) func helper1(_ x: Int) -> Int { return x }
@inline(__always) func helper2(_ x: Int) -> Int { return x }
@inline(__always) func helper3(_ x: Int) -> Int { return x }
@inline(__always) func helper4(_ x: Int) -> Int { return x }
@inline(__always) func helper5(_ x: Int) -> Int { return x }
@inline(__always) func helper6(_ x: Int) -> Int { return x }
@inline(__always) func helper7(_ x: Int) -> Int { return x }
@inline(__always) func helper8(_ x: Int) -> Int { return x }
@inline(__always) func helper9(_ x: Int) -> Int { return x }
@inline(__always) func helper10(_ x: Int) -> Int { return x }
@inline(__always) func helper11(_ x: Int) -> Int { return x }
@inline(__always) func helper12(_ x: Int) -> Int { return x }
@inline(__always) func helper13(_ x: Int) -> Int { return x }
@inline(__always) func helper14(_ x: Int) -> Int { return x }
@inline(__always) func helper15(_ x: Int) -> Int { return x }
@inline(__always) func helper16(_ x: Int) -> Int { return x }
@inline(__always) func helper17(_ x: Int) -> Int { return x }
@inline(__always) func helper18(_ x: Int) -> Int { return x }
@inline(__always) func helper19(_ x: Int) -> Int { return x }
@inline(__always) func helper20(_ x: Int) -> Int { return x }
@inline(__always) func helper21(_ x: Int) -> Int { return x }
@inline(__always) func helper22(_ x: Int) -> Int { return x }
@inline(__always) func helper23(_ x: Int) -> Int { return x }
@inline(__always) func helper24(_ x: Int) -> Int { return x }
@inline(__always) func helper25(_ x: Int) -> Int { return x }
@inline(__always) func helper26(_ x: Int) -> Int { return x }
@inline(__always) func helper27(_ x: Int) -> Int { return x }
@inline(__always) func helper28(_ x: Int) -> Int { return x }
@inline(__always) func helper29(_ x: Int) -> Int { return x }
@inline(__always) func helper30(_ x: Int) -> Int { return x }
@inline(__always) func helper31(_ x: Int) -> Int { return x }

public func entry(_ x: Int) -> Int {
  return helper31(helper30(helper29(helper28(helper27(helper26(helper25(helper24(
    helper23(helper22(helper21(helper20(helper19(helper18(helper17(helper16(
    helper15(helper14(helper13(helper12(helper11(helper10(helper9(helper8(
    helper7(helper6(helper5(helper4(helper3(helper2(helper1(helper0(
    x))))))))))))))))))))))))))))))))
}

// BEGIN Client.swift

import M

public func run(_ x: Int) -> Int {
  return entry(x)
}
