// RUN: %target-run-simple-swift(-target %target-swift-6.0-abi-triple -parse-as-library) | %FileCheck %s
// RUN: %target-run-simple-swift(-target %target-swift-6.0-abi-triple -parse-as-library -O) | %FileCheck %s

// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: concurrency_runtime
// UNSUPPORTED: back_deployment_runtime

// A closure literal with a typed throws clause whose contextual type is
// fully opaque (a generic `T`, an array element) must throw its error through
// the indirect error result of the most general function type.

enum EnumError: Error { case a, b, c }

struct StructError: Error {
  var message: String
  var codes: [Int]
}

final class ClassError: Error {
  let id: Int
  init(id: Int) { self.id = id }
}

func describe(_ error: EnumError) -> String {
  switch error {
  case .a: return "a"
  case .b: return "b"
  case .c: return "c"
  }
}

func id<T>(_ x: T) -> T { x }
func idOptional<T>(_ x: T?) -> T? { x }
func idAsync<T>(_ x: T) async -> T { x }
func idPack<each T>(_ x: repeat each T) -> (repeat each T) { (repeat each x) }

protocol P {
  associatedtype A
  func take(_ a: A) -> String
}

struct S: P {
  func take(_ a: () throws(EnumError) -> Int) -> String {
    do {
      return "returned \(try a())"
    } catch {
      return "caught \(describe(error))"
    }
  }
}

func take<X: P>(_ x: X, _ a: X.A) -> String { x.take(a) }

func callUntyped<T>(_ op: () throws -> T) -> String {
  do {
    return "returned \(try op())"
  } catch let error as EnumError {
    return "caught \(describe(error))"
  } catch {
    return "caught unexpected error"
  }
}

func thrower(_ error: EnumError) throws(EnumError) -> Int { throw error }

// Cast a value of generic type back to the typed throws function type.
func callAfterCast<T>(_ x: T) -> String {
  let fn = x as! () throws(EnumError) -> Int
  do {
    return "returned \(try fn())"
  } catch {
    return "caught \(describe(error))"
  }
}

func genericContext<U>(_: U.Type) -> String {
  let fn = id({ () throws(EnumError) -> U in throw .b })
  do {
    _ = try fn()
    return "returned"
  } catch {
    return "caught \(describe(error))"
  }
}

func capture(_ error: EnumError, _ limit: Int) -> (Int) throws(EnumError) -> Int {
  id({ (x: Int) throws(EnumError) -> Int in
    if x > limit { throw error }
    return limit
  })
}

func genericError<E: Error>(_ error: E) -> String {
  let fn = id({ () throws(E) -> Int in throw error })
  do {
    return "returned \(try fn())"
  } catch {
    return "caught \((error as? ClassError)?.id ?? -1)"
  }
}

@main struct Main {
  static func main() async {
    let fn = id({ () throws(EnumError) -> Int in throw .a })
    // CHECK: generic: caught a
    print("generic:", callUntyped(fn))
    do {
      _ = try fn()
      print("direct: returned")
    } catch {
      // CHECK-NEXT: direct: caught a
      print("direct: caught \(describe(error))")
    }

    // CHECK-NEXT: return: returned 42
    print("return:", callUntyped(id({ () throws(EnumError) -> Int in 42 })))

    let withParam = id({ (x: Int) throws(EnumError) -> Int in
      if x > 0 { return try thrower(.c) }
      return x
    })
    // CHECK-NEXT: parameter: caught c
    print("parameter:", callUntyped { try withParam(1) })
    // CHECK-NEXT: parameter: returned -3
    print("parameter:", callUntyped { try withParam(-3) })

    // CHECK-NEXT: cast: caught b
    print("cast:", callAfterCast({ () throws(EnumError) -> Int in throw .b }))

    let captured = capture(.c, 5)
    // CHECK-NEXT: capture: caught c
    print("capture:", callUntyped { try captured(10) })
    // CHECK-NEXT: capture: returned 5
    print("capture:", callUntyped { try captured(1) })

    // CHECK-NEXT: generic context: caught b
    print("generic context:", genericContext(String.self))

    let pack = idPack(1, { () throws(EnumError) -> Int in throw .a }, "x")
    // CHECK-NEXT: pack: caught a
    print("pack:", callUntyped(pack.1))

    // CHECK-NEXT: associated type: caught c
    print("associated type:", take(S(), { () throws(EnumError) -> Int in throw .c }))
    // CHECK-NEXT: associated type: returned 9
    print("associated type:", take(S(), { () throws(EnumError) -> Int in 9 }))

    let array: [() throws(StructError) -> Int] = [
      { () throws(StructError) -> Int in
        throw StructError(message: "first", codes: [1, 2]) },
      { () throws(StructError) -> Int in 7 },
      { () throws(StructError) -> Int in
        throw StructError(message: "third", codes: [3]) },
    ]
    var results: [String] = []
    for _ in 0..<100 {
      results = []
      for element in array {
        do {
          results.append("returned \(try element())")
        } catch {
          results.append("caught \(error.message) \(error.codes)")
        }
      }
    }
    // CHECK-NEXT: array: caught first [1, 2], returned 7, caught third [3]
    print("array:", results.joined(separator: ", "))

    let classError = ClassError(id: 5)
    let classFn = id({ () throws(ClassError) -> Int in throw classError })
    do {
      _ = try classFn()
      print("class: returned")
    } catch {
      // CHECK-NEXT: class: caught 5 true
      print("class: caught \(error.id) \(error === classError)")
    }

    let optionalFn = idOptional({ () throws(EnumError) -> Int in throw .c })!
    do {
      _ = try optionalFn()
      print("optional: returned")
    } catch {
      // CHECK-NEXT: optional: caught c
      print("optional: caught \(describe(error))")
    }

    // CHECK-NEXT: generic error: caught 9
    print("generic error:", genericError(ClassError(id: 9)))

    let asyncFn = await idAsync({ () async throws(StructError) -> Int in
      throw StructError(message: "async", codes: [4])
    })
    do {
      _ = try await asyncFn()
      print("async: returned")
    } catch {
      // CHECK-NEXT: async: caught async [4]
      print("async: caught \(error.message) \(error.codes)")
    }
  }
}
