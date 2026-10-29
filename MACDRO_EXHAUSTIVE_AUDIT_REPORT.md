# Macdro Exhaustive Audit Report

**Date:** 2026-10-29
**Auditor:** opencode (automated security/correctness audit session)
**Repo:** `/Users/gouthamsai/opencode_1/Macdro` — branch `main`, 3 commits ahead of `origin/main`
**Environment:** macOS arm64, Swift 6.4 (swiftlang-6.4.0.34.1), Xcode 27.1 (build 27A9275), target macOS 14+
**Report status:** Interim — baseline verification and full source review complete; dynamic adversarial PoC phase and defect fixes not yet executed. Findings below are marked with their evidence basis.

---

## 1. Executive Summary

Macdro is a native macOS 14+ menu-bar LAN file-transfer application built on Swift/SwiftUI/SwiftNIO. This audit examined the complete server stack (`MacdroKit`), app layer, web client, and existing test suites through full source review, and re-ran every shipped verification gate.

**Baseline results: all green.**

| Gate | Result |
|---|---|
| `swift build` | success (1.83 s, cached), EXIT=0 |
| `swift test` | **89/89 XCTest passed, 0 failed** |
| `swift run MacdroSelfTest` | all checks passed, EXIT=0 |
| `swift run MacdroAudit test` | `AUDIT complete` — 0 failures, all invariants held (evidence §3.4) |

**Findings:** 1 likely correctness bug (BUG-001, setup-server handler sharing), 1 documentation/defense-in-depth gap (SEC-001, body-phase slowloris window), 1 informational auth-ordering oracle (SEC-002), 2 low-severity resource-accounting issues (SEC-003, BUG-002), and 2 informational items (SEC-004, SEC-005). **No critical or high-severity vulnerabilities were found.** The token-authorization model, loopback/LAN transport separation, path containment, header-injection neutralization, range-request parsing, quota enforcement, and certificate lifecycle all verified clean under both static review and dynamic testing.

**Overall verdict:** **PASS WITH MINOR FINDINGS** — production-grade security posture; no blocking issues; findings are defense-in-depth and correctness polish.

---

## 2. Scope & Methodology

### 2.1 Scope
- **In scope:** All Swift sources (`Sources/MacdroKit`, `Sources/Macdro`, `Sources/MacdroSelfTest`, `Sources/MacdroAudit`), web client (`app.js`, `index.html`), tests (`Tests/MacdroKitTests`), build/verify scripts, security invariants (token auth, path containment, TLS separation, resource limits, upload pipeline, SSE, archive/manifest).
- **Out of scope:** Other devices on the LAN (no attacks issued), Keychain, firewall configuration, Android/USB native transports (explicitly not implemented per `PROJECT_CONTEXT.md`), PDF artifacts.
- **Safety constraints honored:** All dynamic testing on loopback with disposable temp directories and ephemeral ports; no pushes, no releases, no weakening of security controls; no modification of user files; no secrets logged.

### 2.2 Method
1. **Phase 0 — Discovery:** repo state, environment versions, full file inventory.
2. **Phase 1 — Static review:** line-by-line review of every `MacdroKit` source (HTTPHandler 2075 lines, UploadStore 919 lines, and all others), app layer, web client, and all four test files.
3. **Phase 2 — Baseline reproduction:** rebuild + full test suite + self-test + audit tool (§3).
4. **Phases 3–6 — Dynamic adversarial PoCs, fixes, re-verification:** **not yet executed in this session** (report finalized per user request at current progress point).

### 2.3 Evidence basis labels
- `[DYNAMIC]` — reproduced/replayed against a live server during this audit.
- `[STATIC]` — determined by source review; not yet dynamically confirmed.
- `[TEST]` — covered by an existing passing XCTest (re-run this session).

---

## 3. Baseline Verification Results

### 3.1 Build
`swift build` → success, 1.83 s, EXIT=0. No warnings.

### 3.2 Test suite
`swift test` → **89 XCTest cases passed, 0 failed** (log: `/tmp/audit_baseline_test.log`). Coverage highlights re-verified this session:
- Cookie required for bare `/api/*`; token-path `/s/<token>/` authorization.
- SSE heartbeat and close-on-auth-rotation.
- TLS trust path (CA-issued cert, hostname checks, SAN encoding for IP+DNS).
- Loopback HTTP vs LAN HTTPS separation.
- Slowloris connection bounding (100 connections) and partial-header close at read timeout.
- Upload quota 507, resumable caps (exact under concurrency), abandoned-upload leak tests.
- Path escape via symlink and post-upload directory swap rejected.
- Zero-byte files, pre-1970 mtimes, ETag changes within one second, 413 chunked/oversized bodies.
- ZIP/manifest single-flight, concurrent upload name collisions, 5 MiB coalesced uploads, 3 parallel uploads.

### 3.3 Self-test
`swift run MacdroSelfTest` → all PASS including: resumable upload completes/marks completion/contents match, duplicate completion 409, wrong-offset recovery, unknown-upload reset, oversized clipboard 413, wrong token 404. EXIT=0.

### 3.4 Audit tool (`swift run MacdroAudit test`)
Dynamic end-to-end run (log: `/tmp/audit_baseline_audit.log`), key evidence:

| Check | Result | Invariant |
|---|---|---|
| Server start, TLS fingerprint | `tls=24:92:...` (self-signed, ephemeral) | TLS identity generated on demand |
| CA private key file mode | `ca-key-mode=600` | ✅ owner-only key permissions |
| LAN HTTPS `/health` | `200 ok` with full chain validation | ✅ CA-issued cert usable by system trust |
| **Plaintext on LAN port** | **`rejected`** | ✅ loopback HTTP / LAN HTTPS separation holds |
| Root page `/` | 200, `token-leak=false`, no redirect | ✅ token not in root HTML |
| `/s/<token>/api/session` | 200, no `"token"` field, no leak | ✅ session JSON never exposes token |
| Bare `/api/session` | **401 Unauthorized** | ✅ cookie required for bare API |
| Zero-byte GET/HEAD | 200, `content-length=0`, body empty | ✅ correct length semantics |
| CR/LF filename injection | `content-disposition` neutralized (`headerX-Injected_`), `injected-header-present=false` | ✅ header injection impossible |
| Range fuzz (12 cases) | invalid/unsatisfiable → 416 `bytes */10`; malformed/multi-range → 200 full body; valid prefix/suffix/open → 206 with correct `Content-Range` | ✅ RFC-compliant, no parsing bypasses |
| 4 GiB offset on sparse 5 GiB file | 206, 100 bytes, `bytes 4294967296-4294967395/5368709120` | ✅ no 32-bit offset overflow |
| 4 concurrent uploads, identical name | `files=4 uniquePayloads=4 contentsMatch=true` | ✅ unique suffixing, no clobber |
| 12 resumable creations (cap 8) | excess rejected `tooManyUploads`; 8 part files, leases released, TTL cleanup pending | ✅ exact per-client cap |
| Long Unicode name (1204-byte emoji name) | 201 accepted, truncated safely | ✅ filesystem limit compliance |
| 32 MiB POST `/health` | **413 Payload Too Large, body=0** | ✅ oversized bodies rejected before buffering |

---

## 4. Architecture & Threat Model

- **Loopback listener** (`127.0.0.1`, ports 8787–8807 with ephemeral fallback): plain HTTP; routes `/`, `/s/<token>/...`, bare `/api/*`+`/f/*` (cookie-gated).
- **LAN listener** (`0.0.0.0`): TLS by default (self-signed CA + leaf, SAN=IP+DNS), or plain HTTP only via explicit persisted Easy mode; token-path routes only.
- **Authorization:** 64-hex session token (`UInt8.random`, secure) compared with `constantTimeEquals`; `macdro_session` cookie (Secure+HttpOnly+SameSite=Strict on HTTPS) for bare-API after visiting token URL.
- **Trust boundary:** anyone with the token URL is a trusted peer (capability model); unauthenticated LAN peers can reach only TLS handshake / root (no token leakage verified).
- **Resource bounds:** 1 MiB buffered body, 30 s header/read timeout, 128 global / 16 per-IP connections, 16 GiB per-file / 64 GiB total quota, 8 MiB drain on reject, SSE heartbeat 10 s / lifetime 1 h.
- **Attacker capabilities considered:** unauthenticated LAN peer; token-holder gone malicious; network-adjacent DoS; malicious filenames/paths; oversized/malformed HTTP; browser XSS via rendered content.

---

## 5. Security Findings (SEC-xxx)

### SEC-001 — Body-phase read timeout gap (slowloris partial body) — *Low / Defense-in-Depth* `[STATIC]`
**Location:** `Sources/MacdroKit/HTTPHandler.swift` (head/body state machine; `IdleTimeoutHandler` re-arm points).
**Issue:** The header timeout is cancelled when `.head` completes and re-armed only at `.end`. `IdleStateHandler(allTimeout:)` resets on *any* read, so an authenticated client that sends a valid head plus a trickle of body bytes (1 byte / 25 s) holds the connection indefinitely. Bounded only by connection caps (128 global / 16 per-IP), not by a wall-clock body deadline. Documentation claims "read+header timeout 30 s".
**Impact:** Connection-slot exhaustion against legitimate LAN peers by a token holder (or, on loopback Easy mode, by any local process). No data corruption or leakage.
**Recommendation:** Arm an absolute (non-resetting) body deadline from head receipt to `.end`, e.g. `Scheduled` task cancelled at `.end`, sized by expected upload duration or a generous fixed cap (e.g. 5 min), independent of `IdleStateHandler`.
**Existing mitigation:** `ConnectionGate` caps; `testHundredSlowlorisConnectionsAreBoundedAndClosed` covers full slowloris (no body), not partial-body.
**Status:** Not yet fixed (fix phase pending).

### SEC-002 — Bare `/f/{uuid}` existence check before cookie auth — *Informational* `[STATIC]`
**Location:** `Sources/MacdroKit/HTTPHandler.swift` (bare `/f/` route).
**Issue:** The handler resolves the file before checking the session cookie, so an unauthenticated requester gets 404 for unknown IDs vs 401 for known IDs — an existence oracle for shared-file UUIDs.
**Impact:** Trivially negligible — UUIDv4 IDs are unguessable; knowing an ID still requires the cookie or token path to download bytes.
**Recommendation:** Check cookie first; return 401 uniformly.
**Status:** Not yet fixed.

### SEC-003 — Lease-held resumable uploads exempt from TTL cleanup — *Low* `[STATIC]` `[TEST]` (cap behavior confirmed dynamic; TTL interaction static)
**Location:** `Sources/MacdroKit/UploadStore.swift` (`cleanupExpired` skips `leaseHeld` entries).
**Issue:** A token holder drip-feeding 1 byte per lease-refresh interval holds resumable leases (cap 8/client) and up to 8×16 GiB = 128 GiB of quota reservations + on-disk part files indefinitely. Cleanup never reaps lease-held entries.
**Impact:** Disk/quota denial against the *same host session* (capability model: the attacker already holds full upload/download powers, so this is a resource-hygiene gap, not a privilege escalation).
**Recommendation:** Hard TTL even for lease-held entries (e.g. no byte received for N minutes → reap), or count idle leases against a global wall-clock.
**Status:** Not yet fixed.

### SEC-004 — Intermediate path components not screened for `.macdro-*.part` — *Low* `[STATIC]`
**Location:** `Sources/MacdroKit/UploadStore.swift` (`sanitizeName` guards the final name only).
**Issue:** A remote can upload `name=.macdro-abc.part/x.bin`, creating a *directory* matching the temp-file prefix. Startup orphan cleanup (`testStartupRemovesOrphanedPartFiles`) removes it at next launch; no data loss or authorization bypass.
**Recommendation:** Apply the `.macdro-` reserved-prefix check to every path component.
**Status:** Not yet fixed.

### SEC-005 — `Math.random` fallback for client upload IDs — *Informational* `[STATIC]`
**Location:** `Sources/MacdroKit/Resources/Web/app.js` (`makeUploadID`).
**Issue:** If Web Crypto is unavailable, upload IDs fall back to `Math.random` (predictable). Server enforces per-client entry ownership, so a colliding ID from another client is rejected/mismatched, not hijacked.
**Recommendation:** Require Web Crypto; fail the upload UI if absent.
**Status:** Not yet fixed.

### Verified clean (no finding)
- Token generation (`UInt8.random`); `constantTimeEquals` fixed-length compare. `[TEST]`
- CR/LF/quote/backslash neutralization in `Content-Disposition` — dynamically confirmed (`injected-header-present=false`). `[DYNAMIC]`
- Path containment: symlinked-directory escape and post-upload directory swap both rejected. `[TEST]`
- Loopback HTTP / LAN HTTPS separation; plaintext on LAN port dynamically confirmed rejected. `[DYNAMIC]`
- Session token never in root HTML or session JSON; bare API 401 without cookie. `[DYNAMIC]`
- Cert generation via argv exec (no shell injection); CA key mode 600; SAN IP+DNS; hostname checks pass. `[DYNAMIC]` `[TEST]`
- No XSS in web client (`textContent` everywhere; `innerHTML` only for static SVG). `[STATIC]`
- Bounded rejected-body drain (8 MiB); 32 MiB non-upload body → 413 with zero body buffered. `[DYNAMIC]`
- SSE closes on auth rotation; heartbeat/lifetime caps tested. `[TEST]`
- ZIP/manifest `SingleFlight` on `DispatchQueue.global(.utility)` (not event loop) — no NIO deadlock. `[STATIC]` `[TEST]`
- IPv4-mapped IPv6 remotes rejected (fail-closed). `[STATIC]`

---

## 6. Correctness Defects (BUG-xxx)

### BUG-001 — Shared `SetupHTTPHandler` instance across all setup-server connections — *Medium (correctness)* `[STATIC]`
**Location:** `Sources/MacdroKit/SetupServer.swift` (`start()` creates one handler, adds it to every channel's pipeline).
**Issue:** NIO channel handlers are per-connection state machines; sharing one instance across concurrent connections races on `head`/write state. Concurrent requests during the ~3 s cert-pairing window can receive no response or a mis-framed response (one client's bytes to another).
**Impact:** Pairing-page flakiness under concurrent connect (phone + laptop retrying simultaneously). Not exploitable for auth bypass (responses contain only public cert material; token never present). Existing tests (`testSetupServerServesOnlyCertificateMaterialAndStops`, `testSetupServerAutoStopsWithoutDeadlocking`) are single-connection and pass.
**Recommendation:** Instantiate a fresh `SetupHTTPHandler` inside `childChannelInitializer` per channel.
**Status:** Not yet fixed (highest-priority fix).

### BUG-002 — `committedBytes` drifts upward when user deletes received files — *Low (correctness)* `[STATIC]`
**Location:** `Sources/MacdroKit/UploadStore.swift` (quota accounting).
**Issue:** Quota `committedBytes` increments on commit but is only reconciled at app restart (directory scan). User deleting files via Finder mid-session inflates apparent usage; worst case spurious 507 until restart.
**Recommendation:** Recompute on file-removed notifications, or decrement via `SessionStore` removal hooks.
**Status:** Not yet fixed.

### Verified clean (no finding)
- Range parsing edge cases (start>end, suffix -0, multi-range, UInt64.max end, whitespace) — 12/12 dynamic cases correct. `[DYNAMIC]` `[TEST]`
- Pre-1970 mtimes, zero-byte lengths, same-second ETag changes. `[TEST]`
- Concurrent identical-name uploads: 4/4 unique, contents match. `[DYNAMIC]`
- Resumable offset mismatch recovery, duplicate completion 409, unknown upload reset. `[TEST]` (self-test)
- Unicode name truncation fits filesystem limits. `[DYNAMIC]` `[TEST]`

---

## 7. Invariant Matrix

| # | Invariant | Enforced in | Verified by | Status |
|---|---|---|---|---|
| I-1 | Session token never leaves server except via out-of-band URL/QR | `SessionStore`, `HTTPHandler` | Audit root/session checks, `testRootDoesNotLeakTokenOrRedirect`, `testSessionJSONDoesNotExposeSessionToken` | ✅ PASS `[DYNAMIC]` |
| I-2 | Loopback may serve HTTP; LAN serves TLS unless explicit Easy mode | `HTTPServer`, `SettingsView` | `AUDIT plaintext-on-lan-port=rejected`, `testLoopbackHTTPAndLANHTTPSAreSeparate`, `testEasyModeServesPlainHTTP` | ✅ PASS `[DYNAMIC]` |
| I-3 | All paths contained within upload root | `UploadStore.sanitizeName` + realpath checks | symlink-escape and dir-swap tests | ✅ PASS `[TEST]` |
| I-4 | Request bodies bounded and streamed; no unbounded buffering | `HTTPHandler`, `MacdroLimits` | 32 MiB POST → 413 body=0; chunked-over-cap 413 test | ✅ PASS `[DYNAMIC]` |
| I-5 | CR/LF never emitted in response header values | `HTTPHandler.contentDisposition` | audit newline-filename test | ✅ PASS `[DYNAMIC]` |
| I-6 | Connection counts bounded globally and per IP | `HTTPGuards.ConnectionGate` | slowloris-100 test | ✅ PASS `[TEST]` |
| I-7 | Header size/count bounded | `HeaderLimitHandler` | hardening tests | ✅ PASS `[TEST]` |
| I-8 | Upload quota (16 GiB/file, 64 GiB total) enforced pre-write | `UploadStore` | quota-507 and in-flight quota tests | ✅ PASS `[TEST]` |
| I-9 | Resumable upload caps exact under concurrency | `UploadStore` | audit 12-of-8 + `testResumableUploadLimitIsExactUnderConcurrency` | ✅ PASS `[DYNAMIC]` |
| I-10 | Range/conditional requests RFC-correct; no integer overflow >4 GiB | `RangeRequest`, `HTTPHandler` | 12-case fuzz + 4 GiB sparse offset | ✅ PASS `[DYNAMIC]` |
| I-11 | SSE authenticated; closes on token rotation | `HTTPHandler` | `testSSESendsHeartbeatAndClosesOnAuthRotation` | ✅ PASS `[TEST]` |
| I-12 | TLS cert CA-issued, SAN-correct, key mode 600 | `TLSIdentity` | audit fingerprint/mode + trust-path tests | ✅ PASS `[DYNAMIC]` |
| I-13 | Bare `/api/*` requires session cookie | `HTTPHandler` | audit 401 + `testCookieIsRequiredForAPIAndIssuedByReceiverPage` | ✅ PASS `[DYNAMIC]` |
| I-14 | No unbounded body-phase holding (absolute deadline) | `HTTPHandler` | **gap identified — SEC-001** | ⚠️ GAP |
| I-15 | One handler state machine per connection (setup server) | `SetupServer` | **gap identified — BUG-001** | ⚠️ GAP |
| I-16 | Lease-held uploads eventually reaped | `UploadStore.cleanupExpired` | **gap identified — SEC-003** | ⚠️ GAP |

---

## 8. Attack-Surface Test Results (Dynamic)

Executed this session against real servers on loopback (audit tool + XCTest integration servers):

| Attack | Outcome |
|---|---|
| Token brute-force / leak via root or session JSON | ❌ blocked (no token in any unauthenticated response) |
| Bare API access without cookie | ❌ 401 |
| Plaintext HTTP to LAN port | ❌ rejected (TLS-only) |
| CRLF injection via shared/upload filename | ❌ neutralized in Content-Disposition |
| Range fuzzing (12 malformed/extreme cases) | ❌ all safe (416/200/206, no crash, no overflow) |
| >4 GiB offset arithmetic | ❌ correct 206 |
| Oversized (32 MiB) non-upload body | ❌ 413, zero bytes buffered |
| Concurrent identical-name upload clobber | ❌ 4 unique files |
| Resumable cap bypass (12 > 8) | ❌ `tooManyUploads` |
| Symlink/dir-swap path escape | ❌ rejected |
| Slowloris (100 conns) | ❌ bounded and closed |
| Partial-header stall | ❌ closed at read timeout |
| Wrong token download | ❌ 404 |
| Clipboard body >1 MiB | ❌ 413 |

Not yet dynamically executed this session (deferred to fix/PoC phase): partial-body slowloris proof-of-concept (SEC-001), concurrent setup-server race PoC (BUG-001), lease-drip quota exhaustion (SEC-003), live session-rotation-during-upload matrix.

---

## 9. Test Coverage Assessment

- **Strengths:** Real-server integration tests (not mocks); TLS trust validated via system evaluator; raw-socket adversarial harnesses in `RegressionTests`/`HardeningTests` cover protocol-level abuse; resumable/quota/lease semantics thoroughly covered; audit tool provides independent dynamic evidence.
- **Gaps identified:**
  1. No test for partial-body (trickle) slowloris — only full slowloris and partial-header.
  2. No concurrent-connection test against the setup server (single-connection tests only).
  3. No test that lease-held resumable entries are eventually reaped.
  4. No test for intermediate path components named `.macdro-*.part`.
  5. No test for `committedBytes` reconciliation after mid-session file deletion.
- Each gap maps 1:1 to a finding (SEC-001, BUG-001, SEC-003, SEC-004, BUG-002) and will receive a regression test when the fix phase runs.

---

## 10. Residual Risks & Limitations

- **Interim report:** Phases 3–6 (adversarial PoCs, fixes, re-verification) not yet run; findings SEC-001/BUG-001 are static-analysis based and high-confidence but lack a captured reproduction transcript.
- **Capability model:** Any token holder is fully trusted by design; findings assume a *malicious token holder* or *network-adjacent attacker without token*. Cross-device physical testing (iPhone/Android browsers) remains blocked per `PROJECT_CONTEXT.md`.
- **Uncommitted working tree** (4 modified files, 1 deleted, new `MainWindowController.swift`): audit reviewed the committed+working-tree state as-is; `MainWindowController`/`StatusToast` refactor in progress was read but not part of the security boundary.
- No fuzzing (e.g. libFuzzer/NIO-fuzz) was run; header/range parsers were reviewed and exercised but not fuzzed.

---

## 11. Remediation Roadmap

| Priority | ID | Action | Est. effort |
|---|---|---|---|
| P1 | BUG-001 | Per-channel `SetupHTTPHandler` in `childChannelInitializer`; add concurrent-connection regression test | Small |
| P2 | SEC-001 | Absolute body-phase deadline (scheduled task, cancelled at `.end`); trickle-body regression test | Small |
| P3 | SEC-003 | Hard TTL for lease-held entries (no-bytes-received window); drip test | Small |
| P4 | SEC-002 | Cookie check before file resolution on bare `/f/` route | Trivial |
| P5 | SEC-004 | Reserved-prefix check on all path components | Trivial |
| P6 | BUG-002 | Reconcile `committedBytes` on file removal or periodic rescan | Small |
| P7 | SEC-005 | Drop `Math.random` fallback; require Web Crypto | Trivial |
| — | §9 | Close the five test-coverage gaps as regression tests with each fix | bundled |

Post-fix verification plan: `swift build` → `swift test` → `swift run MacdroSelfTest` → `swift run MacdroAudit test` → `./scripts/verify.sh` (zero-warning gate) → Xcode Debug build.

---

## 12. Final Verdict

**PASS WITH MINOR FINDINGS.**

Macdro's security architecture is sound and its shipped verification suite is unusually strong for a project this size: token authorization, transport separation, path containment, body bounds, header hygiene, range parsing, quota, and TLS lifecycle all withstood both static review and live adversarial replay this session (89/89 tests, self-test all-pass, audit tool all-invariants-held).

No critical or high-severity vulnerability was found. The five informational/low findings (SEC-001…SEC-005) and two correctness defects (BUG-001, BUG-002) are defense-in-depth and polish issues, none enabling data leakage, privilege escalation, or remote code execution; the most impactful (BUG-001, SEC-001) degrade availability/flakiness under adversarial or concurrent conditions and have straightforward fixes.

**Recommendation:** Ship-blocking? **No.** Schedule the P1–P3 remediations before the next release; fold the remainder into routine hardening. Re-run this audit's dynamic phase after fixes to close the interim-report gap.

---

*Evidence logs: `/tmp/audit_baseline_test.log` (89/89), `/tmp/audit_baseline_selftest.log` via session capture, `/tmp/audit_baseline_audit.log` (full audit transcript). This report does not overwrite or replace `Macdro-Audit-Report.pdf` (historical, not present in tree).*
