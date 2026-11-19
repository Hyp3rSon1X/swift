// REQUIRES: swift_swift_parser

// Diagnostic positions in a plugin's reply that lie before the source buffer,
// and ranges that end before they start, are dropped instead of reaching the
// source manager.

// RUN: %empty-directory(%t)
// RUN: split-file %s %t

// RUN: %swift-build-c-plugin -o %t/mock-plugin %t/plugin.c

// RUN: not %target-swift-frontend \
// RUN:   -typecheck \
// RUN:   -swift-version 5 \
// RUN:   -diagnostic-style llvm \
// RUN:   -load-plugin-executable %t/mock-plugin#TestPlugin \
// RUN:   -module-name MyApp \
// RUN:   %t/test.swift \
// RUN:   > %t/diags.txt 2>&1

// RUN: %FileCheck %s < %t/diags.txt

// CHECK-DAG: <unknown>:0: error: diagnostic before the buffer (from macro 'outOfBuffer')
// CHECK-DAG: <unknown>:0: note: note before the buffer
// CHECK-DAG: test.swift:6:7: error: diagnostic with inverted ranges (from macro 'invertedRanges')
// CHECK-DAG: test.swift:6:7: note: fix with an inverted range

//--- test.swift
@freestanding(expression) macro outOfBuffer() -> Int = #externalMacro(module: "TestPlugin", type: "OutOfBufferMacro")
@freestanding(expression) macro invertedRanges() -> Int = #externalMacro(module: "TestPlugin", type: "InvertedRangesMacro")

func test() {
  _ = #outOfBuffer
  _ = #invertedRanges
}

//--- plugin.c
#include "swift-c/MockPlugin/MockPlugin.h"

MOCK_PLUGIN([
  {
    "expect": {"getCapability": {}},
    "response": {"getCapabilityResult": {"capability": {"protocolVersion": 1}}}
  },
  {
    "expect": {"expandFreestandingMacro": {
                "macro": {"moduleName": "TestPlugin", "typeName": "OutOfBufferMacro"}}},
    "response": {"expandFreestandingMacroResult": {
                   "expandedSource": "1",
                   "diagnostics": [
                     {"severity": "error",
                      "position": {"offset": -100,
                                   "fileName": "=req.expandFreestandingMacro.syntax.location.fileName"},
                      "message": "diagnostic before the buffer",
                      "highlights": [
                        {"fileName": "=req.expandFreestandingMacro.syntax.location.fileName",
                         "startOffset": -5, "endOffset": -1}
                      ],
                      "notes": [
                        {"position": {"offset": -9223372036854775807,
                                      "fileName": "=req.expandFreestandingMacro.syntax.location.fileName"},
                         "message": "note before the buffer"}
                      ],
                      "fixIts": []}
                   ]}}
  },
  {
    "expect": {"expandFreestandingMacro": {
                "macro": {"moduleName": "TestPlugin", "typeName": "InvertedRangesMacro"}}},
    "response": {"expandFreestandingMacroResult": {
                   "expandedSource": "2",
                   "diagnostics": [
                     {"severity": "error",
                      "position": {"offset": "=req.expandFreestandingMacro.syntax.location.offset",
                                   "fileName": "=req.expandFreestandingMacro.syntax.location.fileName"},
                      "message": "diagnostic with inverted ranges",
                      "highlights": [
                        {"fileName": "=req.expandFreestandingMacro.syntax.location.fileName",
                         "startOffset": 40, "endOffset": 2}
                      ],
                      "notes": [],
                      "fixIts": [
                        {"message": "fix with an inverted range",
                         "changes": [
                           {"range": {"fileName": "=req.expandFreestandingMacro.syntax.location.fileName",
                                      "startOffset": 40, "endOffset": 2},
                            "newText": "x"}
                         ]}
                      ]}
                   ]}}
  }
])
