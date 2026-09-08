# v3.4.1: transport resilience and deployment notes

This update fixes concrete software issues found at base commit
`f29049f79e8a2fc6135dc794cad25c9a7e913e5a`. It does not establish the cause of an
Iran IP block and does not promise DPI invisibility.

## Changes

- Candidate enumeration does not reserve unused half-open endpoints. An atomic
  acquisition occurs just before dial, and cancellation releases the probe.
- User stream setup selects a ready TLS pool slot; it never creates a shared
  HTTP/2 session parented to that user's setup deadline. The existing supervisor
  owns reconnects. Busy slots are skipped so another healthy slot can be used.
- TCP forwarders bound concurrent pending setups and close expired local
  connections. Defaults are 256 pending setups per forwarder and 15 seconds.
  Active relays do not consume pending slots and are not cut off at 15 seconds.
- H2 heartbeats sample their interval on every probe and suppress redundant NOPs
  after non-NOP outbound activity. Receive-side liveness remains enabled.
  A minimal, MIT-licensed smux v1.5.53 snapshot implements this scheduling; see
  `core/third_party/smux/UPSTREAM.md`. The wire protocol is unchanged.
- The shared Welcome page is removed. Without `decoy_url`, ordinary requests
  receive a web-server 404 page. A configured site's routes are preserved;
  backend outages return a 502 page. Unauthenticated CONNECT is rejected with
  405. Since v3.4.2 none of these responses carry Go's default bodies, and all
  of them send a `Server` header - the previous defaults identified the host as
  a bare Go program to any prober.
- `tls.mode` must be explicit. Omitted mode now fails validation before startup
  rather than silently selecting the legacy direct carrier.
- The manager pins source downloads to a resolved Git commit and embeds that
  commit in the binary's version output. The core version is v3.5.0-wildpaqet.

## Before updating servers

1. Preserve the previous binaries and configuration files.
2. Check every managed TLS configuration for an explicit mode. For an old
   direct deployment, add `mode: direct` on both sides to retain its existing
   carrier. Use `mode: h2` only when both peers are configured for the real H2
   carrier, including its SNI and authentication settings. Do not blindly change
   a legacy peer to h2 during an unattended upgrade.
3. Keep `smux_version` identical on both peers. This patch does not require a
   wire migration from the same version of smux. Do not combine v1 and v2.
4. Set `decoy_url` to an actual site backend you operate, e.g.
   `http://127.0.0.1:8080`, for a meaningful web response. The generic 404
   fallback is not a substitute for a real site.
5. Maintain `keepalive_timeout > 2 * (keepalive + keepalive_jitter)`. Existing defaults
   60, 15 and 5 seconds satisfy this. Direct TLS/KCP retain legacy scheduling.
6. Build and roll out to a test pair before updating production. Running the
   public branch installer will not include a local development branch until
   the changes have actually been published there.

Optional TCP-forward setup limits (seconds, per listening forward entry):

```yaml
forward:
  - listen: "0.0.0.0:2083"
    target: "127.0.0.1:2083"
    protocol: "tcp"
    connect_timeout: 15
    max_pending: 256
```

These limits cover setup, not active concurrent users or bandwidth. In a
persistent upstream stall, pending workers remain counted until their transport
operation returns; expired local sockets are closed by the setup timer. A
shared session's internal stream-open timeout may outlive a user setup timer,
so bounded admission remains important.

The standard TCP forwarder does not add TLS to the user-to-Iran leg. Preserve
and independently verify the inbound protocol's own security configuration.
No inbound Xray configuration was available for automatic modification.

## Verification commands

Go compatible with core/go.mod, a C compiler and libpcap development headers
are required for the complete core tests/build.

```bash
cd core
go test -count=1 ./...
go test -race -count=1 ./internal/client ./internal/forward ./internal/tnet/tls
go vet ./...
WILDPAQET_LARGE_TEST=1 go test -count=1 -run '^TestH2LargeTransfer$' -v -timeout 12m ./internal/tnet/tls
cd third_party/smux
go test -count=1 ./...
go test -race -count=1 -run 'TestHeartbeat|TestIdleHeartbeat|TestActiveOutbound'
```

The opt-in large test transfers and verifies 12 GiB in each direction over a
real loopback TLS/H2 connection and a single smux v2 stream with bounded memory.
It exercises byte-counter wrap boundaries but does not emulate Iranian DPI,
packet loss or all production concurrency patterns. The existing H2 roundtrip
regression now explicitly tests smux v2 rather than the upstream v1 default.

A local run of the large test passed: 12,884,901,888 bytes each direction,
24 GiB combined, in approximately 43 seconds. Record separate field evidence
for any claim about blocking resistance: timestamps, RX/TX deltas, fresh inbound
TCP probes, listener health and captures from both ends of the failed leg.

## Deliberate exclusions

No arbitrary traffic padding, per-packet delay or automatic connection-count
increase was added. Those require baseline traffic/latency measurements and
can worsen throughput or introduce new patterns. TLS 1.3 and authentication
remain enforced; changing the transport does not remove network-level IP
blocking. A real site and public certificate still need operator configuration.

## v3.5.0: carriers and traffic shape

**The decoy differs per install.** Its nginx build, `server_tokens` setting,
`Last-Modified` and `ETag` are derived from the shared secret, so no two
deployments answer a probe alike and the fleet cannot be found with one scan.
`/` serves that page; every other path, the cover path included, is a 404. It
honours `If-None-Match`, `If-Modified-Since` and `Range`, so a probe that
replays the `ETag` is answered `304` as a file on disk would be.

**`padding: true` (h2 only, off by default).** Varies the length of every small
record so the fixed-size smux keepalive stops being a constant on the wire.
Measured idle: without it, 12 of 16 records after the handshake were exactly 39
bytes; with it, 19 records had 19 distinct lengths. This changes the framing
between the two smux endpoints, so **set it on the server and on every client
together** — a mismatch drops the session the way a `smux_version` mismatch
does. Bulk transfers are not padded and pay nothing on the wire.

**`mode: stealth`.** A Noise NNpsk0 carrier with no TLS, no certificate, no SNI
and no ALPN: two handshake messages indistinguishable from random bytes, then a
ChaCha20-Poly1305 record layer with padding always on. A peer without the shared
secret receives nothing at all, so a port scan finds a dead port.

Use it when the HTTP/2 cover is the thing being filtered. It is not strictly
better: traffic with no recognisable protocol is a category a censor can block
on its own, and there is no cover story to fall back on. Both ends must run the
same carrier.
