//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftAsyncDNSResolver open source project
//
// Copyright (c) 2020-2024 Apple Inc. and the SwiftAsyncDNSResolver project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftAsyncDNSResolver project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import CAsyncDNSResolver
import Foundation

#if os(Windows)
// On Windows `ares_socket_t` is `SOCKET` and `ARES_SOCKET_BAD` is defined as
// `INVALID_SOCKET`, a cast-expression macro that the Swift C importer cannot
// surface. Recreate it here: `INVALID_SOCKET` is `(SOCKET)(~0)`.
private let ARES_SOCKET_BAD = ~(ares_socket_t(0))
#endif

/// ``DNSResolver`` implementation backed by c-ares C library.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public final class CAresDNSResolver: DNSResolver, Sendable {
    let options: Options
    let ares: Ares

    /// Initialize a `CAresDNSResolver` with the given options.
    ///
    /// - Parameters:
    ///   - options: ``CAresDNSResolver/Options`` to create resolver with.
    public init(options: Options) throws {
        self.options = options
        self.ares = try Ares(options: options.aresOptions)
    }

    /// Initialize a `CAresDNSResolver` using default options.
    public convenience init() throws {
        try self.init(options: .default)
    }

    /// See ``DNSResolver/queryA(name:)``.
    public func queryA(name: String) async throws -> [ARecord] {
        try await self.ares.query(type: .A, name: name, replyParser: Ares.AQueryReplyParser.instance)
    }

    /// See ``DNSResolver/queryAAAA(name:)``.
    public func queryAAAA(name: String) async throws -> [AAAARecord] {
        try await self.ares.query(type: .AAAA, name: name, replyParser: Ares.AAAAQueryReplyParser.instance)
    }

    /// See ``DNSResolver/queryNS(name:)``.
    public func queryNS(name: String) async throws -> NSRecord {
        try await self.ares.query(type: .NS, name: name, replyParser: Ares.NSQueryReplyParser.instance)
    }

    /// See ``DNSResolver/queryCNAME(name:)``.
    public func queryCNAME(name: String) async throws -> String? {
        try await self.ares.query(type: .CNAME, name: name, replyParser: Ares.CNAMEQueryReplyParser.instance)
    }

    /// See ``DNSResolver/querySOA(name:)``.
    public func querySOA(name: String) async throws -> SOARecord? {
        try await self.ares.query(type: .SOA, name: name, replyParser: Ares.SOAQueryReplyParser.instance)
    }

    /// See ``DNSResolver/queryPTR(name:)``.
    public func queryPTR(name: String) async throws -> PTRRecord {
        try await self.ares.query(type: .PTR, name: name, replyParser: Ares.PTRQueryReplyParser.instance)
    }

    /// See ``DNSResolver/queryMX(name:)``.
    public func queryMX(name: String) async throws -> [MXRecord] {
        try await self.ares.query(type: .MX, name: name, replyParser: Ares.MXQueryReplyParser.instance)
    }

    /// See ``DNSResolver/queryTXT(name:)``.
    public func queryTXT(name: String) async throws -> [TXTRecord] {
        try await self.ares.query(type: .TXT, name: name, replyParser: Ares.TXTQueryReplyParser.instance)
    }

    /// See ``DNSResolver/querySRV(name:)``.
    public func querySRV(name: String) async throws -> [SRVRecord] {
        try await self.ares.query(type: .SRV, name: name, replyParser: Ares.SRVQueryReplyParser.instance)
    }

    /// Lookup NAPTR records associated with `name`.
    ///
    /// - Parameters:
    ///   - name: The name to resolve.
    ///
    /// - Returns: ``NAPTRRecord``s for the given name.
    public func queryNAPTR(name: String) async throws -> [NAPTRRecord] {
        try await self.ares.query(type: .NAPTR, name: name, replyParser: Ares.NAPTRQueryReplyParser.instance)
    }
}

extension QueryType {
    /// The c-ares DNS record type for this query.
    fileprivate var aresRecType: ares_dns_rec_type_t {
        switch self {
        case .A:
            return ARES_REC_TYPE_A
        case .NS:
            return ARES_REC_TYPE_NS
        case .CNAME:
            return ARES_REC_TYPE_CNAME
        case .SOA:
            return ARES_REC_TYPE_SOA
        case .PTR:
            return ARES_REC_TYPE_PTR
        case .MX:
            return ARES_REC_TYPE_MX
        case .TXT:
            return ARES_REC_TYPE_TXT
        case .AAAA:
            return ARES_REC_TYPE_AAAA
        case .SRV:
            return ARES_REC_TYPE_SRV
        case .NAPTR:
            return ARES_REC_TYPE_NAPTR
        }
    }
}

// MARK: - c-ares query wrapper

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class Ares: Sendable {
    typealias QueryCallback =
        @convention(c) (
            UnsafeMutableRawPointer?, ares_status_t, size_t, OpaquePointer?
        ) -> Void

    private let channel: AresChannel
    private let queryProcessor: QueryProcessor

    init(options: AresOptions) throws {
        // `AresChannel` owns the socket registry and wires the c-ares `sock_state_cb`.
        let channel = try AresChannel(options: options)
        self.channel = channel

        // Need to call `ares_process_fd` for query callbacks to happen
        self.queryProcessor = QueryProcessor(channel: channel)
        self.queryProcessor.start()
    }

    func query<ReplyParser: AresQueryReplyParser>(
        type: QueryType,
        name: String,
        replyParser: ReplyParser
    ) async throws -> ReplyParser.Reply {
        let channel = self.channel
        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<ReplyParser.Reply, Error>) in
                    let handler = QueryReplyHandler(parser: replyParser, continuation)

                    // Wrap `handler` into a pointer so we can pass it to callback. The pointer will be deallocated in there later.
                    let handlerPointer = UnsafeMutableRawPointer.allocate(
                        byteCount: MemoryLayout<QueryReplyHandler>.stride,
                        alignment: MemoryLayout<QueryReplyHandler>.alignment
                    )
                    handlerPointer.initializeMemory(as: QueryReplyHandler.self, repeating: handler, count: 1)

                    let queryCallback: QueryCallback = { arg, status, _, dnsrec in
                        guard let handlerPointer = arg else {
                            preconditionFailure("'arg' is nil. This is a bug.")
                        }

                        let pointer = handlerPointer.assumingMemoryBound(to: QueryReplyHandler.self)
                        let handler = pointer.pointee
                        defer {
                            pointer.deinitialize(count: 1)
                            pointer.deallocate()
                        }

                        handler.handle(status: status, dnsrec: dnsrec)
                    }

                    self.channel.withChannel { channel in
                        var qid: CUnsignedShort = 0
                        let status = ares_query_dnsrec(
                            channel,
                            name,
                            ARES_CLASS_IN,
                            type.aresRecType,
                            queryCallback,
                            handlerPointer,
                            &qid
                        )
                        // Unlike the deprecated `ares_query`, `ares_query_dnsrec` reports a
                        // synchronous status. On failure the callback will not fire, so free
                        // the handler here and fail the continuation to avoid a leak/hang.
                        if status != ARES_SUCCESS {
                            let pointer = handlerPointer.assumingMemoryBound(to: QueryReplyHandler.self)
                            pointer.deinitialize(count: 1)
                            pointer.deallocate()
                            continuation.resume(throwing: AsyncDNSResolver.Error(cAresCode: CInt(status.rawValue)))
                        }
                    }
                }
            },
            onCancel: {
                channel.withChannel { channel in
                    ares_cancel(channel)
                }
            }
        )
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension Ares {
    // TODO: implement this more nicely using NIO EventLoop?
    // See:
    // https://github.com/dimbleby/c-ares-resolver/blob/master/src/unix/eventloop.rs  // ignore-unacceptable-language
    // https://github.com/dimbleby/rust-c-ares/blob/master/src/channel.rs  // ignore-unacceptable-language
    // https://github.com/dimbleby/rust-c-ares/blob/master/examples/event-loop.rs  // ignore-unacceptable-language
    final class QueryProcessor: @unchecked Sendable {
        static let defaultPollInterval: UInt64 = 10 * 1_000_000  // 10ms

        private let channel: AresChannel
        private let pollIntervalNanos: UInt64

        private let lock = NSLock()
        private var locked_pollingTask: Task<Void, Error>?

        deinit {
            // No need to lock here as there can exist no more strong references to self.
            self.locked_pollingTask?.cancel()
        }

        init(
            channel: AresChannel,
            pollIntervalNanos: UInt64 = QueryProcessor.defaultPollInterval
        ) {
            self.channel = channel
            self.pollIntervalNanos = pollIntervalNanos
        }

        /// Drives c-ares by calling `ares_process_fd` for each socket it is currently
        /// waiting on. The set of sockets (and their read/write interest) is maintained
        /// by the `sock_state_cb` in ``SocketRegistry`` rather than the deprecated
        /// `ares_getsock`.
        func poll() {
            let sockets = self.channel.socketRegistry.snapshot()

            if !sockets.isEmpty {
                self.channel.withChannel { channel in
                    for entry in sockets {
                        // `ARES_SOCKET_BAD` instructs c-ares not to perform the action
                        let readFD = entry.readable ? entry.socket : ARES_SOCKET_BAD
                        let writeFD = entry.writable ? entry.socket : ARES_SOCKET_BAD
                        ares_process_fd(channel, readFD, writeFD)
                    }
                }
            }

            // Schedule next poll
            self.schedule()
        }

        func start() {
            self.schedule()
        }

        private func schedule() {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.locked_pollingTask = Task { [weak self] in
                guard let s = self else {
                    return
                }
                try await Task.sleep(nanoseconds: s.pollIntervalNanos)
                s.poll()
            }
        }
    }
}

// MARK: - c-ares query reply handler

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension Ares {
    class QueryReplyHandler {
        private let _handler: (ares_status_t, OpaquePointer?) -> Void

        init<Parser: AresQueryReplyParser>(parser: Parser, _ continuation: CheckedContinuation<Parser.Reply, Error>) {
            self._handler = { status, dnsrec in
                guard status == ARES_SUCCESS || status == ARES_ENODATA else {
                    return continuation.resume(throwing: AsyncDNSResolver.Error(cAresCode: CInt(status.rawValue)))
                }

                do {
                    let reply = try parser.parse(dnsrec)
                    continuation.resume(returning: reply)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        func handle(status: ares_status_t, dnsrec: OpaquePointer?) {
            self._handler(status, dnsrec)
        }
    }
}

// MARK: - c-ares query reply parsers

protocol AresQueryReplyParser {
    associatedtype Reply: Sendable

    /// Parse a reply from the (already parsed) DNS record c-ares delivers to the
    /// query callback. The `dnsrec` pointer (`const ares_dns_record_t *`) is owned
    /// by c-ares and is only valid for the duration of the call.
    func parse(_ dnsrec: OpaquePointer?) throws -> Reply
}

/// Returns the answer-section resource records of the given type from `dnsrec`.
/// The returned `ares_dns_rr_t` pointers are owned by c-ares and only valid while
/// `dnsrec` is (i.e. for the duration of the callback).
private func answerRecords(_ dnsrec: OpaquePointer?, ofType type: ares_dns_rec_type_t) -> [OpaquePointer] {
    guard let dnsrec = dnsrec else { return [] }
    let count = ares_dns_record_rr_cnt(dnsrec, ARES_SECTION_ANSWER)
    var records = [OpaquePointer]()
    for index in 0..<count {
        guard let rr = ares_dns_record_rr_get_const(dnsrec, ARES_SECTION_ANSWER, index) else { continue }
        // The answer section can contain other record types (e.g. CNAMEs); the old
        // `ares_parse_*_reply` filtered internally, so we must filter here.
        if ares_dns_rr_get_type(rr) == type {
            records.append(rr)
        }
    }
    return records
}

private func string(_ rr: OpaquePointer, _ key: ares_dns_rr_key_t) -> String? {
    ares_dns_rr_get_str(rr, key).map { String(cString: $0) }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension Ares {
    struct AQueryReplyParser: AresQueryReplyParser {
        static let instance = AQueryReplyParser()

        func parse(_ dnsrec: OpaquePointer?) throws -> [ARecord] {
            answerRecords(dnsrec, ofType: ARES_REC_TYPE_A).compactMap { rr in
                guard let addr = ares_dns_rr_get_addr(rr, ARES_RR_A_ADDR) else { return nil }
                return ARecord(
                    address: IPAddress.IPv4(addr.pointee),
                    ttl: Int32(truncatingIfNeeded: ares_dns_rr_get_ttl(rr))
                )
            }
        }
    }

    struct AAAAQueryReplyParser: AresQueryReplyParser {
        static let instance = AAAAQueryReplyParser()

        func parse(_ dnsrec: OpaquePointer?) throws -> [AAAARecord] {
            answerRecords(dnsrec, ofType: ARES_REC_TYPE_AAAA).compactMap { rr in
                guard let addr = ares_dns_rr_get_addr6(rr, ARES_RR_AAAA_ADDR) else { return nil }
                return AAAARecord(
                    address: IPAddress.IPv6(addr.pointee),
                    ttl: Int32(truncatingIfNeeded: ares_dns_rr_get_ttl(rr))
                )
            }
        }
    }

    struct NSQueryReplyParser: AresQueryReplyParser {
        static let instance = NSQueryReplyParser()

        func parse(_ dnsrec: OpaquePointer?) throws -> NSRecord {
            let nameservers = answerRecords(dnsrec, ofType: ARES_REC_TYPE_NS).compactMap {
                string($0, ARES_RR_NS_NSDNAME)
            }
            return NSRecord(nameservers: nameservers)
        }
    }

    struct CNAMEQueryReplyParser: AresQueryReplyParser {
        static let instance = CNAMEQueryReplyParser()

        func parse(_ dnsrec: OpaquePointer?) throws -> String? {
            answerRecords(dnsrec, ofType: ARES_REC_TYPE_CNAME).lazy.compactMap {
                string($0, ARES_RR_CNAME_CNAME)
            }.first
        }
    }

    struct SOAQueryReplyParser: AresQueryReplyParser {
        static let instance = SOAQueryReplyParser()

        func parse(_ dnsrec: OpaquePointer?) throws -> SOARecord? {
            guard let rr = answerRecords(dnsrec, ofType: ARES_REC_TYPE_SOA).first else {
                return nil
            }
            return SOARecord(
                mname: string(rr, ARES_RR_SOA_MNAME),
                rname: string(rr, ARES_RR_SOA_RNAME),
                serial: ares_dns_rr_get_u32(rr, ARES_RR_SOA_SERIAL),
                refresh: ares_dns_rr_get_u32(rr, ARES_RR_SOA_REFRESH),
                retry: ares_dns_rr_get_u32(rr, ARES_RR_SOA_RETRY),
                expire: ares_dns_rr_get_u32(rr, ARES_RR_SOA_EXPIRE),
                ttl: ares_dns_rr_get_u32(rr, ARES_RR_SOA_MINIMUM)
            )
        }
    }

    struct PTRQueryReplyParser: AresQueryReplyParser {
        static let instance = PTRQueryReplyParser()

        func parse(_ dnsrec: OpaquePointer?) throws -> PTRRecord {
            let names = answerRecords(dnsrec, ofType: ARES_REC_TYPE_PTR).compactMap {
                string($0, ARES_RR_PTR_DNAME)
            }
            return PTRRecord(names: names)
        }
    }

    struct MXQueryReplyParser: AresQueryReplyParser {
        static let instance = MXQueryReplyParser()

        func parse(_ dnsrec: OpaquePointer?) throws -> [MXRecord] {
            answerRecords(dnsrec, ofType: ARES_REC_TYPE_MX).compactMap { rr in
                guard let host = string(rr, ARES_RR_MX_EXCHANGE) else { return nil }
                return MXRecord(host: host, priority: ares_dns_rr_get_u16(rr, ARES_RR_MX_PREFERENCE))
            }
        }
    }

    struct TXTQueryReplyParser: AresQueryReplyParser {
        static let instance = TXTQueryReplyParser()

        func parse(_ dnsrec: OpaquePointer?) throws -> [TXTRecord] {
            var records = [TXTRecord]()
            for rr in answerRecords(dnsrec, ofType: ARES_REC_TYPE_TXT) {
                // TXT data is an array of binary strings; emit one record per segment.
                let segments = ares_dns_rr_get_abin_cnt(rr, ARES_RR_TXT_DATA)
                for index in 0..<segments {
                    var length: size_t = 0
                    guard let bytes = ares_dns_rr_get_abin(rr, ARES_RR_TXT_DATA, index, &length) else { continue }
                    let txt = String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
                    records.append(TXTRecord(txt: txt))
                }
            }
            return records
        }
    }

    struct SRVQueryReplyParser: AresQueryReplyParser {
        static let instance = SRVQueryReplyParser()

        func parse(_ dnsrec: OpaquePointer?) throws -> [SRVRecord] {
            answerRecords(dnsrec, ofType: ARES_REC_TYPE_SRV).compactMap { rr in
                guard let host = string(rr, ARES_RR_SRV_TARGET) else { return nil }
                return SRVRecord(
                    host: host,
                    port: ares_dns_rr_get_u16(rr, ARES_RR_SRV_PORT),
                    weight: ares_dns_rr_get_u16(rr, ARES_RR_SRV_WEIGHT),
                    priority: ares_dns_rr_get_u16(rr, ARES_RR_SRV_PRIORITY)
                )
            }
        }
    }

    struct NAPTRQueryReplyParser: AresQueryReplyParser {
        static let instance = NAPTRQueryReplyParser()

        func parse(_ dnsrec: OpaquePointer?) throws -> [NAPTRRecord] {
            answerRecords(dnsrec, ofType: ARES_REC_TYPE_NAPTR).map { rr in
                NAPTRRecord(
                    flags: string(rr, ARES_RR_NAPTR_FLAGS),
                    service: string(rr, ARES_RR_NAPTR_SERVICES),
                    regExp: string(rr, ARES_RR_NAPTR_REGEXP),
                    replacement: string(rr, ARES_RR_NAPTR_REPLACEMENT) ?? "",
                    order: ares_dns_rr_get_u16(rr, ARES_RR_NAPTR_ORDER),
                    preference: ares_dns_rr_get_u16(rr, ARES_RR_NAPTR_PREFERENCE)
                )
            }
        }
    }
}

// MARK: - helpers

extension IPAddress.IPv4 {
    init(_ address: in_addr) {
        var address = address
        let addressString = sys_inet_ntop(family: AF_INET, bytes: &address, length: Int(INET_ADDRSTRLEN)) ?? ""
        self = IPAddress.IPv4(address: addressString)
    }
}

extension IPAddress.IPv6 {
    init(_ address: ares_in6_addr) {
        var address = address
        let addressString = sys_inet_ntop(family: AF_INET6, bytes: &address, length: Int(INET6_ADDRSTRLEN)) ?? ""
        self = IPAddress.IPv6(address: addressString)
    }
}

func sys_inet_ntop(family: CInt, bytes: UnsafeRawPointer, length: Int) -> String? {
    var addressBytes: [Int8] = Array(repeating: 0, count: length)
    return addressBytes.withUnsafeMutableBufferPointer { addressBytesPtr -> String? in
        // The returned pointer is the same as addressBytesPtr.baseAddress but nil on error.
        #if os(Windows)
        // On Windows `inet_ntop`'s size argument is `size_t` (imported as `Int`).
        if inet_ntop(family, bytes, addressBytesPtr.baseAddress, length) == nil {
            return nil
        }
        #else
        if inet_ntop(family, bytes, addressBytesPtr.baseAddress, socklen_t(length)) == nil {
            return nil
        }
        #endif

        return addressBytesPtr.baseAddress!.withMemoryRebound(
            to: UInt8.self,
            capacity: addressBytesPtr.count
        ) {
            String(cString: $0)
        }
    }
}
