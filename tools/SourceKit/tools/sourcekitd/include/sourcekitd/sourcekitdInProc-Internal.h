//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_SOURCEKITDINPROC_INTERNAL_H
#define LLVM_SOURCEKITDINPROC_INTERNAL_H

#include "sourcekitd/sourcekitd.h"
#include <functional>
#include <string>

namespace sourcekitdInProc {
std::string getRuntimeLibPath();
std::string getSwiftExecutablePath();

/// Hooks for a process that embeds the in-process service, which let it decide
/// how requests reach the service: for example to answer them itself once the
/// service can no longer be used (after a crash in the service that the host
/// recovered from). Every hook is optional.
struct ServiceHooks {
  using ResponseReceiver = std::function<void(sourcekitd_response_t)>;

  /// Called by sourcekitd_send_request and sourcekitd_send_request_sync with
  /// the request, the receiver that takes its response, and \c Send, which
  /// hands the request to the service with the receiver it is given (a
  /// synchronous request is then handled on the thread that calls \c Send).
  /// The hook calls \c Send once, on any thread, or answers the request
  /// itself by calling \c Receiver once.
  void (*SendRequest)(sourcekitd_object_t Request, bool Synchronous,
                      ResponseReceiver Receiver,
                      std::function<void(ResponseReceiver)> Send) = nullptr;

  /// Called by sourcekitd_initialize, sourcekitd_shutdown,
  /// sourcekitd_cancel_request, sourcekitd_request_handle_dispose and
  /// sourcekitd_set_notification_handler, which do nothing if it returns
  /// false.
  bool (*ShouldUseService)() = nullptr;

  /// Called at the end of sourcekitd_initialize, after the service has been
  /// initialized.
  void (*ServiceInitialized)() = nullptr;

  /// Called by the first sourcekitd_initialize. If it returns false, the
  /// service leaves LLVM's fatal error handler alone (it installs one that
  /// prints the reason to stderr and aborts), so that a host that installed
  /// its own keeps it.
  bool (*ShouldInstallFatalErrorHandler)() = nullptr;

  /// Called on the main queue with each notification for the handler of
  /// sourcekitd_set_notification_handler, instead of calling the handler:
  /// \c Deliver calls the handler with the notification. The hook calls
  /// \c Deliver once, on any thread, before it returns or later, so that the
  /// host decides where the handler runs (for example outside its crash
  /// recovery around SourceKit's work items).
  void (*DeliverNotification)(std::function<void()> Deliver) = nullptr;
};

/// Installs \p Hooks. Call it before sourcekitd_initialize.
void setServiceHooks(const ServiceHooks &Hooks);
} // namespace sourcekitdInProc

#endif
