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

extension ares_status_t {
    /// Bridge a c-ares `CInt` status code to the strongly-typed `ares_status_t`
    /// enum. As of c-ares 1.20+ the `ARES_*` status constants are members of the
    /// `ares_status_t` enum, while the legacy parse and init APIs still return `int`.
    init(_ status: Int32) {
        self.init(rawValue: ares_status_t.RawValue(status))
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension AsyncDNSResolver.Error {
    /// Create an ``AsyncDNSResolver/AsyncDNSResolver/Error`` from c-ares error code.
    init(cAresCode: Int32, _ description: String = "") {
        self.message = description
        self.source = CAresError(code: Int(cAresCode))

        switch ares_status_t(cAresCode) {
        case ARES_EFORMERR, ARES_EBADQUERY, ARES_EBADNAME, ARES_EBADFAMILY, ARES_EBADFLAGS:
            self.code = .badQuery
        case ARES_EBADRESP:
            self.code = .badResponse
        case ARES_ECONNREFUSED:
            self.code = .connectionRefused
        case ARES_ETIMEOUT:
            self.code = .timeout
        default:
            self.code = .internalError
        }
    }
}
