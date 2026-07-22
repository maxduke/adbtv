# Reuse a page-scoped connection for Remote

Remote originally opened and closed an ADB connection for every TV Remote Action, which made controls unavailable between taps and made repeated input inherit connection latency. Remote will instead own a bounded Remote Session that reuses one checked connection, serializes input, and closes when the user leaves Remote or backgrounds the app; other features retain operation-scoped connections.

## Consequences

Rapid one-shot actions require a small bounded buffer, while held repeats remain unbuffered. An uncertain transport failure is never retried because the TV may already have applied the action; pending input is discarded and the session attempts one reconnect before falling back to manual retry.
