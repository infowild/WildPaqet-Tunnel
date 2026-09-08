# Local smux patch

Source: https://github.com/xtaci/smux/tree/ab9f0f36cbce9d0f784c86977115f0b059dafc3e
Version: v1.5.53. License: MIT, retained in LICENSE and source headers.

Only mux.go and session.go production files differ from upstream. Config gains
an optional per-probe interval callback and idle-only heartbeat flag. The sender
records successful non-NOP outbound activity; the heartbeat resamples its delay
on each iteration and suppresses redundant NOPs during activity. Receive-side
liveness and wire commands stay unchanged. Both options default off, preserving
legacy direct TLS and KCP behavior. H2 opts in in internal/tnet/tls/config.go.

When updating this snapshot, rebase these two changes and run upstream tests,
heartbeat regression tests and the core H2 integration/large-transfer tests.
