// RUN: %target-run-simple-swift(-parse-as-library) | %FileCheck %s

// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: concurrency_runtime
// REQUIRES: OS=wasip1

// On WASI the async main entry point installs the main module's
// DefaultExecutorFactory without -disable-availability-checking: the Swift
// runtime always comes from the SDK the program is built against.

@_spi(ExperimentalCustomExecutors) import _Concurrency

struct RecordingExecutorFactory: ExecutorFactory {
  static var mainExecutor: any MainExecutor {
    print("factory: mainExecutor")
    return PlatformExecutorFactory.mainExecutor
  }
  static var defaultExecutor: any TaskExecutor {
    print("factory: defaultExecutor")
    return PlatformExecutorFactory.defaultExecutor
  }
}

typealias DefaultExecutorFactory = RecordingExecutorFactory

@main struct Main {
  static func main() async {
    print("main: start")
    let value = await Task.detached { 42 }.value
    print("main: \(value)")
  }
}

// CHECK: factory: mainExecutor
// CHECK-NEXT: factory: defaultExecutor
// CHECK-NEXT: main: start
// CHECK-NEXT: main: 42
