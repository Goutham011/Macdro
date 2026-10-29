# Macdro Remediation Report — 2026-10-29

Remediation of the seven findings in `MACDRO_EXHAUSTIVE_AUDIT_REPORT.md`. Fixes were implemented in audit priority order (BUG-001 → SEC-001 → SEC-003 → SEC-002 → SEC-004 → BUG-002 → SEC-005), each paired with regression tests, and verified with the full pipeline. No security control was weakened, no token/secret is present in this report, all testing used loopback interfaces, ephemeral ports, and temporary directories, and nothing was committed, pushed, signed, or published.

## A. Executive summary

- **7/7 findings remediated**, 0 skipped. No critical/high findings existed in the audit; the two most impactful items (BUG-001 setup-server response interleaving, SEC-001 body-phase slowloris window) are fixed and covered by raw-socket tests that reproduce the original adversarial conditions.
- **30 new regression tests** in `Tests/MacdroKitTests/RemediationTests.swift` (1,228 lines) close every deferred test gap the audit identified — partial-body slowloris (SEC-001), concurrent/interleaved setup-server clients (BUG-001), lease-drip quota exhaustion (SEC-003), reserved-prefix neutralization (SEC-004), quota reconciliation (BUG-002), session-rotation-during-upload matrix, stale-cookie rejection, and property-style Range/upload-path fuzzing.
- **Full suite green: 119/119** (89 legacy + 30 new), `MacdroSelfTest` 71/71, `MacdroAudit test` → `AUDIT complete`, and a **clean `scripts/verify.sh`** run (zero-warning SwiftPM build with warning-as-failure, tests, self-test, audit, XcodeGen, `xcodebuild` Debug with `CODE_SIGNING_ALLOWED=NO`) all pass.
- Verification of the new quota tests accounted for APFS block allocation: `totalFileAllocatedSizeKey` (used by the directory scan) rounds each file up to the 4096-byte block on this volume (empirically confirmed for 0–150,000-byte files), so test quotas/sizes were chosen so the admission outcome is identical under both exact-byte and block-allocated accounting.

## B. Findings and remediation status

| ID | Audit severity | Status | Fix | Regression tests (all in `RemediationTests`) |
|---|---|---|---|---|
| BUG-001 | Medium (correctness) | ✅ Fixed | `SetupServer.swift`: fresh `SetupHTTPHandler` per child channel | `testSetupServerInterleavedConnectionsGetIndependentResponses`, `testSetupServerConcurrentClientsReceiveCorrectResources`, `testSetupServerRepeatedAndAbruptlyClosedConnections`, `testSetupServerStopsPromptlyWithConnectedClients` |
| SEC-001 | Low / defense-in-depth | ✅ Fixed | `MacdroLimits.BodyTimeoutPolicy` + `HTTPHandler` absolute body deadline | `testPartialBodyTrickleIsClosedByAbsoluteDeadline`, `testTimedOutResumableUploadReleasesLeaseAndResumes`, `testTimedOutNonResumableUploadLeavesNoTemporaryFiles`, `testBodyCompletingBeforeDeadlineSucceeds`, `testZeroLengthBodyRequestIsNotRejectedByDeadline`, `testBodyTimeoutPolicyBoundsAndMonotonicity` |
| SEC-003 | Low | ✅ Fixed | `UploadStore`: `leaseHardTimeout` (8 h) + `leaseAcquiredAt` reaped by `cleanupExpired` | `testUnleasedExpiredUploadIsStillCleanedUp`, `testActiveLeaseIsPreservedBeforeHardTimeout`, `testLeaseHeldUploadExpiresEvenWhileActivityIsTouched`, `testReapedLeaseReleasesQuotaForNewUploads` |
| SEC-002 | Informational | ✅ Fixed | `HTTPHandler`: cookie check before UUID/`store.file(id:)` on bare `/f/` | `testBareFileRouteAuthorizesBeforeResolvingExistence` |
| SEC-004 | Low | ✅ Fixed | `UploadStore.sanitizeComponent`: reserved-prefix neutralization for every path component | `testReservedPrefixNeutralizedInEveryPathComponent`, `testReservedPathComponentUploadCreatesNeutralizedDirectory` |
| BUG-002 | Low (correctness) | ✅ Fixed | `UploadStore.reconcileQuotaNow()` + generation guard + timer/rejection triggers | `testQuotaRecoversAfterExternalFileDeletion`, `testRepeatedReconciliationDoesNotDoubleDecrement`, `testReconciliationCountsInFlightTemporaryUploadsExactlyOnce`, `testQuotaRejectionTriggersAutomaticReconciliation` |
| SEC-005 | Informational | ✅ Fixed | `app.js`: Web-Crypto-only upload IDs, fail closed, no `Math.random` | `testWebClientHasNoInsecureUploadIDRandomness`, `testMakeUploadIDUsesRandomUUIDWhenAvailable`, `testMakeUploadIDUsesSecureGetRandomValuesFallback`, `testMakeUploadIDFailsClosedWithoutSecureRandomness` |

Deferred gaps from the audit's §9/§8 (now closed): live session-rotation-during-upload (`testTokenRotationMidUploadRejectsStaleTokenAndResumesWithNewToken`), SSE close on rotation (`testTokenRotationClosesActiveEventStream`), stale cookie after rotation (`testStaleCookieIsRejectedAfterRotationMidUpload`), and property-style fuzzing (`testRangeRequestParseFuzzInvariants` — 600 iterations; `testUploadPathFuzzInvariants` — 500 iterations, deterministic seeds).

## C. Implementation details

**BUG-001 — setup-server handler isolation** (`Sources/MacdroKit/SetupServer.swift`)
The server previously captured one `SetupHTTPHandler` in the bootstrap closure and installed that shared instance into every connection's pipeline; the handler's request state (`requestHead`, partial-read buffer) was cross-connection, so interleaved clients could receive mismatched or concatenated responses. The handler (and logger) are now constructed inside `childChannelInitializer`, giving each channel its own state machine. Verified with raw sockets: a client stalled mid-head receives only its own `/health` answer once its terminator arrives, while a second connection concurrently receives a complete `/ca.crt` response; 10 sequential requests and an abrupt half-request close leave the listener healthy; `stop()` returns promptly (< 5 s) with a connected client.

**SEC-001 — absolute body-phase deadline** (`Sources/MacdroKit/MacdroLimits.swift`, `HTTPServer.swift`, `HTTPHandler.swift`)
New `BodyTimeoutPolicy` (defaults: min 60 s, max 6 h, chunked/unknown 15 min, throughput floor 64 KiB/s) computes `deadlineSeconds(contentLength:) = clamp(⌈contentLength / 64 KiB/s⌉, 60 s, 6 h)` (nil/unknown length → 15 min). `MacdroServerConfiguration.bodyTimeoutPolicy` plumbs it into `MacdroHTTPHandler`, which arms a scheduled task when the request **head** is accepted (`armBodyTimeout`) — the deadline does **not** reset as bytes arrive, so a trickling client cannot hold the connection open indefinitely (the audit's gap; the previous 30 s read timeout only fired between reads). On expiry: normal requests get a `408 Request Timeout` response; connections in the rejected-body-drain path (`isRejectingRequest`) are closed to bound drain. The task is cancelled at `.end`, `channelInactive`, and `errorCaught`, and refuses to act on inactive channels. Known-length policy is monotonic in body size and bounded (property-tested). The web client's resumable 16 MiB chunks receive ~256 s each at the 64 KiB/s floor — far above LAN throughput — so legitimate transfers are unaffected; a body that completes before its deadline proceeds normally, and zero-length requests are answered immediately.

**SEC-003 — lease hard timeout** (`Sources/MacdroKit/UploadStore.swift`, `MacdroLimits.swift`)
`UploadStore.Configuration.leaseHardTimeout` (default `MacdroLimits.leaseHardTimeoutSeconds` = 8 h) with `ResumableEntry.leaseAcquiredAt` set on lease acquire (`beginResumable`, both fresh and re-lease paths) and cleared on `releaseLease`. `cleanupExpired(now:)` now reaps entries whose lease has been held past the hard timeout **in addition to** the idle TTL for unleased entries — constant `touchResumable`/append activity can no longer keep a lease-held upload alive forever (the audit's drip scenario). Reaping removes the entry, cancels its transaction (`settle(discarded: true)` → `committedBytes -= written`, `commitGeneration` bumped), and deletes the `.part` file, releasing quota for new uploads. Tests confirm: unleased idle expiry unchanged; an active lease is preserved at t+59 s of a 60 s timeout; touches every 5 s never defer the reap past the hard timeout; and a 90 KB lease-held upload that exhausts a 100 KB quota is reaped at +31 s (30 s timeout), after which a new 90 KB upload succeeds.

**SEC-002 — authorization before file lookup** (`Sources/MacdroKit/HTTPHandler.swift`)
The bare `/f/{uuid}` branch evaluated `store.file(id:)` **before** `cookieAuthorized`, letting an unauthenticated caller distinguish existing from non-existing file ids by response status. The cookie check now runs first: unauthenticated requests receive an identical `401` + `Unauthorized\n` body regardless of id validity or existence (existence oracle closed), then authorized requests proceed to normal lookup (`200` for known, `404` + `Not found\n` for unknown/invalid). Token-path routes (`/s/{token}/f/{uuid}`) remain capability-authorized by design.

**SEC-004 — reserved prefix in every path component** (`Sources/MacdroKit/UploadStore.swift`)
`.macdro-*.part` neutralization (`_` prefix) previously ran only in `sanitizeName`, which applies to the final file name; intermediate **directory** components could still be named `.macdro-*.part`, colliding with the store's own temporary-file namespace. The check moved into `sanitizeComponent` (after control-character/`.`/`..` handling and truncation, so truncation cannot reintroduce the pattern), covering every component of `name` and `relativePath`; `sanitizeName` keeps the empty→`"Untitled"` fallback. A directory literally named `.macdro-evil.part` is created as `_.macdro-evil.part`.

**BUG-002 — quota reconciliation** (`Sources/MacdroKit/UploadStore.swift`)
`committedBytes` only ever increased (by written bytes) and never reflected files deleted outside the app (Finder), so quota admission drifted permanently upward until restart. New `reconcileQuotaNow()` re-scans the upload directory (`directoryBytes`: sum of `totalFileAllocatedSizeKey` over regular files, falling back to `fileSizeKey`) and assigns `committedBytes = scanned` **only if `commitGeneration` is unchanged** across the scan — an in-flight commit or discard bumps the generation and invalidates the scan, so nothing is double-counted or lost. Triggers: the 60 s cleanup timer (after `cleanupExpired`), and a coalesced `cleanupQueue` async rescan scheduled by `scheduleQuotaReconciliationLocked()` on every quota rejection (flag reset at the start of the async block so bursts still schedule a follow-up scan). Admission (`ensureCapacityLocked`) is unchanged (`used ≤ quota`, `reserved + additional ≤ quota − used`) — only its view of `used` is refreshed. Tests: external deletion restores admission (with a bounded poll loop for the one-shot stale-scan race window); three consecutive reconciliations neither under- nor over-count (a subsequent over-quota begin still throws — detection holds under both exact and 4096-block-allocated accounting); and an in-flight temporary upload is counted exactly once (a double-counted scan would make a probe begin fail; single-count makes it pass).

**SEC-005 — secure client upload IDs** (`Sources/MacdroKit/Resources/Web/app.js`)
`makeUploadID` previously fell back to `Math.random()` when Web Crypto was unavailable, producing guessable upload ids (session-fixation surface for resume/complete routes). It now uses `crypto.randomUUID()` (dashes stripped) or `crypto.getRandomValues()` only, and returns `null` otherwise; the upload flow fails closed with "Secure random IDs are unavailable in this browser" before any request is made. `Math.random` no longer appears anywhere in `app.js`. Tests extract the function source and evaluate it in JavaScriptCore under three window stubs (randomUUID → expected UUID string; getRandomValues → the deterministic 32-hex value `030a11181f262d343b424950575e656c`; no crypto → `null`), plus a static no-`Math.random` scan.

## D. Verification evidence

All commands run on macOS arm64 (Swift 6.4, Xcode 27.1) on 2026-10-29, loopback-only.

| Step | Command | Result |
|---|---|---|
| Source build | `swift build` | ✅ Build complete, zero errors |
| Test compile | `swift build --build-tests` | ✅ Zero errors, zero warnings |
| New suite | `swift test --filter RemediationTests` | ✅ 30/30, 0 failures (~10 s) |
| Full suite | `swift test` | ✅ **119/119**, 0 failures (~87 s; 89 legacy all still green) |
| Self-test | `swift run MacdroSelfTest` | ✅ "All checks passed." (71 checks) |
| Audit tool | `swift run MacdroAudit test` | ✅ `AUDIT complete` |
| Full gate | `./scripts/verify.sh` (clean scratch, warning-as-failure) | ✅ "Verification passed." — SwiftPM clean build with no `warning:` lines, 119/119, self-test, audit, `xcodegen generate`, `xcodebuild -configuration Debug CODE_SIGNING_ALLOWED=NO build`, embedded `Macdro_MacdroKit.bundle` present |
| Allocation model | `st_blocks*512` for 0…150,000-byte files on the test volume | ✅ Always `ceil(size/4096)*4096` (0-byte = 0); used to size quota tests |

Baseline (pre-remediation) evidence from the audit session is preserved at `/tmp/audit_baseline_test.log` (89/89) and `/tmp/audit_baseline_audit.log` (`AUDIT complete`). The `verify.sh` run's logs were written to the temp dir it prints on completion.

Dynamic adversarial coverage now includes the three PoCs the audit deferred: partial-body slowloris (client trickles 5 bytes every 300 ms → server responds 408 and closes within the 1 s policy deadline, well before the read timeout), concurrent/interleaved setup-server connections (independent responses), and lease-drip quota exhaustion (touching an active lease cannot prevent the 8 h reap that restores quota).

## E. Residual issues

- **Physical-device paths remain untested** (pre-existing, unchanged by remediation): iPhone on device, Android transfer re-verification after these changes, the Android ≤ 512 MiB in-page blob download limit (larger files still use the direct link that Android's download component rejects at the TLS handshake), and phone-side CA fingerprint display after a clean profile reinstall.
- **No multi-hour soak / 1,000-concurrent-client run**; the new deadline and reconciliation paths were exercised by the test suite but not under sustained load.
- **Reconciliation staleness is bounded, not zero**: `committedBytes` can lag external deletions by up to the 60 s cleanup interval plus one scan; a quota-rejection-triggered async scan closes the gap faster. A pathological one-shot race (async scan reading pre-deletion state and applying after a manual reconcile) is generation-guarded against commits but not against pure external file changes — the test covers it with a bounded retry, and the next timer tick corrects it.
- **Directory-scan cost**: `reconcileQuotaNow` enumerates the upload directory synchronously on the cleanup queue (and on the caller for manual/tests); with tens of thousands of files this adds latency to cleanup ticks, not to request handling. Upload admission itself never blocks on a scan.
- **Chunked/unknown-length bodies** get a fixed 15-minute budget rather than a size-aware one; a deliberately chunked, very slow large body can be cut at 15 min (clients that declare `Content-Length` — including Macdro's own web client — get the size-aware deadline). This is the documented tradeoff of SEC-001.
- **Token-path file routes** (`/s/{token}/f/{uuid}`) intentionally do not require the cookie (capability-token model, audit-verified clean); SEC-002 only closed the bare `/f/` oracle.
- **Notarization/Developer ID** still absent (`spctl` rejects ad-hoc), app icon/legal pages absent — unchanged from the audit's limitations.
- The seven audit findings marked *Verified clean* (invariant matrix §7) were not modified.

## F. Final diff summary

Remediation-scoped changes (uncommitted working tree; user's separate main-window UI work in `Sources/Macdro/` is untouched and preserved):

| File | Change |
|---|---|
| `Sources/MacdroKit/SetupServer.swift` | +4 / −2 — per-channel handler (BUG-001) |
| `Sources/MacdroKit/MacdroLimits.swift` | +61 / −0 — `BodyTimeoutPolicy` + body/lease limits (SEC-001, SEC-003) |
| `Sources/MacdroKit/HTTPServer.swift` | +6 / −1 — `bodyTimeoutPolicy` plumbing (SEC-001) |
| `Sources/MacdroKit/HTTPHandler.swift` | +32 / −7 — arm/cancel body deadline, 408/close paths, cookie-before-lookup (SEC-001, SEC-002) |
| `Sources/MacdroKit/UploadStore.swift` | +62 / −9 — lease hard timeout, generation-guarded quota reconciliation, reserved-prefix neutralization (SEC-003, SEC-004, BUG-002) |
| `Sources/MacdroKit/Resources/Web/app.js` | +8 / −6 — Web-Crypto-only upload IDs, fail-closed guard (SEC-005) |
| **Source total** | **+173 / −25** |
| `Tests/MacdroKitTests/RemediationTests.swift` | new, 1,228 lines / 30 tests |
| `PROJECT_CONTEXT.md` | updated: commands (119 tests), verification-tools count, layout, limits (body deadline, lease hard timeout), state, change log, change map, file tree |
| `MACDRO_REMEDIATION_REPORT.md` | this document (new) |

Verification totals after remediation: `swift build` zero warnings · `swift test` **119/119** · `MacdroSelfTest` **71/71** · `MacdroAudit test` **complete** · `scripts/verify.sh` **passed** (clean zero-warning build + XcodeGen + Xcode Debug). No commits, pushes, tags, releases, signatures, Keychain entries, or firewall rules were created; no secrets or tokens appear in any changed file or report.
