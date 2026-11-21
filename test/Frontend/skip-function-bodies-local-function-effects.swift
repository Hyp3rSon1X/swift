// REQUIRES: swift_swift_parser

// RUN: %empty-directory(%t)
// RUN: split-file %s %t

// RUN: %host-build-swift -swift-version 5 -emit-library -o %t/%target-library-name(MacroDefinition) -module-name=MacroDefinition %t/macro.swift -g -no-toolchain-stdlib-rpath

// Local functions whose bodies are skipped must not have their effects
// checked: their bodies were never type-checked, so the macros in them were
// never expanded and a 'try' covering a throwing macro expansion would look
// like it covers nothing.
// RUN: %target-swift-frontend -typecheck -verify -swift-version 5 -parse-as-library -load-plugin-library %t/%target-library-name(MacroDefinition) -experimental-skip-non-inlinable-function-bodies-without-types %t/test.swift
// RUN: %target-swift-frontend -typecheck -verify -swift-version 5 -parse-as-library -load-plugin-library %t/%target-library-name(MacroDefinition) -verify-additional-prefix noskip- %t/test.swift

//--- macro.swift
import SwiftSyntax
import SwiftSyntaxMacros

/// Expands `#check(x)` to `checkThrowing(x)`, a call that must be covered by
/// a 'try' at the use site.
public struct CheckMacro: ExpressionMacro {
  public static func expansion(
    of macro: some FreestandingMacroExpansionSyntax,
    in context: some MacroExpansionContext
  ) -> ExprSyntax {
    return "checkThrowing(\(macro.arguments.first!.expression))"
  }
}

//--- test.swift
@freestanding(expression)
macro check(_ value: Bool) = #externalMacro(module: "MacroDefinition", type: "CheckMacro")

struct CheckFailure: Error {}

func checkThrowing(_ value: Bool) throws {
  if !value { throw CheckFailure() }
}

func cond() -> Bool { true }

// The body is type-checked because it declares a local type, but the local
// function is skipped because it has no nested types of its own.
func localFunctionInBodyWithLocalType() throws {
  typealias T = Int
  func inner() throws { try #check(cond()) }
  try inner()
}

// The same, with the throwing macro two local functions deep.
func nestedLocalFunctionInBodyWithLocalType() throws {
  typealias T = Int
  func outer() throws {
    func inner() throws { try #check(cond()) }
    try inner()
  }
  try outer()
}

// A local function that declares a local type itself is not skipped.
func localFunctionWithOwnLocalType() throws {
  typealias T = Int
  func inner() throws {
    typealias U = T
    try #check(cond())
  }
  try inner()
}

// Without local types the whole body is skipped.
func localFunctionInBodyWithoutLocalType() throws {
  func inner() throws { try #check(cond()) }
  try inner()
}

// Closures are type-checked together with the enclosing body.
func closureInBodyWithLocalType() throws {
  typealias T = Int
  let inner = { () throws in try #check(cond()) }
  try inner()
}

// The closure initializing a stored property is type-checked, but a local
// function inside it is skipped, even without local types.
struct PropertyInitializer {
  var x: Int = {
    func inner() throws -> Int { try #check(cond()); return 1 }
    return try! inner()
  }()
}

// Missing 'try' is still diagnosed in bodies that are type-checked.
func missingTryInBodyWithLocalType() throws {
  typealias T = Int
  #check(cond()) // expected-note 4 {{in expansion of macro 'check' here}}
  /*
  expected-expansion@-2:3{{
    expected-error@1:1 {{call can throw but is not marked with 'try'}}
    expected-note@1:1 {{did you mean to use 'try'?}}
    expected-note@1:1 {{did you mean to handle error as optional value?}}
    expected-note@1:1 {{did you mean to disable error propagation?}}
  }}
  */
}

func missingTryInLocalFunctionWithOwnLocalType() throws {
  typealias T = Int
  func inner() throws {
    typealias U = T
    #check(cond()) // expected-note 4 {{in expansion of macro 'check' here}}
    /*
    expected-expansion@-2:5{{
      expected-error@1:1 {{call can throw but is not marked with 'try'}}
      expected-note@1:1 {{did you mean to use 'try'?}}
      expected-note@1:1 {{did you mean to handle error as optional value?}}
      expected-note@1:1 {{did you mean to disable error propagation?}}
    }}
    */
  }
  try inner()
}

// A skipped body is not checked at all, so the missing 'try' is only
// diagnosed when bodies are not skipped.
func missingTryInSkippedLocalFunction() throws {
  typealias T = Int
  func inner() throws {
    #check(cond()) // expected-noskip-note 4 {{in expansion of macro 'check' here}}
    /*
    expected-noskip-expansion@-2:5{{
      expected-noskip-error@1:1 {{call can throw but is not marked with 'try'}}
      expected-noskip-note@1:1 {{did you mean to use 'try'?}}
      expected-noskip-note@1:1 {{did you mean to handle error as optional value?}}
      expected-noskip-note@1:1 {{did you mean to disable error propagation?}}
    }}
    */
  }
  try inner()
}
