/* First-party compatibility shim, not part of the WebView2 SDK package:
 * WebView2.h includes "EventToken.h" for this one struct, and the
 * mingw-w64 headers zig ships do not carry that file. The layout is the
 * OS ABI's event-registration cookie — a single 64-bit value. */
#ifndef __EVENTTOKEN_H__
#define __EVENTTOKEN_H__

typedef struct EventRegistrationToken {
    __int64 value;
} EventRegistrationToken;

#endif
