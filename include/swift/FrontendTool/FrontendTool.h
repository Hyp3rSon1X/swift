//===--- FrontendTool.h - Frontend control ----------------------*- C++ -*-===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
//
// This file provides a high-level API for interacting with the basic
// frontend tool operation.
//
//===----------------------------------------------------------------------===//

#ifndef SWIFT_FRONTENDTOOL_H
#define SWIFT_FRONTENDTOOL_H

#include "swift/Basic/LLVM.h"

namespace llvm {
class raw_pwrite_stream;
class Module;
}

namespace swift {
class CompilerInvocation;
class CompilerInstance;
class SILModule;

/// A simple observer of frontend activity.
///
/// Don't let this interface block enhancements to the frontend pipeline.
class FrontendObserver {
public:
  FrontendObserver() = default;
  virtual ~FrontendObserver() = default;

  /// Whether performFrontend routes LLVM fatal errors through the frontend's
  /// diagnostics, by installing LLVM's fatal error handler for the duration of
  /// the call. That handler is process-wide: a host that runs other compiler
  /// work in the same process at the same time (and installs a fatal error
  /// handler of its own that tells the threads apart) returns false.
  virtual bool shouldInstallFatalErrorHandler();

  /// The frontend has parsed the command line.
  virtual void parsedArgs(CompilerInvocation &invocation);

  /// The frontend has configured the compiler instance.
  virtual void configuredCompiler(CompilerInstance &instance);

  /// The frontend has performed semantic analysis.
  virtual void performedSemanticAnalysis(CompilerInstance &instance);

  /// The frontend has performed basic SIL generation.
  /// SIL diagnostic passes have not yet been applied.
  virtual void performedSILGeneration(SILModule &module);

  /// The frontend has executed the SIL optimization and diagnostics pipelines.
  virtual void performedSILProcessing(SILModule &module);

  // TODO: maybe enhance this interface to hear about IRGen and LLVM
  // progress.
};

namespace frontend {
namespace utils {
StringRef escapeForMake(StringRef raw, llvm::SmallVectorImpl<char> &buffer);
}
}

/// Perform all the operations of the frontend, exactly as if invoked
/// with -frontend.
///
/// \param args the arguments to use as the arguments to the frontend
/// \param argv0 the name used as the frontend executable
/// \param mainAddr an address from the main executable
///
/// \return the exit value of the frontend: 0 or 1 on success unless
///   the frontend executes in immediate mode, in which case this will be
///   the exit value of the script, assuming it exits normally
int performFrontend(ArrayRef<const char *> args,
                    const char *argv0,
                    void *mainAddr,
                    FrontendObserver *observer = nullptr);

/// Like performFrontend above, but prints diagnostics to \p diagOS instead of
/// llvm::errs(), so a host process that runs the frontend as a library can
/// route each invocation's diagnostics separately.
int performFrontend(ArrayRef<const char *> args,
                    const char *argv0,
                    void *mainAddr,
                    FrontendObserver *observer,
                    llvm::raw_pwrite_stream &diagOS);

bool performCompileStepsPostSema(CompilerInstance &Instance, int &ReturnValue,
                                 FrontendObserver *observer,
                                 ArrayRef<const char *> CommandLineArgs);

} // namespace swift

#endif
