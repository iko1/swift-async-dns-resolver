//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftAsyncDNSResolver open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftAsyncDNSResolver project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftAsyncDNSResolver project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest

@testable import AsyncDNSResolver

/// Cancellation is per-query: cancelling the task awaiting one query resumes only that
/// query's continuation (with `CancellationError`) and never calls `ares_cancel`, so it
/// neither deadlocks against the poll loop nor cancels other in-flight queries sharing
/// the channel.
final class CAresCancellationTests: XCTestCase {
    /// Reserved, non-routable (TEST-NET-1, RFC 5737): queries never get an answer, so
    /// they stay in flight until we cancel them or they time out.
    private static let blackholeServer = "192.0.2.1"

    private func makeResolver(timeoutMillis: Int32 = 5000) throws -> CAresDNSResolver {
        var options = CAresDNSResolver.Options()
        options.servers = [Self.blackholeServer]
        options.timeoutMillis = timeoutMillis
        return try CAresDNSResolver(options: options)
    }

    /// Race-style: repeatedly start an in-flight query and cancel it from another task
    /// while the resolver is polling. Each cancel must settle promptly with
    /// `CancellationError` — a cancel that re-entered the locked resolver state / inverted
    /// with the poll loop would hang and trip the watchdog.
    func test_cancelInFlightQuery_isRaceSafeAndSettlesWithoutDeadlock() async throws {
        let resolver = try self.makeResolver()
        for iteration in 0..<25 {
            let query = Task { try await resolver.queryA(name: "example.com") }

            // Cancel from a SEPARATE task, concurrently with the poll loop — after a
            // small, varied delay so the cancel lands while the query is in flight.
            let canceller = Task {
                try? await Task.sleep(nanoseconds: UInt64(5_000_000 + iteration % 5 * 3_000_000))
                query.cancel()
            }

            let outcome = await Self.result(of: { try await query.value }, within: 5_000_000_000)
            canceller.cancel()
            switch outcome {
            case .none:
                XCTFail("iteration \(iteration): cancelled query did not settle within 5s — likely a deadlock")
                return
            case .some(.success):
                XCTFail("iteration \(iteration): cancelled query unexpectedly succeeded")
                return
            case .some(.failure(let error)):
                XCTAssertTrue(error is CancellationError, "iteration \(iteration): expected CancellationError, got \(error)")
            }
        }
    }

    /// Cancelling one query must NOT cancel a parallel query sharing the same channel.
    /// With the old `ares_cancel(channel)` approach this failed: cancelling A cancelled
    /// every in-flight query on the channel, so B would settle immediately too.
    func test_cancellingOneQueryDoesNotCancelParallelQueryOnSameChannel() async throws {
        let resolver = try self.makeResolver()

        // B records when it finishes, so we can assert it stays in flight without
        // awaiting its value (which isn't a cancellation point).
        let bFinished = AtomicFlag()
        let queryA = Task { try await resolver.queryA(name: "a.example.com") }
        let queryB = Task { () -> [ARecord] in
            defer { bFinished.set() }
            return try await resolver.queryA(name: "b.example.com")
        }

        // Ensure both queries are in flight on the shared channel.
        try await Task.sleep(nanoseconds: 150_000_000)

        // Cancel only A — it must settle with CancellationError.
        queryA.cancel()
        let aOutcome = await Self.result(of: { try await queryA.value }, within: 5_000_000_000)
        if case .some(.failure(let error)) = aOutcome {
            XCTAssertTrue(error is CancellationError, "A should be cancelled, got \(error)")
        } else {
            XCTFail("A did not settle with CancellationError after cancel")
        }

        // Give any (incorrect) cross-query cancellation a chance to land, then assert B
        // is still in flight. On the old ares_cancel(channel) approach B would already
        // have been cancelled here.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(
            bFinished.value,
            "cancelling A also finished B — the cancel leaked across queries on the shared channel"
        )

        // Cleanup: cancel B (settles fast via per-query cancel; no wait on its timeout).
        queryB.cancel()
        _ = try? await queryB.value
    }

    /// Minimal thread-safe boolean flag for test synchronization.
    private final class AtomicFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { self.lock.lock(); self.flag = true; self.lock.unlock() }
        var value: Bool { self.lock.lock(); defer { self.lock.unlock() }; return self.flag }
    }

    #if DEBUG
    /// A cancelled query's deferred c-ares work must be released, not leaked: the caller
    /// is resumed immediately, and once the background request finishes on its own its
    /// per-query handler is deallocated.
    func test_cancelledQueryReleasesResourcesAndDoesNotLeak() async throws {
        // Handlers left draining by earlier tests share this global counter, so first wait
        // for it to quiesce (two consecutive equal reads) to get a stable baseline.
        var baseline = Ares.QueryReplyHandler.liveInstances.current
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let current = Ares.QueryReplyHandler.liveInstances.current
            if current == baseline { break }
            baseline = current
        }

        // Short timeout so the abandoned background request drains quickly.
        let resolver = try self.makeResolver(timeoutMillis: 1000)

        let query = Task { try await resolver.queryA(name: "example.com") }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThan(
            Ares.QueryReplyHandler.liveInstances.current, baseline,
            "handler should be alive while the query is in flight"
        )
        query.cancel()
        _ = try? await query.value  // caller unblocked immediately with CancellationError

        // The c-ares request keeps running in the background; when it completes (bounded by
        // the timeout) its callback releases the handler. Poll until we're back to baseline.
        var released = false
        for _ in 0..<100 {  // up to ~10s
            if Ares.QueryReplyHandler.liveInstances.current <= baseline {
                released = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(released, "cancelled query's handler was never released — deferred work leaked")
    }
    #endif

    /// Runs `operation`, returning its `Result` if it finishes within `nanos`, or `nil`
    /// if a watchdog fires first (i.e. it is still running).
    private static func result<T: Sendable>(
        of operation: @escaping @Sendable () async throws -> T,
        within nanos: UInt64
    ) async -> Result<T, Error>? {
        await withTaskGroup(of: Result<T, Error>?.self) { group in
            group.addTask {
                do { return .success(try await operation()) } catch { return .failure(error) }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: nanos)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
