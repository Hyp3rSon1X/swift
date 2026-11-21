//===--- PersistentIndexMap.h - Copy-on-write map from dense indices ------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
///
/// \file
///
/// A map from small, densely allocated unsigned keys to unsigned values with
/// value semantics whose copies share structure.
///
/// The map is a persistent radix trie: copying a map is O(1), and a mutation
/// copies only the nodes on the path from the root to the changed entry that
/// are still shared with another map. Iteration is in ascending key order.
///
/// The region analysis keeps an entry and an exit partition for every basic
/// block of a function, each mapping every value tracked so far to its region.
/// Consecutive partitions differ in a handful of entries, so storing each one
/// as an independent ordered map costs O(blocks x values) memory and time on a
/// large function; with shared structure the cost follows the number of
/// changes instead.
///
//===----------------------------------------------------------------------===//

#ifndef SWIFT_SILOPTIMIZER_UTILS_PERSISTENTINDEXMAP_H
#define SWIFT_SILOPTIMIZER_UTILS_PERSISTENTINDEXMAP_H

#include <algorithm>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <iterator>
#include <optional>
#include <utility>

namespace swift {

/// A map from \p KeyT to \p ValueT with value semantics and structural
/// sharing between copies.
///
/// \p KeyT and \p ValueT must convert to and from unsigned. Keys should be
/// dense (the trie is as deep as the largest key needs); the value ~0U is
/// reserved to mark a missing entry.
///
/// Copies are not thread safe: a map and its copies share reference counted
/// nodes without synchronization.
template <typename KeyT, typename ValueT>
class PersistentIndexMap {
  static constexpr unsigned BitsPerLevel = 5;
  static constexpr unsigned Fanout = 1u << BitsPerLevel;
  static constexpr unsigned LevelMask = Fanout - 1;

  /// The raw value stored in a leaf slot whose key is not in the map.
  static constexpr unsigned Absent = ~0u;

  struct Node {
    unsigned refCount = 1;
  };

  struct Leaf : Node {
    unsigned values[Fanout];

    Leaf() { std::fill(std::begin(values), std::end(values), Absent); }
    Leaf(const Leaf &other) : Node() {
      std::copy(std::begin(other.values), std::end(other.values),
                std::begin(values));
    }
  };

  struct Interior : Node {
    Node *children[Fanout] = {};

    Interior() = default;
    /// The copy shares, and so retains, every child of \p other.
    Interior(const Interior &other) : Node() {
      for (unsigned i = 0; i < Fanout; ++i) {
        children[i] = other.children[i];
        if (children[i])
          ++children[i]->refCount;
      }
    }
  };

  /// The root node, a leaf if height is zero. Null if the map never had an
  /// entry.
  Node *root = nullptr;

  /// The level of the root. A trie of height h holds keys below
  /// 2^(BitsPerLevel * (h + 1)).
  unsigned height = 0;

  /// The number of keys in the map.
  unsigned numEntries = 0;

public:
  class const_iterator;
  using iterator = const_iterator;
  using value_type = std::pair<KeyT, ValueT>;

  PersistentIndexMap() = default;

  PersistentIndexMap(const PersistentIndexMap &other)
      : root(other.root), height(other.height), numEntries(other.numEntries) {
    if (root)
      ++root->refCount;
  }

  PersistentIndexMap(PersistentIndexMap &&other) noexcept
      : root(other.root), height(other.height), numEntries(other.numEntries) {
    other.root = nullptr;
    other.height = 0;
    other.numEntries = 0;
  }

  PersistentIndexMap &operator=(const PersistentIndexMap &other) {
    // Retain first so that assigning a map to itself or to a map sharing its
    // root never frees the root.
    if (other.root)
      ++other.root->refCount;
    release(root, height);
    root = other.root;
    height = other.height;
    numEntries = other.numEntries;
    return *this;
  }

  PersistentIndexMap &operator=(PersistentIndexMap &&other) noexcept {
    if (this != &other) {
      release(root, height);
      root = other.root;
      height = other.height;
      numEntries = other.numEntries;
      other.root = nullptr;
      other.height = 0;
      other.numEntries = 0;
    }
    return *this;
  }

  ~PersistentIndexMap() { release(root, height); }

  unsigned size() const { return numEntries; }
  bool empty() const { return numEntries == 0; }

  bool count(KeyT key) const { return findSlot(unsigned(key)) != nullptr; }

  /// Return the value of \p key, or std::nullopt if \p key is not in the map.
  std::optional<ValueT> lookup(KeyT key) const {
    if (const unsigned *slot = findSlot(unsigned(key)))
      return ValueT(*slot);
    return std::nullopt;
  }

  /// Return the value of \p key, which must be in the map.
  ValueT at(KeyT key) const {
    const unsigned *slot = findSlot(unsigned(key));
    assert(slot && "Key is not in the map");
    return ValueT(*slot);
  }

  /// Map \p key to \p value, replacing any value \p key had.
  void set(KeyT key, ValueT value) {
    unsigned rawValue = unsigned(value);
    assert(rawValue != Absent && "~0U is reserved for missing entries");
    // Leave shared nodes alone if nothing changes.
    if (const unsigned *slot = findSlot(unsigned(key)))
      if (*slot == rawValue)
        return;
    unsigned &slot = getMutableSlot(unsigned(key));
    if (slot == Absent)
      ++numEntries;
    slot = rawValue;
  }

  /// Map \p key to \p value if \p key is not in the map yet. Returns true if
  /// the entry was inserted.
  bool insert(KeyT key, ValueT value) {
    if (count(key))
      return false;
    set(key, value);
    return true;
  }

  /// Remove \p key from the map. Returns true if \p key was in the map.
  bool erase(KeyT key) {
    if (!count(key))
      return false;
    getMutableSlot(unsigned(key)) = Absent;
    --numEntries;
    return true;
  }

  void clear() {
    release(root, height);
    root = nullptr;
    height = 0;
    numEntries = 0;
  }

  /// Replace the value of every entry with \p fn(key, value), visiting the
  /// keys in ascending order. Only nodes whose entries change are copied.
  template <typename Fn>
  void updateValues(Fn &&fn) {
    if (!root)
      return;
    Node *newRoot = updateNode(root, height, 0, /*mayMutateInPlace=*/true, fn);
    if (newRoot != root) {
      release(root, height);
      root = newRoot;
    }
  }

  /// Two maps are equal if they hold the same entries. Subtrees the maps
  /// share are not visited.
  friend bool operator==(const PersistentIndexMap &lhs,
                         const PersistentIndexMap &rhs) {
    if (lhs.numEntries != rhs.numEntries)
      return false;
    if (lhs.numEntries == 0)
      return true;
    if (lhs.height == rhs.height)
      return equalNodes(lhs.root, rhs.root, lhs.height);
    // Tries of different heights do not share nodes at the same level, so
    // just compare the entries.
    return std::equal(lhs.begin(), lhs.end(), rhs.begin(), rhs.end());
  }

  friend bool operator!=(const PersistentIndexMap &lhs,
                         const PersistentIndexMap &rhs) {
    return !(lhs == rhs);
  }

  /// Return the largest key in the map, or std::nullopt if the map is empty.
  std::optional<KeyT> getMaxKey() const {
    unsigned key = 0;
    if (root && findLast(root, height, 0, key))
      return KeyT(key);
    return std::nullopt;
  }

  const_iterator begin() const { return findFirstAtOrAfter(0); }
  const_iterator end() const { return const_iterator(); }

  /// Iterates over the entries of the map in ascending key order. Mutating
  /// the map invalidates its iterators.
  class const_iterator {
    friend PersistentIndexMap;

    const PersistentIndexMap *map = nullptr;
    /// The leaf that holds the current entry. Null for the end iterator.
    const Leaf *leaf = nullptr;
    unsigned key = 0;

    const_iterator(const PersistentIndexMap *map, const Leaf *leaf,
                   unsigned key)
        : map(map), leaf(leaf), key(key) {}

  public:
    using iterator_category = std::forward_iterator_tag;
    using value_type = PersistentIndexMap::value_type;
    using difference_type = std::ptrdiff_t;
    using pointer = const value_type *;
    using reference = value_type;

    const_iterator() = default;

    value_type operator*() const {
      assert(leaf && "Dereferencing the end iterator");
      return {KeyT(key), ValueT(leaf->values[key & LevelMask])};
    }

    const_iterator &operator++() {
      assert(leaf && "Incrementing the end iterator");
      // Look at the rest of the current leaf first...
      for (unsigned i = (key & LevelMask) + 1; i < Fanout; ++i) {
        if (leaf->values[i] != Absent) {
          key = (key & ~LevelMask) | i;
          return *this;
        }
      }
      // ... and only then search the trie for the next leaf.
      *this = map->findFirstAtOrAfter(uint64_t(key | LevelMask) + 1);
      return *this;
    }

    const_iterator operator++(int) {
      const_iterator result = *this;
      ++*this;
      return result;
    }

    friend bool operator==(const const_iterator &lhs,
                           const const_iterator &rhs) {
      return lhs.leaf == rhs.leaf && (!lhs.leaf || lhs.key == rhs.key);
    }

    friend bool operator!=(const const_iterator &lhs,
                           const const_iterator &rhs) {
      return !(lhs == rhs);
    }
  };

private:
  static unsigned indexAt(unsigned key, unsigned level) {
    return (key >> (BitsPerLevel * level)) & LevelMask;
  }

  static bool fitsInHeight(unsigned key, unsigned height) {
    unsigned bits = BitsPerLevel * (height + 1);
    return bits >= 32 || (key >> bits) == 0;
  }

  static uint64_t spanOfLevel(unsigned level) {
    return uint64_t(1) << (BitsPerLevel * level);
  }

  static Node *createNode(unsigned level) {
    if (level == 0)
      return new Leaf();
    return new Interior();
  }

  static Node *cloneNode(const Node *node, unsigned level) {
    if (level == 0)
      return new Leaf(*static_cast<const Leaf *>(node));
    return new Interior(*static_cast<const Interior *>(node));
  }

  /// Drop one reference to \p node, freeing it and releasing its children if
  /// that was the last one.
  static void release(Node *node, unsigned level) {
    if (!node || --node->refCount != 0)
      return;
    if (level == 0) {
      delete static_cast<Leaf *>(node);
      return;
    }
    auto *interior = static_cast<Interior *>(node);
    for (Node *child : interior->children)
      release(child, level - 1);
    delete interior;
  }

  const unsigned *findSlot(unsigned key) const {
    if (!root || !fitsInHeight(key, height))
      return nullptr;
    const Node *node = root;
    for (unsigned level = height; level > 0; --level) {
      node = static_cast<const Interior *>(node)->children[indexAt(key, level)];
      if (!node)
        return nullptr;
    }
    const unsigned *slot =
        &static_cast<const Leaf *>(node)->values[key & LevelMask];
    return *slot == Absent ? nullptr : slot;
  }

  /// Return the slot of \p key, creating the nodes leading to it and copying
  /// those shared with other maps, so that writing the slot only affects this
  /// map.
  unsigned &getMutableSlot(unsigned key) {
    if (!root) {
      height = 0;
      while (!fitsInHeight(key, height))
        ++height;
      root = createNode(height);
    }
    while (!fitsInHeight(key, height)) {
      // The old root, and its reference, moves under the new root.
      auto *newRoot = new Interior();
      newRoot->children[0] = root;
      root = newRoot;
      ++height;
    }

    // Every node above the one *ref points at is owned by this map alone, so
    // a node that is only referenced once can be written in place.
    Node **ref = &root;
    for (unsigned level = height;; --level) {
      Node *node = *ref;
      if (!node) {
        node = createNode(level);
        *ref = node;
      } else if (node->refCount > 1) {
        Node *copy = cloneNode(node, level);
        --node->refCount;
        *ref = copy;
        node = copy;
      }
      if (level == 0)
        return static_cast<Leaf *>(node)->values[key & LevelMask];
      ref = &static_cast<Interior *>(node)->children[indexAt(key, level)];
    }
  }

  /// Apply \p fn to the entries below \p node. Returns \p node if it could be
  /// updated in place (or nothing changed), and otherwise a new node holding
  /// the updated entries that the caller must store in place of \p node.
  ///
  /// \p mayMutateInPlace is true if every node above \p node is owned by this
  /// map alone.
  template <typename Fn>
  static Node *updateNode(Node *node, unsigned level, uint64_t base,
                          bool mayMutateInPlace, Fn &fn) {
    bool isUnique = mayMutateInPlace && node->refCount == 1;
    Node *result = node;

    if (level == 0) {
      auto *leaf = static_cast<Leaf *>(node);
      for (unsigned i = 0; i < Fanout; ++i) {
        unsigned oldValue = leaf->values[i];
        if (oldValue == Absent)
          continue;
        unsigned newValue =
            unsigned(fn(KeyT(unsigned(base + i)), ValueT(oldValue)));
        assert(newValue != Absent && "~0U is reserved for missing entries");
        if (newValue == oldValue)
          continue;
        if (result == node && !isUnique)
          result = cloneNode(node, 0);
        static_cast<Leaf *>(result)->values[i] = newValue;
      }
      return result;
    }

    auto *interior = static_cast<Interior *>(node);
    uint64_t span = spanOfLevel(level);
    for (unsigned i = 0; i < Fanout; ++i) {
      // Children past i are the same in node and in a copy made for an
      // earlier child, so reading them from node is fine.
      Node *child = interior->children[i];
      if (!child)
        continue;
      Node *newChild =
          updateNode(child, level - 1, base + i * span, isUnique, fn);
      if (newChild == child)
        continue;
      if (result == node && !isUnique)
        result = cloneNode(node, level);
      auto *target = static_cast<Interior *>(result);
      release(target->children[i], level - 1);
      target->children[i] = newChild;
    }
    return result;
  }

  static bool isEmptyNode(const Node *node, unsigned level) {
    if (!node)
      return true;
    if (level == 0) {
      auto *leaf = static_cast<const Leaf *>(node);
      return std::all_of(std::begin(leaf->values), std::end(leaf->values),
                         [](unsigned value) { return value == Absent; });
    }
    auto *interior = static_cast<const Interior *>(node);
    return std::all_of(
        std::begin(interior->children), std::end(interior->children),
        [&](const Node *child) { return isEmptyNode(child, level - 1); });
  }

  static bool equalNodes(const Node *lhs, const Node *rhs, unsigned level) {
    if (lhs == rhs)
      return true;
    if (!lhs)
      return isEmptyNode(rhs, level);
    if (!rhs)
      return isEmptyNode(lhs, level);
    if (level == 0) {
      auto *lhsLeaf = static_cast<const Leaf *>(lhs);
      auto *rhsLeaf = static_cast<const Leaf *>(rhs);
      return std::equal(std::begin(lhsLeaf->values), std::end(lhsLeaf->values),
                        std::begin(rhsLeaf->values));
    }
    auto *lhsInterior = static_cast<const Interior *>(lhs);
    auto *rhsInterior = static_cast<const Interior *>(rhs);
    for (unsigned i = 0; i < Fanout; ++i)
      if (!equalNodes(lhsInterior->children[i], rhsInterior->children[i],
                      level - 1))
        return false;
    return true;
  }

  /// Return an iterator to the entry with the smallest key that is at least
  /// \p from.
  const_iterator findFirstAtOrAfter(uint64_t from) const {
    const Leaf *leaf = nullptr;
    unsigned key = 0;
    if (root && findFirst(root, height, 0, from, leaf, key))
      return const_iterator(this, leaf, key);
    return end();
  }

  static bool findFirst(const Node *node, unsigned level, uint64_t base,
                        uint64_t from, const Leaf *&foundLeaf,
                        unsigned &foundKey) {
    if (level == 0) {
      auto *leaf = static_cast<const Leaf *>(node);
      for (uint64_t i = from > base ? from - base : 0; i < Fanout; ++i) {
        if (leaf->values[i] != Absent) {
          foundLeaf = leaf;
          foundKey = unsigned(base + i);
          return true;
        }
      }
      return false;
    }
    auto *interior = static_cast<const Interior *>(node);
    uint64_t span = spanOfLevel(level);
    for (uint64_t i = from > base ? (from - base) / span : 0; i < Fanout; ++i) {
      if (const Node *child = interior->children[i])
        if (findFirst(child, level - 1, base + i * span, from, foundLeaf,
                      foundKey))
          return true;
    }
    return false;
  }

  static bool findLast(const Node *node, unsigned level, uint64_t base,
                       unsigned &foundKey) {
    if (level == 0) {
      auto *leaf = static_cast<const Leaf *>(node);
      for (unsigned i = Fanout; i-- > 0;) {
        if (leaf->values[i] != Absent) {
          foundKey = unsigned(base + i);
          return true;
        }
      }
      return false;
    }
    auto *interior = static_cast<const Interior *>(node);
    uint64_t span = spanOfLevel(level);
    for (unsigned i = Fanout; i-- > 0;) {
      if (const Node *child = interior->children[i])
        if (findLast(child, level - 1, base + i * span, foundKey))
          return true;
    }
    return false;
  }
};

} // namespace swift

#endif
