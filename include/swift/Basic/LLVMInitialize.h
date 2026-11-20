//===--- LLVMInitialize.h ---------------------------------------*- C++ -*-===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
//
// A file that declares macros for initializing all parts of LLVM that various
// binaries in swift use. Please call PROGRAM_START in the main routine of all
// binaries, and INITIALIZE_LLVM in anything that uses Clang or LLVM IR.
//
//===----------------------------------------------------------------------===//

#ifndef SWIFT_BASIC_LLVMINITIALIZE_H
#define SWIFT_BASIC_LLVMINITIALIZE_H

#include "swift/Basic/Compiler.h"
#include "llvm/Support/InitLLVM.h"
#include "llvm/Support/ManagedStatic.h"
#include "llvm/Support/PrettyStackTrace.h"
#include "llvm/Support/Signals.h"
#include "llvm/Support/TargetSelect.h"

#include <mutex>

#define PROGRAM_START(argc, argv)                                              \
  llvm::InitLLVM _INITIALIZE_LLVM(argc, argv);                                 \
  llvm::setBugReportMsg(SWIFT_CRASH_BUG_REPORT_MESSAGE "\n")

namespace swift {

/// Registers all of LLVM's targets, once per process. Several clients of the
/// compiler in one process (the frontend run in-process, an in-process
/// sourcekitd, the dependency scanner) each initialize LLVM at their start,
/// possibly at the same time on different threads, and LLVM's target registry
/// is not thread-safe: two threads registering the same target can link it
/// into the registry twice. The function is inline, so all of its callers in
/// a binary share one flag.
inline void initializeLLVMOnce() {
  static std::once_flag once;
  std::call_once(once, [] {
    llvm::InitializeAllTargets();
    llvm::InitializeAllTargetMCs();
    llvm::InitializeAllAsmPrinters();
    llvm::InitializeAllAsmParsers();
    llvm::InitializeAllDisassemblers();
    llvm::InitializeAllTargetInfos();
  });
}

} // end namespace swift

#define INITIALIZE_LLVM() ::swift::initializeLLVMOnce()

#endif // SWIFT_BASIC_LLVMINITIALIZE_H
