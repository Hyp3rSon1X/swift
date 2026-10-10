//===--- LLVMSwiftAA.cpp - LLVM Alias Analysis for Swift ------------------===//
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

#include "swift/LLVMPasses/Passes.h"
#include "LLVMARCOpts.h"
#include "swift/Demangling/Demangle.h"
#include "llvm/Analysis/TargetLibraryInfo.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/IR/LegacyPassManager.h" 
#include "llvm/IR/Module.h"

using namespace llvm;
using namespace swift;

//===----------------------------------------------------------------------===//
//                           Alias Analysis Result
//===----------------------------------------------------------------------===//

static ModRefInfo getConservativeModRefForKind(RT_Kind Kind) {
  switch (Kind) {
#define KIND(Name, MemBehavior) case RT_ ## Name: return ModRefInfo:: MemBehavior;
#include "LLVMSwift.def"
  }

  llvm_unreachable("Not a valid Instruction.");
}

static bool isRuntimeInitializedFieldOffsetGlobal(const llvm::Value *V) {
  auto *GV = dyn_cast<GlobalVariable>(V);
  if (!GV || GV->isConstant())
    return false;
  StringRef Name = GV->getName();
  return Demangle::isSwiftSymbol(Name) && Name.ends_with("Wvd");
}

/// Returns true if \p Loc may be a class field offset global ("...Wvd") whose
/// value is filled in by the runtime.
///
/// If the layout of a class is not known at compile time, its field offset
/// globals start out as placeholders and are written when the class metadata
/// is initialized. Metadata accessors are modeled as not accessing memory, so
/// nothing orders a load of such a global after the metadata access that
/// initializes it.
///
/// Optimizations may merge loads of the field offsets of different classes
/// into a load through a phi or select of their globals, so all underlying
/// objects are checked. Objects the walk cannot identify (arguments, loaded
/// pointers, or where it gave up) are not treated as field offset globals:
/// IRGen only ever addresses these globals directly, their address does not
/// escape, and assuming otherwise would make every allocation clobber nearly
/// all memory.
static bool
mayBeRuntimeInitializedFieldOffset(const llvm::MemoryLocation &Loc) {
  SmallVector<const Value *, 4> Objects;
  getUnderlyingObjects(Loc.Ptr, Objects);
  return llvm::any_of(Objects, isRuntimeInitializedFieldOffsetGlobal);
}

ModRefInfo SwiftAAResult::getModRefInfo(const llvm::CallBase *Call,
                                        const llvm::MemoryLocation &Loc,
                                        llvm::AAQueryInfo &AAQI) {
  RT_Kind Kind = classifyInstruction(*Call);

  // An instance can only be allocated once its class metadata, including the
  // field offset globals, has been initialized. The allocation is therefore
  // the earliest point at which a field offset of the new object can be
  // loaded; don't let such a load move above it, where it could still read
  // the placeholder.
  if (Kind == RT_AllocObject && mayBeRuntimeInitializedFieldOffset(Loc))
    return AAResultBase::getModRefInfo(Call, Loc, AAQI);

  // We know at compile time that certain entry points do not modify any
  // compiler-visible state ever. Quickly check if we have one of those
  // instructions and return if so.
  if (ModRefInfo::NoModRef == getConservativeModRefForKind(Kind))
    return ModRefInfo::NoModRef;

  // Otherwise, delegate to the rest of the AA ModRefInfo machinery.
  return AAResultBase::getModRefInfo(Call, Loc, AAQI);
}

//===----------------------------------------------------------------------===//
//                        Alias Analysis Wrapper Pass
//===----------------------------------------------------------------------===//

char SwiftAAWrapperPass::ID = 0;
INITIALIZE_PASS_BEGIN(SwiftAAWrapperPass, "swift-aa",
                      "Swift Alias Analysis", false, true)
INITIALIZE_PASS_DEPENDENCY(TargetLibraryInfoWrapperPass)
INITIALIZE_PASS_END(SwiftAAWrapperPass, "swift-aa",
                    "Swift Alias Analysis", false, true)

SwiftAAWrapperPass::SwiftAAWrapperPass() : ImmutablePass(ID) {
  initializeSwiftAAWrapperPassPass(*PassRegistry::getPassRegistry());
}

bool SwiftAAWrapperPass::doInitialization(Module &M) {
  Result.reset(new SwiftAAResult());
  return false;
}

bool SwiftAAWrapperPass::doFinalization(Module &M) {
  Result.reset();
  return false;
}

void SwiftAAWrapperPass::getAnalysisUsage(AnalysisUsage &AU) const {
  AU.setPreservesAll();
  AU.addRequired<TargetLibraryInfoWrapperPass>();
}

AnalysisKey SwiftAA::Key;

SwiftAAResult SwiftAA::run(llvm::Function &F,
                           llvm::FunctionAnalysisManager &AM) {
  return SwiftAAResult();
}

//===----------------------------------------------------------------------===//
//                           Top Level Entry Point
//===----------------------------------------------------------------------===//

llvm::ImmutablePass *swift::createSwiftAAWrapperPass() {
  return new SwiftAAWrapperPass();
}
