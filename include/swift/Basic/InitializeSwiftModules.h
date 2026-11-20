//===--- InitializeSwiftModules.h -------------------------------*- C++ -*-===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#ifndef SWIFT_BASIC_INITIALIZE_SWIFT_MODULES_H
#define SWIFT_BASIC_INITIALIZE_SWIFT_MODULES_H

#ifdef __cplusplus
extern "C" {
#endif

/// Registers the compiler's Swift modules (SwiftCompilerSources) with the C++
/// side. Call it before any Swift code of the compiler runs. It may be called
/// more than once and from several threads at the same time: the registration
/// happens once, and every call returns after it is complete.
void initializeSwiftModules();

#ifdef __cplusplus
}
#endif

#endif // SWIFT_BASIC_INITIALIZE_SWIFT_MODULES_H
