// RUN: %swift -typecheck %s -verify -target wasm32-unknown-wasip1 -disable-objc-interop -parse-stdlib -platform-condition-os macOS -D WASM_AS_MACOS -verify-additional-prefix wasm-as-macos-
// RUN: %swift -typecheck %s -verify -target wasm32-unknown-wasip1 -disable-objc-interop -parse-stdlib -D WASM -verify-additional-prefix wasm-
// RUN: %swift -typecheck %s -verify -target arm64-apple-macosx14 -parse-stdlib -platform-condition-os Linux -D MACOS_AS_LINUX -verify-additional-prefix macos-as-linux-
// RUN: not %swift -typecheck %s -target wasm32-unknown-wasip1 -disable-objc-interop -parse-stdlib -platform-condition-os Darwin 2>&1 | %FileCheck %s -check-prefix=UNKNOWN

// UNKNOWN: error: unsupported operating system 'Darwin' in '-platform-condition-os'

// -platform-condition-os replaces only the os() condition; everything else
// still follows the target triple.

#if WASM_AS_MACOS
#if os(macOS) && os(OSX)
#warning("os is macOS") // expected-wasm-as-macos-warning {{os is macOS}}
#endif
#if os(WASI) || os(Linux) || os(iOS)
#error("os() must only match the override")
#endif
#if canImport(Darwin)
#error("canImport() must follow the target")
#endif
#if arch(wasm32) && !targetEnvironment(simulator) && _pointerBitWidth(_32) && _endian(little) && _runtime(_Native) && _hasAtomicBitWidth(_32)
#warning("target conditions are wasm32") // expected-wasm-as-macos-warning {{target conditions are wasm32}}
#endif
#endif

#if WASM
#if os(WASI)
#warning("os is WASI") // expected-wasm-warning {{os is WASI}}
#endif
#if os(macOS)
#error("os(macOS) must be false without the override")
#endif
#endif

#if MACOS_AS_LINUX
#if os(Linux)
#warning("os is Linux") // expected-macos-as-linux-warning {{os is Linux}}
#endif
#if os(macOS) || os(OSX)
#error("os(macOS) must be false with the override")
#endif
#if arch(arm64) && _pointerBitWidth(_64)
#warning("arch is arm64") // expected-macos-as-linux-warning {{arch is arm64}}
#endif
#endif
