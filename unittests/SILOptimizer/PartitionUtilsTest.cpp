//===--- PartitionUtilsTest.cpp -------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#include "swift/SILOptimizer/Utils/PartitionUtils.h"

#include "gtest/gtest.h"

#include <array>
#include <map>
#include <random>

using namespace swift;
using namespace swift::PartitionPrimitives;

//===----------------------------------------------------------------------===//
//                                 Utilities
//===----------------------------------------------------------------------===//

struct Partition::PartitionTester {
  const Partition &p;

  PartitionTester(const Partition &p) : p(p) {}

  unsigned getRegion(unsigned elt) const {
    return unsigned(p.elementToRegionMap.at(Element(elt)));
  }

  static unsigned getFreshLabel(const Partition &p) {
    return unsigned(p.freshLabel);
  }

  static bool isCanonical(const Partition &p) { return p.canonical; }

  /// Partition::join without the shortcut for joining into a partition that
  /// has no elements.
  static Partition joinElementByElement(const Partition &fst, Partition &snd) {
    return Partition::joinImpl(fst, snd, /*shareIntoEmpty=*/false);
  }

  static void canonicalize(Partition &p) { p.canonicalize(); }

  static std::vector<std::pair<unsigned, unsigned>>
  getEntries(const Partition &p) {
    std::vector<std::pair<unsigned, unsigned>> entries;
    for (auto [element, region] : p.elementToRegionMap)
      entries.push_back({unsigned(element), unsigned(region)});
    return entries;
  }

  static std::vector<std::pair<unsigned, const void *>>
  getSentRegions(const Partition &p) {
    std::vector<std::pair<unsigned, const void *>> regions;
    for (auto [region, set] : p.regionToSendingOpMap)
      regions.push_back({unsigned(region), set});
    return regions;
  }

  /// Return a copy of \p p whose next canonicalize() walks every element.
  static Partition withFullCanonicalization(const Partition &p) {
    Partition copy = p;
    copy.needsFullCanonicalization = true;
    copy.elementsAddedSinceCanonical.clear();
    return copy;
  }

  static void expectSameState(const Partition &lhs, const Partition &rhs) {
    EXPECT_EQ(getEntries(lhs), getEntries(rhs));
    EXPECT_EQ(getSentRegions(lhs), getSentRegions(rhs));
    EXPECT_EQ(getFreshLabel(lhs), getFreshLabel(rhs));
    EXPECT_EQ(isCanonical(lhs), isCanonical(rhs));
  }
};

namespace {

using PartitionTester = Partition::PartitionTester;

struct MockedPartitionOpEvaluator final
    : PartitionOpEvaluatorBaseImpl<MockedPartitionOpEvaluator> {
  MockedPartitionOpEvaluator(Partition &workingPartition,
                             SendingOperandSetFactory &ptrSetFactory,
                             SendingOperandToStateMap &operandToStateMap)
      : PartitionOpEvaluatorBaseImpl(workingPartition, ptrSetFactory,
                                     operandToStateMap) {}

  // Just say that we always have a disconnected value.
  SILIsolationInfo getIsolationRegionInfo(Element elt) const {
    return SILIsolationInfo::getDisconnected(false /*isUnsafeNonIsolated*/);
  }

  bool shouldTryToSquelchErrors() const { return false; }

  static SILLocation getLoc(SILInstruction *inst) {
    return SILLocation::invalid();
  }

  static SILLocation getLoc(Operand *op) { return SILLocation::invalid(); }

  static SILIsolationInfo getIsolationInfo(const PartitionOp &partitionOp) {
    return {};
  }

  static SILInstruction *getSourceInst(const PartitionOp &partitionOp) {
    return nullptr;
  }

  static bool doesFunctionHaveSendingResult(const PartitionOp &partitionOp) {
    return false;
  }
};

} // namespace

namespace {

struct MockedPartitionOpEvaluatorWithFailureCallback final
    : PartitionOpEvaluatorBaseImpl<
          MockedPartitionOpEvaluatorWithFailureCallback> {
  using FailureCallbackTy =
      std::function<void(const PartitionOp &, unsigned, Operand *)>;
  FailureCallbackTy failureCallback;

  MockedPartitionOpEvaluatorWithFailureCallback(
      Partition &workingPartition, SendingOperandSetFactory &ptrSetFactory,
      SendingOperandToStateMap &operandToStateMap,
      FailureCallbackTy failureCallback)
      : PartitionOpEvaluatorBaseImpl(workingPartition, ptrSetFactory,
                                     operandToStateMap),
        failureCallback(failureCallback) {}

  void handleError(PartitionOpError &&error) {
    switch (error.getKind()) {
    case PartitionOpError::UnknownCodePattern:
    case PartitionOpError::SentNeverSendable:
    case PartitionOpError::AssignNeverSendableIntoSendingResult:
    case PartitionOpError::InOutSendingNotInitializedAtExit:
    case PartitionOpError::InOutSendingNotDisconnectedAtExit:
    case PartitionOpError::NonSendableIsolationCrossingResult:
    case PartitionOpError::InOutSendingReturned:
    case PartitionOpError::InOutSendingParametersInSameRegion:
      llvm_unreachable("Unsupported");
    case PartitionOpError::LocalUseAfterSend: {
      auto state = std::move(error).getLocalUseAfterSendError();
      failureCallback(*state.op, state.sentElement, state.sendingOp);
    }
    }
  }

  // Just say that we always have a disconnected value.
  SILIsolationInfo getIsolationRegionInfo(Element elt) const {
    return SILIsolationInfo::getDisconnected(false /*nonisolated(unsafe)*/);
  }

  bool shouldTryToSquelchErrors() const { return false; }

  static SILLocation getLoc(SILInstruction *inst) {
    return SILLocation::invalid();
  }

  static SILLocation getLoc(Operand *op) { return SILLocation::invalid(); }

  static SILIsolationInfo getIsolationInfo(const PartitionOp &partitionOp) {
    return {};
  }

  static SILInstruction *getSourceInst(const PartitionOp &partitionOp) {
    return nullptr;
  }
};

} // namespace

//===----------------------------------------------------------------------===//
//                                   Tests
//===----------------------------------------------------------------------===//

// When we send we need a specific send instruction. We do not ever
// actually dereference the instruction, so just use some invalid ptr values so
// we can compare.
Operand *operandSingletons[5] = {
    (Operand *)uintptr_t(0xDEAD0000), (Operand *)uintptr_t(0xFEAD0000),
    (Operand *)uintptr_t(0xAEDF0000), (Operand *)uintptr_t(0xFEDA0000),
    (Operand *)uintptr_t(0xFBDA0000),
};

SILInstruction *instSingletons[5] = {
    (SILInstruction *)uintptr_t(0xBEAD0000),
    (SILInstruction *)uintptr_t(0xBEAD0000),
    (SILInstruction *)uintptr_t(0xBEDF0000),
    (SILInstruction *)uintptr_t(0xBEDA0000),
    (SILInstruction *)uintptr_t(0xBBDA0000),
};

SILLocation fakeLoc = SILLocation::invalid();

// This test tests that if a series of merges is split between two partitions
// p1 and p2, but also applied in its entirety to p3, then joining p1 and p2
// yields p3.
TEST(PartitionUtilsTest, TestMergeAndJoin) {
  llvm::BumpPtrAllocator allocator;
  Partition::SendingOperandSetFactory factory(allocator);
  IsolationHistory::Factory historyFactory(allocator, /*enabled=*/true);
  SendingOperandToStateMap sendingOpToStateMap(historyFactory);

  Partition p1(historyFactory.get());
  Partition p2(historyFactory.get());
  Partition p3(historyFactory.get());

  {
    MockedPartitionOpEvaluator eval(p1, factory, sendingOpToStateMap);
    eval.apply({PartitionOp::AssignFresh(Element(0)),
                PartitionOp::AssignFresh(Element(1)),
                PartitionOp::AssignFresh(Element(2)),
                PartitionOp::AssignFresh(Element(3))});
  }

  {
    MockedPartitionOpEvaluator eval(p2, factory, sendingOpToStateMap);
    eval.apply({PartitionOp::AssignFresh(Element(5)),
                PartitionOp::AssignFresh(Element(6)),
                PartitionOp::AssignFresh(Element(7)),
                PartitionOp::AssignFresh(Element(0))});
  }

  {
    MockedPartitionOpEvaluator eval(p3, factory, sendingOpToStateMap);
    eval.apply({PartitionOp::AssignFresh(Element(2)),
                PartitionOp::AssignFresh(Element(3)),
                PartitionOp::AssignFresh(Element(4)),
                PartitionOp::AssignFresh(Element(5))});
  }

  EXPECT_FALSE(Partition::equals(p1, p2));
  EXPECT_FALSE(Partition::equals(p2, p3));
  EXPECT_FALSE(Partition::equals(p1, p3));

  {
    MockedPartitionOpEvaluator eval(p1, factory, sendingOpToStateMap);
    eval.apply({PartitionOp::AssignFresh(Element(4)),
                PartitionOp::AssignFresh(Element(5)),
                PartitionOp::AssignFresh(Element(6)),
                PartitionOp::AssignFresh(Element(7)),
                PartitionOp::AssignFresh(Element(8))});
  }

  {
    MockedPartitionOpEvaluator eval(p2, factory, sendingOpToStateMap);
    eval.apply({PartitionOp::AssignFresh(Element(1)),
                PartitionOp::AssignFresh(Element(2)),
                PartitionOp::AssignFresh(Element(3)),
                PartitionOp::AssignFresh(Element(4)),
                PartitionOp::AssignFresh(Element(8))});
  }

  {
    MockedPartitionOpEvaluator eval(p3, factory, sendingOpToStateMap);
    eval.apply({PartitionOp::AssignFresh(Element(6)),
                PartitionOp::AssignFresh(Element(7)),
                PartitionOp::AssignFresh(Element(0)),
                PartitionOp::AssignFresh(Element(1)),
                PartitionOp::AssignFresh(Element(8))});
  }

  EXPECT_TRUE(Partition::equals(p1, p2));
  EXPECT_TRUE(Partition::equals(p2, p3));
  EXPECT_TRUE(Partition::equals(p1, p3));

  auto expect_join_eq = [&]() {
    Partition joined = Partition::join(p1, p2);
    EXPECT_TRUE(Partition::equals(p3, joined));
  };

  auto apply_to_p1_and_p3 = [&](PartitionOp op) {
    {
      MockedPartitionOpEvaluator eval(p1, factory, sendingOpToStateMap);
      eval.apply(op);
    }

    {
      MockedPartitionOpEvaluator eval(p3, factory, sendingOpToStateMap);
      eval.apply(op);
    }
    expect_join_eq();
  };

  auto apply_to_p2_and_p3 = [&](PartitionOp op) {
    {
      MockedPartitionOpEvaluator eval(p2, factory, sendingOpToStateMap);
      eval.apply(op);
    }

    {
      MockedPartitionOpEvaluator eval(p3, factory, sendingOpToStateMap);
      eval.apply(op);
    }
    expect_join_eq();
  };

  apply_to_p1_and_p3(PartitionOp::Merge(Element(1), Element(2)));
  apply_to_p2_and_p3(PartitionOp::Merge(Element(7), Element(8)));
  apply_to_p1_and_p3(PartitionOp::Merge(Element(2), Element(7)));
  apply_to_p2_and_p3(PartitionOp::Merge(Element(1), Element(3)));
  apply_to_p1_and_p3(PartitionOp::Merge(Element(3), Element(4)));

  EXPECT_FALSE(Partition::equals(p1, p2));
  EXPECT_FALSE(Partition::equals(p2, p3));
  EXPECT_FALSE(Partition::equals(p1, p3));

  apply_to_p2_and_p3(PartitionOp::Merge(Element(2), Element(5)));
  apply_to_p1_and_p3(PartitionOp::Merge(Element(5), Element(6)));
  apply_to_p2_and_p3(PartitionOp::Merge(Element(1), Element(6)));
  apply_to_p1_and_p3(PartitionOp::Merge(Element(2), Element(6)));
  apply_to_p2_and_p3(PartitionOp::Merge(Element(3), Element(7)));
  apply_to_p1_and_p3(PartitionOp::Merge(Element(7), Element(8)));
}

TEST(PartitionUtilsTest, Join1) {
  llvm::BumpPtrAllocator allocator;
  Partition::SendingOperandSetFactory factory(allocator);
  IsolationHistory::Factory historyFactory(allocator, /*enabled=*/true);
  SendingOperandToStateMap transferringOpToStateMap(historyFactory);

  Element data1[] = {Element(0), Element(1), Element(2),
                     Element(3), Element(4), Element(5)};
  Partition p1 = Partition::separateRegions(fakeLoc, llvm::ArrayRef(data1),
                                            historyFactory.get());

  {
    MockedPartitionOpEvaluator eval(p1, factory, transferringOpToStateMap);
    eval.apply({PartitionOp::AssignDirect(Element(0), Element(0)),
                PartitionOp::AssignDirect(Element(1), Element(0)),
                PartitionOp::AssignDirect(Element(2), Element(2)),
                PartitionOp::AssignDirect(Element(3), Element(3)),
                PartitionOp::AssignDirect(Element(4), Element(3)),
                PartitionOp::AssignDirect(Element(5), Element(2))});
  }

  Partition p2 = Partition::separateRegions(fakeLoc, llvm::ArrayRef(data1),
                                            historyFactory.get());
  {
    MockedPartitionOpEvaluator eval(p2, factory, transferringOpToStateMap);
    eval.apply({PartitionOp::AssignDirect(Element(0), Element(0)),
                PartitionOp::AssignDirect(Element(1), Element(0)),
                PartitionOp::AssignDirect(Element(2), Element(2)),
                PartitionOp::AssignDirect(Element(3), Element(3)),
                PartitionOp::AssignDirect(Element(4), Element(3)),
                PartitionOp::AssignDirect(Element(5), Element(5))});
  }

  auto result = Partition::join(p1, p2);
  PartitionTester tester(result);
  ASSERT_EQ(tester.getRegion(0), 0);
  ASSERT_EQ(tester.getRegion(1), 0);
  ASSERT_EQ(tester.getRegion(2), 2);
  ASSERT_EQ(tester.getRegion(3), 3);
  ASSERT_EQ(tester.getRegion(4), 3);
  ASSERT_EQ(tester.getRegion(5), 2);
}

TEST(PartitionUtilsTest, Join2) {
  llvm::BumpPtrAllocator allocator;
  Partition::SendingOperandSetFactory factory(allocator);
  IsolationHistory::Factory historyFactory(allocator, /*enabled=*/true);
  SendingOperandToStateMap transferringOpToStateMap(historyFactory);

  Element data1[] = {Element(0), Element(1), Element(2),
                     Element(3), Element(4), Element(5)};
  Partition p1 = Partition::separateRegions(fakeLoc, llvm::ArrayRef(data1),
                                            historyFactory.get());

  {
    MockedPartitionOpEvaluator eval(p1, factory, transferringOpToStateMap);
    eval.apply({PartitionOp::AssignDirect(Element(0), Element(0)),
                PartitionOp::AssignDirect(Element(1), Element(0)),
                PartitionOp::AssignDirect(Element(2), Element(2)),
                PartitionOp::AssignDirect(Element(3), Element(3)),
                PartitionOp::AssignDirect(Element(4), Element(3)),
                PartitionOp::AssignDirect(Element(5), Element(2))});
  }

  Element data2[] = {Element(4), Element(5), Element(6),
                     Element(7), Element(8), Element(9)};
  Partition p2 = Partition::separateRegions(fakeLoc, llvm::ArrayRef(data2),
                                            historyFactory.get());
  {
    MockedPartitionOpEvaluator eval(p2, factory, transferringOpToStateMap);
    eval.apply({PartitionOp::AssignDirect(Element(4), Element(4)),
                PartitionOp::AssignDirect(Element(5), Element(5)),
                PartitionOp::AssignDirect(Element(6), Element(4)),
                PartitionOp::AssignDirect(Element(7), Element(7)),
                PartitionOp::AssignDirect(Element(8), Element(7)),
                PartitionOp::AssignDirect(Element(9), Element(4))});
  }

  auto result = Partition::join(p1, p2);
  PartitionTester tester(result);
  ASSERT_EQ(tester.getRegion(0), 0);
  ASSERT_EQ(tester.getRegion(1), 0);
  ASSERT_EQ(tester.getRegion(2), 2);
  ASSERT_EQ(tester.getRegion(3), 3);
  ASSERT_EQ(tester.getRegion(4), 3);
  ASSERT_EQ(tester.getRegion(5), 2);
  ASSERT_EQ(tester.getRegion(6), 3);
  ASSERT_EQ(tester.getRegion(7), 7);
  ASSERT_EQ(tester.getRegion(8), 7);
  ASSERT_EQ(tester.getRegion(9), 3);
}

TEST(PartitionUtilsTest, Join2Reversed) {
  llvm::BumpPtrAllocator allocator;
  Partition::SendingOperandSetFactory factory(allocator);
  IsolationHistory::Factory historyFactory(allocator, /*enabled=*/true);
  SendingOperandToStateMap transferringOpToStateMap(historyFactory);

  Element data1[] = {Element(0), Element(1), Element(2),
                     Element(3), Element(4), Element(5)};
  Partition p1 = Partition::separateRegions(fakeLoc, llvm::ArrayRef(data1),
                                            historyFactory.get());

  {
    MockedPartitionOpEvaluator eval(p1, factory, transferringOpToStateMap);
    eval.apply({PartitionOp::AssignDirect(Element(0), Element(0)),
                PartitionOp::AssignDirect(Element(1), Element(0)),
                PartitionOp::AssignDirect(Element(2), Element(2)),
                PartitionOp::AssignDirect(Element(3), Element(3)),
                PartitionOp::AssignDirect(Element(4), Element(3)),
                PartitionOp::AssignDirect(Element(5), Element(2))});
  }

  Element data2[] = {Element(4), Element(5), Element(6),
                     Element(7), Element(8), Element(9)};
  Partition p2 = Partition::separateRegions(fakeLoc, llvm::ArrayRef(data2),
                                            historyFactory.get());
  {
    MockedPartitionOpEvaluator eval(p2, factory, transferringOpToStateMap);
    eval.apply({PartitionOp::AssignDirect(Element(4), Element(4)),
                PartitionOp::AssignDirect(Element(5), Element(5)),
                PartitionOp::AssignDirect(Element(6), Element(4)),
                PartitionOp::AssignDirect(Element(7), Element(7)),
                PartitionOp::AssignDirect(Element(8), Element(7)),
                PartitionOp::AssignDirect(Element(9), Element(4))});
  }

  auto result = Partition::join(p2, p1);
  PartitionTester tester(result);
  ASSERT_EQ(tester.getRegion(0), 0);
  ASSERT_EQ(tester.getRegion(1), 0);
  ASSERT_EQ(tester.getRegion(2), 2);
  ASSERT_EQ(tester.getRegion(3), 3);
  ASSERT_EQ(tester.getRegion(4), 3);
  ASSERT_EQ(tester.getRegion(5), 2);
  ASSERT_EQ(tester.getRegion(6), 3);
  ASSERT_EQ(tester.getRegion(7), 7);
  ASSERT_EQ(tester.getRegion(8), 7);
  ASSERT_EQ(tester.getRegion(9), 3);
}

TEST(PartitionUtilsTest, JoinLarge) {
  llvm::BumpPtrAllocator allocator;
  Partition::SendingOperandSetFactory factory(allocator);
  IsolationHistory::Factory historyFactory(allocator, /*enabled=*/true);
  SendingOperandToStateMap transferringOpToStateMap(historyFactory);

  Element data1[] = {
      Element(0),  Element(1),  Element(2),  Element(3),  Element(4),
      Element(5),  Element(6),  Element(7),  Element(8),  Element(9),
      Element(10), Element(11), Element(12), Element(13), Element(14),
      Element(15), Element(16), Element(17), Element(18), Element(19),
      Element(20), Element(21), Element(22), Element(23), Element(24),
      Element(25), Element(26), Element(27), Element(28), Element(29)};
  Partition p1 = Partition::separateRegions(fakeLoc, llvm::ArrayRef(data1),
                                            historyFactory.get());
  {
    MockedPartitionOpEvaluator eval(p1, factory, transferringOpToStateMap);
    eval.apply({PartitionOp::AssignDirect(Element(0), Element(29)),
                PartitionOp::AssignDirect(Element(1), Element(17)),
                PartitionOp::AssignDirect(Element(2), Element(0)),
                PartitionOp::AssignDirect(Element(3), Element(12)),
                PartitionOp::AssignDirect(Element(4), Element(13)),
                PartitionOp::AssignDirect(Element(5), Element(9)),
                PartitionOp::AssignDirect(Element(6), Element(15)),
                PartitionOp::AssignDirect(Element(7), Element(27)),
                PartitionOp::AssignDirect(Element(8), Element(3)),
                PartitionOp::AssignDirect(Element(9), Element(3)),
                PartitionOp::AssignDirect(Element(10), Element(3)),
                PartitionOp::AssignDirect(Element(11), Element(21)),
                PartitionOp::AssignDirect(Element(12), Element(14)),
                PartitionOp::AssignDirect(Element(13), Element(25)),
                PartitionOp::AssignDirect(Element(14), Element(1)),
                PartitionOp::AssignDirect(Element(15), Element(25)),
                PartitionOp::AssignDirect(Element(16), Element(12)),
                PartitionOp::AssignDirect(Element(17), Element(3)),
                PartitionOp::AssignDirect(Element(18), Element(25)),
                PartitionOp::AssignDirect(Element(19), Element(13)),
                PartitionOp::AssignDirect(Element(20), Element(19)),
                PartitionOp::AssignDirect(Element(21), Element(7)),
                PartitionOp::AssignDirect(Element(22), Element(19)),
                PartitionOp::AssignDirect(Element(23), Element(27)),
                PartitionOp::AssignDirect(Element(24), Element(1)),
                PartitionOp::AssignDirect(Element(25), Element(9)),
                PartitionOp::AssignDirect(Element(26), Element(18)),
                PartitionOp::AssignDirect(Element(27), Element(29)),
                PartitionOp::AssignDirect(Element(28), Element(28)),
                PartitionOp::AssignDirect(Element(29), Element(13))});
  }

  Element data2[] = {
      Element(15), Element(16), Element(17), Element(18), Element(19),
      Element(20), Element(21), Element(22), Element(23), Element(24),
      Element(25), Element(26), Element(27), Element(28), Element(29),
      Element(30), Element(31), Element(32), Element(33), Element(34),
      Element(35), Element(36), Element(37), Element(38), Element(39),
      Element(40), Element(41), Element(42), Element(43), Element(44)};
  Partition p2 = Partition::separateRegions(fakeLoc, llvm::ArrayRef(data2),
                                            historyFactory.get());
  {
    MockedPartitionOpEvaluator eval(p2, factory, transferringOpToStateMap);
    eval.apply({PartitionOp::AssignDirect(Element(15), Element(31)),
                PartitionOp::AssignDirect(Element(16), Element(34)),
                PartitionOp::AssignDirect(Element(17), Element(35)),
                PartitionOp::AssignDirect(Element(18), Element(41)),
                PartitionOp::AssignDirect(Element(19), Element(15)),
                PartitionOp::AssignDirect(Element(20), Element(32)),
                PartitionOp::AssignDirect(Element(21), Element(17)),
                PartitionOp::AssignDirect(Element(22), Element(31)),
                PartitionOp::AssignDirect(Element(23), Element(21)),
                PartitionOp::AssignDirect(Element(24), Element(33)),
                PartitionOp::AssignDirect(Element(25), Element(25)),
                PartitionOp::AssignDirect(Element(26), Element(31)),
                PartitionOp::AssignDirect(Element(27), Element(16)),
                PartitionOp::AssignDirect(Element(28), Element(35)),
                PartitionOp::AssignDirect(Element(29), Element(40)),
                PartitionOp::AssignDirect(Element(30), Element(33)),
                PartitionOp::AssignDirect(Element(31), Element(34)),
                PartitionOp::AssignDirect(Element(32), Element(22)),
                PartitionOp::AssignDirect(Element(33), Element(42)),
                PartitionOp::AssignDirect(Element(34), Element(37)),
                PartitionOp::AssignDirect(Element(35), Element(34)),
                PartitionOp::AssignDirect(Element(36), Element(18)),
                PartitionOp::AssignDirect(Element(37), Element(32)),
                PartitionOp::AssignDirect(Element(38), Element(22)),
                PartitionOp::AssignDirect(Element(39), Element(44)),
                PartitionOp::AssignDirect(Element(40), Element(20)),
                PartitionOp::AssignDirect(Element(41), Element(37)),
                PartitionOp::AssignDirect(Element(43), Element(29)),
                PartitionOp::AssignDirect(Element(44), Element(25))});
  }

  auto result = Partition::join(p1, p2);
  PartitionTester tester(result);
  ASSERT_EQ(tester.getRegion(0), 0);
  ASSERT_EQ(tester.getRegion(1), 1);
  ASSERT_EQ(tester.getRegion(2), 0);
  ASSERT_EQ(tester.getRegion(3), 3);
  ASSERT_EQ(tester.getRegion(4), 4);
  ASSERT_EQ(tester.getRegion(5), 5);
  ASSERT_EQ(tester.getRegion(6), 6);
  ASSERT_EQ(tester.getRegion(7), 3);
  ASSERT_EQ(tester.getRegion(8), 3);
  ASSERT_EQ(tester.getRegion(9), 3);
  ASSERT_EQ(tester.getRegion(10), 3);
  ASSERT_EQ(tester.getRegion(11), 11);
  ASSERT_EQ(tester.getRegion(12), 0);
  ASSERT_EQ(tester.getRegion(13), 13);
  ASSERT_EQ(tester.getRegion(14), 1);
  ASSERT_EQ(tester.getRegion(15), 13);
  ASSERT_EQ(tester.getRegion(16), 0);
  ASSERT_EQ(tester.getRegion(17), 3);
  ASSERT_EQ(tester.getRegion(18), 13);
  ASSERT_EQ(tester.getRegion(19), 13);
  ASSERT_EQ(tester.getRegion(20), 13);
  ASSERT_EQ(tester.getRegion(21), 3);
  ASSERT_EQ(tester.getRegion(22), 13);
  ASSERT_EQ(tester.getRegion(23), 3);
  ASSERT_EQ(tester.getRegion(24), 1);
  ASSERT_EQ(tester.getRegion(25), 3);
  ASSERT_EQ(tester.getRegion(26), 13);
  ASSERT_EQ(tester.getRegion(27), 0);
  ASSERT_EQ(tester.getRegion(28), 3);
  ASSERT_EQ(tester.getRegion(29), 13);
  ASSERT_EQ(tester.getRegion(30), 1);
  ASSERT_EQ(tester.getRegion(31), 0);
  ASSERT_EQ(tester.getRegion(32), 13);
  ASSERT_EQ(tester.getRegion(33), 33);
  ASSERT_EQ(tester.getRegion(34), 34);
  ASSERT_EQ(tester.getRegion(35), 34);
  ASSERT_EQ(tester.getRegion(36), 13);
  ASSERT_EQ(tester.getRegion(37), 13);
  ASSERT_EQ(tester.getRegion(38), 13);
  ASSERT_EQ(tester.getRegion(39), 39);
  ASSERT_EQ(tester.getRegion(40), 13);
  ASSERT_EQ(tester.getRegion(41), 13);
  ASSERT_EQ(tester.getRegion(42), 33);
  ASSERT_EQ(tester.getRegion(43), 13);
  ASSERT_EQ(tester.getRegion(44), 3);
}

// This test tests the semantics of assignment.
TEST(PartitionUtilsTest, TestAssign) {
  llvm::BumpPtrAllocator allocator;
  Partition::SendingOperandSetFactory factory(allocator);
  IsolationHistory::Factory historyFactory(allocator, /*enabled=*/true);
  SendingOperandToStateMap transferringOpToStateMap(historyFactory);

  Partition p1(historyFactory.get());
  Partition p2(historyFactory.get());
  Partition p3(historyFactory.get());

  MockedPartitionOpEvaluator evalP1(p1, factory, transferringOpToStateMap);
  evalP1.apply({PartitionOp::AssignFresh(Element(0)),
                PartitionOp::AssignFresh(Element(1)),
                PartitionOp::AssignFresh(Element(2)),
                PartitionOp::AssignFresh(Element(3))});

  MockedPartitionOpEvaluator evalP2(p2, factory, transferringOpToStateMap);
  evalP2.apply({PartitionOp::AssignFresh(Element(0)),
                PartitionOp::AssignFresh(Element(1)),
                PartitionOp::AssignFresh(Element(2)),
                PartitionOp::AssignFresh(Element(3))});

  MockedPartitionOpEvaluator evalP3(p3, factory, transferringOpToStateMap);
  evalP3.apply({PartitionOp::AssignFresh(Element(0)),
                PartitionOp::AssignFresh(Element(1)),
                PartitionOp::AssignFresh(Element(2)),
                PartitionOp::AssignFresh(Element(3))});

  // expected: p1: ((Element(0)) (Element(1)) (Element(2)) (Element(3))), p2:
  // ((Element(0)) (Element(1)) (Element(2)) (Element(3))), p3: ((Element(0))
  // (Element(1)) (Element(2)) (Element(3)))

  EXPECT_TRUE(Partition::equals(p1, p2));
  EXPECT_TRUE(Partition::equals(p2, p3));
  EXPECT_TRUE(Partition::equals(p1, p3));

  evalP1.apply(PartitionOp::AssignDirect(Element(0), Element(1)));
  evalP2.apply(PartitionOp::AssignDirect(Element(1), Element(0)));
  evalP3.apply(PartitionOp::AssignDirect(Element(2), Element(1)));

  // expected: p1: ((0 1) (Element(2)) (Element(3))), p2: ((0 1) (Element(2))
  // (Element(3))), p3: ((Element(0)) (1 2) (Element(3)))

  EXPECT_TRUE(Partition::equals(p1, p2));
  EXPECT_FALSE(Partition::equals(p2, p3));
  EXPECT_FALSE(Partition::equals(p1, p3));

  evalP1.apply(PartitionOp::AssignDirect(Element(2), Element(0)));
  evalP2.apply(PartitionOp::AssignDirect(Element(2), Element(1)));
  evalP3.apply(PartitionOp::AssignDirect(Element(0), Element(2)));

  // expected: p1: ((0 1 2) (Element(3))), p2: ((0 1 2) (Element(3))), p3: ((0 1
  // 2) (Element(3)))

  EXPECT_TRUE(Partition::equals(p1, p2));
  EXPECT_TRUE(Partition::equals(p2, p3));
  EXPECT_TRUE(Partition::equals(p1, p3));

  evalP1.apply(PartitionOp::AssignDirect(Element(0), Element(3)));
  evalP2.apply(PartitionOp::AssignDirect(Element(1), Element(3)));
  evalP3.apply(PartitionOp::AssignDirect(Element(2), Element(3)));

  // expected: p1: ((1 2) (0 3)), p2: ((0 2) (1 3)), p3: ((0 1) (2 3))

  EXPECT_FALSE(Partition::equals(p1, p2));
  EXPECT_FALSE(Partition::equals(p2, p3));
  EXPECT_FALSE(Partition::equals(p1, p3));

  evalP1.apply(PartitionOp::AssignDirect(Element(1), Element(0)));
  evalP2.apply(PartitionOp::AssignDirect(Element(2), Element(1)));
  evalP3.apply(PartitionOp::AssignDirect(Element(0), Element(2)));

  // expected: p1: ((Element(2)) (0 1 3)), p2: ((Element(0)) (1 2 3)), p3:
  // ((Element(1)) (0 2 3))

  EXPECT_FALSE(Partition::equals(p1, p2));
  EXPECT_FALSE(Partition::equals(p2, p3));
  EXPECT_FALSE(Partition::equals(p1, p3));

  evalP1.apply(PartitionOp::AssignDirect(Element(2), Element(3)));
  evalP2.apply(PartitionOp::AssignDirect(Element(0), Element(3)));
  evalP3.apply(PartitionOp::AssignDirect(Element(1), Element(3)));

  // expected: p1: ((0 1 2 3)), p2: ((0 1 2 3)), p3: ((0 1 2 3))

  EXPECT_TRUE(Partition::equals(p1, p2));
  EXPECT_TRUE(Partition::equals(p2, p3));
  EXPECT_TRUE(Partition::equals(p1, p3));
}

// This test tests that consumption consumes entire regions as expected
TEST(PartitionUtilsTest, TestConsumeAndRequire) {
  llvm::BumpPtrAllocator allocator;
  Partition::SendingOperandSetFactory factory(allocator);
  IsolationHistory::Factory historyFactory(allocator, /*enabled=*/true);
  SendingOperandToStateMap transferringOpToStateMap(historyFactory);

  Partition p(historyFactory.get());

  {
    MockedPartitionOpEvaluator eval(p, factory, transferringOpToStateMap);
    eval.apply({PartitionOp::AssignFresh(Element(0)),
                PartitionOp::AssignFresh(Element(1)),
                PartitionOp::AssignFresh(Element(2)),
                PartitionOp::AssignFresh(Element(3)),
                PartitionOp::AssignFresh(Element(4)),
                PartitionOp::AssignFresh(Element(5)),
                PartitionOp::AssignFresh(Element(6)),
                PartitionOp::AssignFresh(Element(7)),
                PartitionOp::AssignFresh(Element(8)),
                PartitionOp::AssignFresh(Element(9)),
                PartitionOp::AssignFresh(Element(10)),
                PartitionOp::AssignFresh(Element(11)),

                PartitionOp::AssignDirect(Element(1), Element(0)),
                PartitionOp::AssignDirect(Element(2), Element(1)),

                PartitionOp::AssignDirect(Element(4), Element(3)),
                PartitionOp::AssignDirect(Element(5), Element(4)),

                PartitionOp::AssignDirect(Element(7), Element(6)),
                PartitionOp::AssignDirect(Element(9), Element(8)),

                // expected: p: ((0 1 2) (3 4 5) (6 7) (8 9) (Element(10))
                // (Element(11)))

                PartitionOp::Send(Element(2), operandSingletons[0]),
                PartitionOp::Send(Element(7), operandSingletons[1]),
                PartitionOp::Send(Element(10), operandSingletons[2])});
  }

  // expected: p: ({0 1 2 6 7 10} (3 4 5) (8 9) (Element(11)))

  auto never_called = [](const PartitionOp &, unsigned, Operand *) {
    EXPECT_TRUE(false);
  };

  int times_called = 0;
  auto increment_times_called = [&](const PartitionOp &, unsigned, Operand *) {
    times_called++;
  };

  {
    MockedPartitionOpEvaluatorWithFailureCallback eval(
        p, factory, transferringOpToStateMap, increment_times_called);
    eval.apply({PartitionOp::Require(Element(0)),
                PartitionOp::Require(Element(1)),
                PartitionOp::Require(Element(2))});
  }
  EXPECT_EQ(times_called, 3);

  {
    MockedPartitionOpEvaluatorWithFailureCallback eval(
        p, factory, transferringOpToStateMap, never_called);
    eval.apply({PartitionOp::Require(Element(3)),
                PartitionOp::Require(Element(4)),
                PartitionOp::Require(Element(5))});
  }

  {
    MockedPartitionOpEvaluatorWithFailureCallback eval(
        p, factory, transferringOpToStateMap, increment_times_called);
    eval.apply(
        {PartitionOp::Require(Element(6)), PartitionOp::Require(Element(7))});
  }

  {
    MockedPartitionOpEvaluatorWithFailureCallback eval(
        p, factory, transferringOpToStateMap, never_called);
    eval.apply(
        {PartitionOp::Require(Element(8)), PartitionOp::Require(Element(9))});
  }

  {
    MockedPartitionOpEvaluatorWithFailureCallback eval(
        p, factory, transferringOpToStateMap, increment_times_called);
    eval.apply(PartitionOp::Require(Element(10)));
  }

  {
    MockedPartitionOpEvaluatorWithFailureCallback eval(
        p, factory, transferringOpToStateMap, never_called);
    eval.apply(PartitionOp::Require(Element(11)));
  }

  EXPECT_EQ(times_called, 6);
}

// This test tests that the copy constructor is usable to create fresh
// copies of partitions
TEST(PartitionUtilsTest, TestCopyConstructor) {
  llvm::BumpPtrAllocator allocator;
  Partition::SendingOperandSetFactory factory(allocator);
  IsolationHistory::Factory historyFactory(allocator, /*enabled=*/true);
  SendingOperandToStateMap transferringOpToStateMap(historyFactory);

  Partition p1(historyFactory.get());
  {
    MockedPartitionOpEvaluator eval(p1, factory, transferringOpToStateMap);
    eval.apply(PartitionOp::AssignFresh(Element(0)));
  }

  // Make copy.
  Partition p2 = p1;

  // Change p1 again.
  {
    MockedPartitionOpEvaluator eval(p1, factory, transferringOpToStateMap);
    eval.apply(PartitionOp::Send(Element(0), operandSingletons[0]));
  }

  {
    bool failure = false;
    MockedPartitionOpEvaluatorWithFailureCallback eval(
        p1, factory, transferringOpToStateMap,
        [&](const PartitionOp &, unsigned, Operand *) { failure = true; });
    eval.apply(PartitionOp::Require(Element(0)));
    EXPECT_TRUE(failure);
  }

  {
    MockedPartitionOpEvaluatorWithFailureCallback eval(
        p2, factory, transferringOpToStateMap,
        [](const PartitionOp &, unsigned, Operand *) { EXPECT_TRUE(false); });
    eval.apply(PartitionOp::Require(Element(0)));
  }
}

TEST(PartitionUtilsTest, TestUndoTransfer) {
  llvm::BumpPtrAllocator allocator;
  Partition::SendingOperandSetFactory factory(allocator);
  IsolationHistory::Factory historyFactory(allocator, /*enabled=*/true);
  SendingOperandToStateMap transferringOpToStateMap(historyFactory);

  Partition p(historyFactory.get());
  MockedPartitionOpEvaluatorWithFailureCallback eval(
      p, factory, transferringOpToStateMap,
      [&](const PartitionOp &, unsigned, Operand *) { EXPECT_TRUE(false); });

  // Shouldn't error on this.
  eval.apply({PartitionOp::AssignFresh(Element(0)),
              PartitionOp::Send(Element(0), operandSingletons[0]),
              PartitionOp::UndoSend(Element(0), instSingletons[0]),
              PartitionOp::Require(Element(0), instSingletons[0])});
}

TEST(PartitionUtilsTest, TestLastEltInTransferredRegion) {
  llvm::BumpPtrAllocator allocator;
  Partition::SendingOperandSetFactory factory(allocator);
  IsolationHistory::Factory historyFactory(allocator, /*enabled=*/true);
  SendingOperandToStateMap transferringOpToStateMap(historyFactory);

  // First make sure that we do this correctly with an assign fresh.
  Partition p(historyFactory.get());
  {
    MockedPartitionOpEvaluator eval(p, factory, transferringOpToStateMap);
    eval.apply({PartitionOp::AssignFresh(Element(0)),
                PartitionOp::AssignFresh(Element(1)),
                PartitionOp::AssignFresh(Element(2)),
                PartitionOp::Send(Element(0), operandSingletons[0]),
                PartitionOp::AssignFresh(Element(0))});
  }
  p.validateRegionToSendingOpMapRegions();

  // Now make sure that we do this correctly with assign.
  Partition p2(historyFactory.get());
  {
    MockedPartitionOpEvaluator eval(p2, factory, transferringOpToStateMap);
    eval.apply({PartitionOp::AssignFresh(Element(0)),
                PartitionOp::AssignFresh(Element(1)),
                PartitionOp::AssignFresh(Element(2)),
                PartitionOp::Send(Element(0), operandSingletons[0]),
                PartitionOp::AssignDirect(Element(0), Element(2))});
  }
  p2.validateRegionToSendingOpMapRegions();
}

TEST(PartitionUtilsTest, TestHistory_CreateVariable) {
  llvm::BumpPtrAllocator allocator;
  Partition::SendingOperandSetFactory factory(allocator);
  IsolationHistory::Factory historyFactory(allocator, /*enabled=*/true);
  SmallVector<IsolationHistory, 8> joinedHistories;
  SendingOperandToStateMap transferringOpToStateMap(historyFactory);

  // First make sure that we do this correctly with an assign fresh.
  Partition p(historyFactory.get());
  {
    MockedPartitionOpEvaluator eval(p, factory, transferringOpToStateMap);
    eval.apply({PartitionOp::AssignFresh(Element(0)),
                PartitionOp::AssignFresh(Element(1))});
  }

  Partition pSnapshot = p;

  {
    MockedPartitionOpEvaluator eval(p, factory, transferringOpToStateMap);
    eval.apply({PartitionOp::AssignFresh(Element(2))});
  }

  p.popHistory(joinedHistories);

  EXPECT_TRUE(Partition::equals(p, pSnapshot));
  EXPECT_TRUE(joinedHistories.empty());
}

TEST(PartitionUtilsTest, TestHistory_AssignRegion) {
  llvm::BumpPtrAllocator allocator;
  Partition::SendingOperandSetFactory factory(allocator);
  IsolationHistory::Factory historyFactory(allocator, /*enabled=*/true);
  SendingOperandToStateMap transferringOpToStateMap(historyFactory);
  SmallVector<IsolationHistory, 8> joinedHistories;

  // First make sure that we do this correctly with an assign fresh.
  Partition p(historyFactory.get());
  {
    MockedPartitionOpEvaluator eval(p, factory, transferringOpToStateMap);
    eval.apply({PartitionOp::AssignFresh(Element(0)),
                PartitionOp::AssignFresh(Element(1)),
                PartitionOp::AssignFresh(Element(2))});
  }

  Partition pSnapshot = p;

  {
    MockedPartitionOpEvaluator eval(p, factory, transferringOpToStateMap);
    eval.apply({PartitionOp::AssignDirect(Element(1), Element(2))});
  }

  Partition pSnapshot2 = p;
  {
    MockedPartitionOpEvaluator eval(p, factory, transferringOpToStateMap);
    eval.apply({PartitionOp::AssignDirect(Element(0), Element(2))});
  }

  p.popHistory(joinedHistories);

  EXPECT_TRUE(Partition::equals(p, pSnapshot2));
  EXPECT_TRUE(joinedHistories.empty());

  p.popHistory(joinedHistories);

  EXPECT_TRUE(Partition::equals(p, pSnapshot));
  EXPECT_TRUE(joinedHistories.empty());
}

TEST(PartitionUtilsTest, TestHistory_BuildNewRegionRepIsMergee) {
  llvm::BumpPtrAllocator allocator;
  Partition::SendingOperandSetFactory factory(allocator);
  IsolationHistory::Factory historyFactory(allocator, /*enabled=*/true);
  SendingOperandToStateMap transferringOpToStateMap(historyFactory);
  SmallVector<IsolationHistory, 8> joinedHistories;

  Partition p(historyFactory.get());
  {
    MockedPartitionOpEvaluator eval(p, factory, transferringOpToStateMap);
    eval.apply({PartitionOp::AssignFresh(Element(2)),
                PartitionOp::AssignFresh(Element(3)),
                PartitionOp::AssignFresh(Element(10)),
                PartitionOp::AssignFresh(Element(0)),
                PartitionOp::AssignDirect(Element(3), Element(2)),
                PartitionOp::AssignDirect(Element(10), Element(2)),
                PartitionOp::Merge(Element(2), Element(0))});
  }

  Partition pSnapshot = p;

  {
    MockedPartitionOpEvaluator eval(p, factory, transferringOpToStateMap);
    eval.apply({PartitionOp::AssignDirect(Element(1), Element(2))});
  }

  Partition pSnapshot2 = p;
  {
    MockedPartitionOpEvaluator eval(p, factory, transferringOpToStateMap);
    eval.apply({PartitionOp::AssignDirect(Element(0), Element(2))});
  }

  // Even though we pushed a new instruction, nothing changed in our region.
  EXPECT_TRUE(Partition::equals(p, pSnapshot2));

  // We pop but nothing changes since we did not need to change anything.
  p.popHistory(joinedHistories);

  EXPECT_TRUE(Partition::equals(p, pSnapshot2));
  EXPECT_TRUE(joinedHistories.empty());

  // We pop a last time to return to our original value.
  p.popHistory(joinedHistories);

  EXPECT_TRUE(Partition::equals(p, pSnapshot));
  EXPECT_TRUE(joinedHistories.empty());
}

TEST(PartitionUtilsTest, TestHistory_ReturnFalseWhenNoneLeft) {
  llvm::BumpPtrAllocator allocator;
  Partition::SendingOperandSetFactory factory(allocator);
  IsolationHistory::Factory historyFactory(allocator, /*enabled=*/true);
  SmallVector<IsolationHistory, 8> joinedHistories;
  SendingOperandToStateMap transferringOpToStateMap(historyFactory);

  Partition p(historyFactory.get());

  EXPECT_FALSE(p.popHistory(joinedHistories));
  EXPECT_TRUE(joinedHistories.empty());

  {
    MockedPartitionOpEvaluator eval(p, factory, transferringOpToStateMap);
    eval.apply({PartitionOp::AssignFresh(Element(2)),
                PartitionOp::AssignFresh(Element(3))});
  }

  EXPECT_TRUE(p.popHistory(joinedHistories));
  EXPECT_TRUE(joinedHistories.empty());

  EXPECT_FALSE(p.popHistory(joinedHistories));
  EXPECT_TRUE(joinedHistories.empty());
}

TEST(PartitionUtilsTest, TestHistory_JoiningTwoEmpty) {
  // Make sure that we do sane things when we join empty history.
  llvm::BumpPtrAllocator allocator;
  Partition::SendingOperandSetFactory factory(allocator);
  IsolationHistory::Factory historyFactory(allocator, /*enabled=*/true);
  SmallVector<IsolationHistory, 8> joinedHistories;

  Partition p1(historyFactory.get());
  Partition p2(historyFactory.get());

  auto result = Partition::join(p1, p2);
  EXPECT_TRUE(result.begin() == result.end());
  EXPECT_FALSE(result.hasHistory());
}

TEST(PartitionUtilsTest, TestHistory_JoiningNotEmptyAndEmpty) {
  // Make sure that we do sane things when we join empty history.
  llvm::BumpPtrAllocator allocator;
  Partition::SendingOperandSetFactory factory(allocator);
  IsolationHistory::Factory historyFactory(allocator, /*enabled=*/true);
  SmallVector<IsolationHistory, 8> joinedHistories;
  SendingOperandToStateMap transferringOpToStateMap(historyFactory);

  Partition p1(historyFactory.get());
  Partition p2(historyFactory.get());

  {
    MockedPartitionOpEvaluator eval(p1, factory, transferringOpToStateMap);
    eval.apply({PartitionOp::AssignFresh(Element(2))});
  }

  EXPECT_TRUE(p1.historySize() == 2);
  EXPECT_TRUE(p2.historySize() == 0);
  auto result = Partition::join(p1, p2);
  EXPECT_TRUE(std::next(result.begin()) == result.end());
  // Since p2 doesn't have any history, we do not actually perform any join and
  // thus do not insert a CFGHistory change.
  EXPECT_TRUE(result.historySize() == 2);
}

TEST(PartitionUtilsTest, TestHistory_JoiningEmptyAndNotEmpty) {
  // Make sure that we do sane things when we join empty history.
  llvm::BumpPtrAllocator allocator;
  Partition::SendingOperandSetFactory factory(allocator);
  IsolationHistory::Factory historyFactory(allocator, /*enabled=*/true);
  SendingOperandToStateMap transferringOpToStateMap(historyFactory);
  SmallVector<IsolationHistory, 8> joinedHistories;

  Partition p1(historyFactory.get());
  Partition p2(historyFactory.get());

  {
    MockedPartitionOpEvaluator eval(p1, factory, transferringOpToStateMap);
    eval.apply({PartitionOp::AssignFresh(Element(2))});
  }

  EXPECT_TRUE(p1.historySize() == 2);
  EXPECT_TRUE(p2.historySize() == 0);
  auto result = Partition::join(p1, p2);
  EXPECT_TRUE(std::next(result.begin()) == result.end());
  // Since p2 doesn't have any history, we do not actually perform any join and
  // thus do not insert a CFGHistory change.
  EXPECT_TRUE(result.historySize() == 2);
}

//===----------------------------------------------------------------------===//
//                         MARK: PersistentIndexMap
//===----------------------------------------------------------------------===//

namespace {

using IndexMap = PersistentIndexMap<unsigned, unsigned>;
using ReferenceMap = std::map<unsigned, unsigned>;

void expectSameEntries(const IndexMap &map, const ReferenceMap &reference) {
  EXPECT_EQ(map.size(), reference.size());
  EXPECT_EQ(map.empty(), reference.empty());
  std::vector<std::pair<unsigned, unsigned>> entries(map.begin(), map.end());
  std::vector<std::pair<unsigned, unsigned>> expected(reference.begin(),
                                                      reference.end());
  EXPECT_EQ(entries, expected);
  for (auto [key, value] : reference) {
    EXPECT_TRUE(map.count(key));
    EXPECT_EQ(map.at(key), value);
    EXPECT_EQ(map.lookup(key), std::optional<unsigned>(value));
  }
}

} // namespace

TEST(PersistentIndexMapTest, Basic) {
  IndexMap map;
  EXPECT_TRUE(map.empty());
  EXPECT_TRUE(map.begin() == map.end());
  EXPECT_FALSE(map.count(0));
  EXPECT_EQ(map.lookup(5), std::nullopt);

  EXPECT_TRUE(map.insert(5, 1));
  EXPECT_FALSE(map.insert(5, 2));
  EXPECT_EQ(map.at(5), 1u);
  map.set(5, 3);
  EXPECT_EQ(map.at(5), 3u);
  EXPECT_EQ(map.size(), 1u);

  // Keys far apart grow the trie; iteration stays in key order.
  map.set(1u << 20, 7);
  map.set(0, 9);
  map.set(~0u - 1, 11);
  expectSameEntries(map, {{0, 9}, {5, 3}, {1u << 20, 7}, {~0u - 1, 11}});

  EXPECT_TRUE(map.erase(5));
  EXPECT_FALSE(map.erase(5));
  EXPECT_FALSE(map.erase(6));
  expectSameEntries(map, {{0, 9}, {1u << 20, 7}, {~0u - 1, 11}});

  map.clear();
  expectSameEntries(map, {});
}

TEST(PersistentIndexMapTest, CopiesAreIndependent) {
  IndexMap original;
  ReferenceMap originalReference;
  for (unsigned i = 0; i < 3000; i += 3) {
    original.set(i, i + 1);
    originalReference[i] = i + 1;
  }

  IndexMap copy = original;
  EXPECT_TRUE(copy == original);
  ReferenceMap copyReference = originalReference;

  copy.set(3, 100);
  copy.set(3001, 5);
  copy.erase(2997);
  copyReference[3] = 100;
  copyReference[3001] = 5;
  copyReference.erase(2997);
  copy.updateValues(
      [](unsigned key, unsigned value) { return key % 2 ? value * 2 : value; });
  for (auto &[key, value] : copyReference)
    if (key % 2)
      value *= 2;

  expectSameEntries(original, originalReference);
  expectSameEntries(copy, copyReference);
  EXPECT_FALSE(copy == original);

  // Mutating the original leaves the copy alone too.
  original.set(1, 1);
  originalReference[1] = 1;
  expectSameEntries(original, originalReference);
  expectSameEntries(copy, copyReference);

  // Assignment, self assignment and moves.
  IndexMap assigned;
  assigned.set(4, 4);
  assigned = copy;
  expectSameEntries(assigned, copyReference);
  IndexMap &alias = assigned;
  assigned = alias;
  expectSameEntries(assigned, copyReference);
  IndexMap moved = std::move(assigned);
  expectSameEntries(moved, copyReference);
  IndexMap moveAssigned;
  moveAssigned = std::move(moved);
  expectSameEntries(moveAssigned, copyReference);
  expectSameEntries(copy, copyReference);
}

TEST(PersistentIndexMapTest, UpdateValuesVisitsInOrderAndCopiesOnWrite) {
  IndexMap map;
  for (unsigned i : {70u, 3u, 1025u, 0u, 64u})
    map.set(i, i);
  IndexMap copy = map;

  std::vector<unsigned> visited;
  map.updateValues([&](unsigned key, unsigned value) {
    visited.push_back(key);
    return value;
  });
  EXPECT_EQ(visited, (std::vector<unsigned>{0, 3, 64, 70, 1025}));
  EXPECT_TRUE(map == copy);

  map.updateValues(
      [&](unsigned key, unsigned value) { return key == 64 ? 1 : value; });
  expectSameEntries(map, {{0, 0}, {3, 3}, {64, 1}, {70, 70}, {1025, 1025}});
  expectSameEntries(copy, {{0, 0}, {3, 3}, {64, 64}, {70, 70}, {1025, 1025}});
}

TEST(PersistentIndexMapTest, EqualityIgnoresStructure) {
  // Same entries, built differently: one map once held a key that made its
  // trie taller, the other never did.
  IndexMap tall;
  tall.set(1u << 16, 1);
  tall.set(2, 2);
  tall.erase(1u << 16);
  IndexMap flat;
  flat.set(2, 2);
  EXPECT_TRUE(tall == flat);
  EXPECT_TRUE(flat == tall);

  // Same height, with an emptied subtree on one side only.
  IndexMap a;
  a.set(2, 2);
  a.set(40, 4);
  a.set(700, 7);
  a.erase(700);
  IndexMap b;
  b.set(40, 4);
  b.set(2, 2);
  b.set(900, 9);
  b.erase(900);
  EXPECT_TRUE(a == b);
  b.set(40, 5);
  EXPECT_FALSE(a == b);
  b.set(40, 4);
  EXPECT_TRUE(a == b);
  b.set(41, 4);
  EXPECT_FALSE(a == b);

  IndexMap empty1, empty2;
  EXPECT_TRUE(empty1 == empty2);
  empty2.set(3, 3);
  empty2.erase(3);
  EXPECT_TRUE(empty1 == empty2);
}

TEST(PersistentIndexMapTest, RandomizedAgainstStdMap) {
  // Run random operations on a family of maps that share structure and check
  // each against a std::map after every step.
  std::mt19937 generator(41);
  std::vector<IndexMap> maps(4);
  std::vector<ReferenceMap> references(4);
  auto randomKey = [&]() -> unsigned {
    switch (generator() % 4) {
    case 0:
      return generator() % 64;
    case 1:
      return generator() % 2048;
    case 2:
      return generator() % 70000;
    default:
      return generator() % 300;
    }
  };

  for (unsigned step = 0; step < 20000; ++step) {
    unsigned index = generator() % maps.size();
    IndexMap &map = maps[index];
    ReferenceMap &reference = references[index];
    switch (generator() % 8) {
    case 0:
    case 1: {
      unsigned key = randomKey(), value = generator() % 1000;
      map.set(key, value);
      reference[key] = value;
      break;
    }
    case 2: {
      unsigned key = randomKey(), value = generator() % 1000;
      EXPECT_EQ(map.insert(key, value), reference.insert({key, value}).second);
      break;
    }
    case 3: {
      unsigned key = randomKey();
      EXPECT_EQ(map.erase(key), bool(reference.erase(key)));
      break;
    }
    case 4: {
      unsigned other = generator() % maps.size();
      maps[index] = maps[other];
      references[index] = references[other];
      break;
    }
    case 5: {
      unsigned modulus = generator() % 5 + 2, delta = generator() % 3;
      auto fn = [&](unsigned key, unsigned value) {
        return key % modulus ? value : value + delta;
      };
      map.updateValues(fn);
      for (auto &[key, value] : reference)
        value = fn(key, value);
      break;
    }
    case 6: {
      unsigned other = generator() % maps.size();
      EXPECT_EQ(map == maps[other], reference == references[other]);
      break;
    }
    default: {
      unsigned key = randomKey();
      auto iter = reference.find(key);
      EXPECT_EQ(map.lookup(key), iter == reference.end()
                                     ? std::nullopt
                                     : std::optional<unsigned>(iter->second));
      break;
    }
    }
    if (step % 97 == 0)
      for (unsigned i = 0; i < maps.size(); ++i)
        expectSameEntries(maps[i], references[i]);
  }
  for (unsigned i = 0; i < maps.size(); ++i)
    expectSameEntries(maps[i], references[i]);
}

TEST(PersistentIndexMapTest, MaxKey) {
  IndexMap map;
  EXPECT_EQ(map.getMaxKey(), std::nullopt);
  map.set(3, 3);
  EXPECT_EQ(map.getMaxKey(), std::optional<unsigned>(3));
  map.set(5000, 1);
  map.set(40, 1);
  EXPECT_EQ(map.getMaxKey(), std::optional<unsigned>(5000));
  // An emptied leaf at the end of the trie is skipped.
  map.erase(5000);
  EXPECT_EQ(map.getMaxKey(), std::optional<unsigned>(40));
  map.erase(40);
  map.erase(3);
  EXPECT_EQ(map.getMaxKey(), std::nullopt);
}

TEST(PersistentIndexMapTest, LeafBoundariesAndAllValues) {
  // Every unsigned is a valid value, and the entries at either end of a leaf
  // are found by lookup, iteration and updateValues alike.
  IndexMap map;
  map.set(31, ~0u);
  map.set(32, 0);
  map.set(63, 5);
  map.set(0, ~0u - 1);
  expectSameEntries(map, {{0, ~0u - 1}, {31, ~0u}, {32, 0}, {63, 5}});
  EXPECT_EQ(map.getMaxKey(), std::optional<unsigned>(63));

  std::vector<unsigned> visited;
  map.updateValues([&](unsigned key, unsigned value) {
    visited.push_back(key);
    return key == 31 ? 0 : value;
  });
  EXPECT_EQ(visited, (std::vector<unsigned>{0, 31, 32, 63}));
  expectSameEntries(map, {{0, ~0u - 1}, {31, 0}, {32, 0}, {63, 5}});

  // An erased entry leaves its leaf as if the key had never been set.
  IndexMap other;
  other.set(0, ~0u - 1);
  other.set(32, 0);
  other.set(63, 5);
  EXPECT_FALSE(map == other);
  map.erase(31);
  EXPECT_TRUE(map == other);
}

TEST(PartitionUtilsTest, JoinIntoEmptyPartition) {
  // Joining into a partition without elements takes the other partition as it
  // is, and records the history an element by element join would.
  llvm::BumpPtrAllocator allocator;
  Partition::SendingOperandSetFactory factory(allocator);
  IsolationHistory::Factory historyFactory(allocator, /*enabled=*/true);
  auto *sendingOperand = reinterpret_cast<Operand *>(uintptr_t(0x1000));

  Partition p(historyFactory.get());
  p.trackNewElement(Element(3));
  p.trackNewElement(Element(1));
  p.trackNewElement(Element(7));
  p.assignElement(Element(5), Element(1));
  p.merge(Element(7), Element(3));
  p.markSent(Element(7), factory.get(sendingOperand));
  p.markSent(Element(9), factory.get(sendingOperand));
  unsigned historySize = p.historySize();

  Partition empty(historyFactory.get());
  Partition result = Partition::join(empty, p);
  PartitionTester tester(result);
  EXPECT_EQ(tester.getRegion(1), 1u);
  EXPECT_EQ(tester.getRegion(3), 3u);
  EXPECT_EQ(tester.getRegion(5), 1u);
  EXPECT_EQ(tester.getRegion(7), 3u);
  EXPECT_EQ(tester.getRegion(9), 9u);
  EXPECT_FALSE(result.isSent(Element(1)));
  EXPECT_FALSE(result.isSent(Element(5)));
  EXPECT_TRUE(result.isSent(Element(3)));
  EXPECT_TRUE(result.isSent(Element(7)));
  EXPECT_TRUE(result.isSent(Element(9)));
  EXPECT_EQ(PartitionTester::getFreshLabel(result), 10u);
  EXPECT_TRUE(PartitionTester::isCanonical(result));
  // One node per element on top of the history taken over from p.
  EXPECT_EQ(result.historySize(), historySize + 5);
  EXPECT_TRUE(Partition::equals(result, p));

  // The element by element join builds the same partition and history.
  Partition otherEmpty(historyFactory.get());
  Partition elementByElement =
      PartitionTester::joinElementByElement(otherEmpty, p);
  EXPECT_TRUE(Partition::equals(elementByElement, result));
  EXPECT_EQ(PartitionTester::getFreshLabel(elementByElement), 10u);
  EXPECT_TRUE(PartitionTester::isCanonical(elementByElement));
  EXPECT_EQ(elementByElement.historySize(), result.historySize());
}

//===----------------------------------------------------------------------===//
//                 MARK: Canonicalization and join shortcuts
//===----------------------------------------------------------------------===//

// Run random sequences of partition mutations and check after each step that
// canonicalizing only the added elements gives the same partition as the walk
// over every element, and that joining into an empty partition gives what the
// element-by-element join would, history included.
TEST(PartitionUtilsTest, CanonicalizeAndJoinShortcutsMatchFullWalk) {
  llvm::BumpPtrAllocator allocator;
  Partition::SendingOperandSetFactory factory(allocator);
  IsolationHistory::Factory historyFactory(allocator, /*enabled=*/false);
  IsolationHistory::Factory recordingFactory(allocator, /*enabled=*/true);
  std::mt19937 generator(41);
  auto fakeOperand = [](unsigned i) {
    return reinterpret_cast<Operand *>(uintptr_t(0x1000 + 64 * i));
  };

  for (unsigned round = 0; round < 400; ++round) {
    Partition p(historyFactory.get());
    unsigned numElements = 4 + generator() % 40;
    auto randomElement = [&] { return Element(generator() % numElements); };
    auto randomTrackedElement = [&]() -> std::optional<Element> {
      auto entries = PartitionTester::getEntries(p);
      if (entries.empty())
        return std::nullopt;
      return Element(entries[generator() % entries.size()].first);
    };

    for (unsigned step = 0; step < 40; ++step) {
      switch (generator() % 10) {
      case 0:
      case 1:
      case 2:
        p.trackNewElement(randomElement());
        break;
      case 3:
      case 4:
        if (auto tracked = randomTrackedElement())
          p.assignElement(randomElement(), *tracked);
        break;
      case 5:
        if (auto lhs = randomTrackedElement())
          if (auto rhs = randomTrackedElement())
            p.merge(*lhs, *rhs);
        break;
      case 6:
        p.markSent(randomElement(), factory.get(fakeOperand(generator() % 5)));
        break;
      case 7:
        p.undoSend(randomElement());
        break;
      case 8:
        PartitionTester::canonicalize(p);
        break;
      default:
        break;
      }

      Partition shortcut = p;
      Partition fullWalk = PartitionTester::withFullCanonicalization(p);
      PartitionTester::canonicalize(shortcut);
      PartitionTester::canonicalize(fullWalk);
      PartitionTester::expectSameState(shortcut, fullWalk);
      if (testing::Test::HasFailure())
        return;

      // Joining into an empty partition, with and without the shortcut that
      // shares the other side's map. The empty side records history, so the
      // history the shortcut replicates is compared as well.
      Partition empty(recordingFactory.get());
      Partition snd = p;
      Partition joined = Partition::join(empty, snd);
      Partition otherEmpty(recordingFactory.get());
      Partition otherSnd = p;
      Partition elementByElement =
          PartitionTester::joinElementByElement(otherEmpty, otherSnd);
      PartitionTester::expectSameState(joined, elementByElement);
      EXPECT_EQ(joined.historySize(), elementByElement.historySize());
      EXPECT_TRUE(PartitionTester::isCanonical(joined));
      EXPECT_TRUE(Partition::equals(joined, fullWalk));
      if (testing::Test::HasFailure())
        return;
    }
  }
}
