# Macdro context

Read this instead of the tree. Update after architecture/commands/limits/tests change, and after every production TODO step.

## What
macOS 14+ menu-bar LAN transfer: share files/folders to a phone over LAN HTTPS + loopback HTTP; receive uploads; no cloud/account. Swift 5.10, SwiftUI, SwiftNIO/NIOSSL/Logging, zlib, Network. Bundle `com.macdro.app` 0.1.0, `LSUIElement`, universal ad-hoc, not notarized.

## Commands
- `swift build`
- `swift test` (~45 s, 79 tests; SSE ~18 s)
- `swift test --filter HardeningTests|SecurityHardeningTests|RegressionTests`
- `swift run MacdroSelfTest` (71 checks)
- `swift run MacdroAudit test|pre1970|serve <fixtures> <uploads> <port>`
- `CONFIG=debug ./scripts/build-app.sh` -> `dist/Macdro.app` (release default)
- `swift run Macdro`
- `xcodegen generate` -> `Macdro.xcodeproj` (generated, ignored)
- `xcodebuild -project Macdro.xcodeproj -scheme Macdro -configuration Debug -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build`
- `./scripts/verify.sh [--no-clean] [--skip-xcode]` -> zero-warning build, tests, self-test, audit, XcodeGen/Xcode build
- `./scripts/build-release.sh` -> universal `dist/Macdro.app` + `dist/Macdro.dmg` + `.sha256`; honors signing/notary env
- If Xcode reports a missing plugin: `xcodebuild -runFirstLaunch`

CI `.github/workflows/ci.yml`: macOS 15 installs XcodeGen, runs `scripts/verify.sh`, bundles app. `.github/workflows/release.yml`: tag `v*` (or manual tag) verifies, builds the universal DMG, and publishes DMG + SHA-256 to GitHub Releases. `MACDRO_SIGNING_IDENTITY` (default `-`), optional `MACDRO_NOTARY_PROFILE`.

## Layout
- `Sources/Macdro/`: UI. `MacdroApp` status item/popover; `AppModel` servers/session/network; `ContentView`, `CertificateSetupView`, `QRCode`.
- `MacdroKit/HTTPServer`: dual listeners/config; loopback HTTP always, LAN HTTPS unless loopback; ports 8787...8807 or 0.
- `HTTPHandler`: ~1.9k-line routes/transfer; grep paths.
- `UploadStore`: streaming/resumable uploads, quotas, leases, TTL, orphan `.part`, path safety.
- `SessionStore`: 32-byte token, `macdro_session` cookie, ordered files, auth/content generations.
- `TLSIdentity`: CA+leaf, fingerprint, `.mobileconfig`; `~/Library/Application Support/Macdro/Identity`.
- `SetupServer`: temp LAN HTTP trust server, 5 min, no token.
- `Resources/Web/`: embedded client via `Bundle.module`.
- `ManifestService`/`ArchiveService`/`ZipArchive`: SHA-256 manifest, streaming ZIP64, single-flight.
- Helpers: `SharedFileExpander` folders, `RangeRequest`, `NetworkInterfaces` (IPv4 + `ConnectionOption` transport classification), `NetworkPathMonitor` (NWPathMonitor path-change wakeups), `RequestRateLimiter`, `HTTPGuards`, `Checksums`, `DateEpoch`, `FileMetadata`, `MacdroLimits`, `Models`.
- `Sources/MacdroSelfTest`, `Sources/MacdroAudit`, `Tests/MacdroKitTests`.
- `project.yml` XcodeGen app project using local SwiftPM package; `scripts/verify.sh`; `scripts/build-release.sh` universal app/DMG.

## Runtime
- URL `https://<lan-ip>:<lanPort>/s/<token>/`; sets `macdro_session` (`HttpOnly; SameSite=Strict`; `Secure` on TLS). Token paths work without cookie; bare `/api/*` and `/f/*` require it.
- Routes: `GET /health`; `/s/{token}/` UI; `/s/{token}/f/{uuid}`; `/api/{session,manifest,zip,events}`; `GET|PUT|POST /api/clipboard`; `PUT|POST /api/upload`. All also under `/s/{token}/` except `/health`.
- Temporary trust setup binds to the selected `ConnectionOption` address; `NetworkPathMonitor` triggers a 400 ms debounced URL/TLS refresh, with a 5 s polling fallback. Upload query: `name` required; `path` optional; resumable `uploadId/offset/total/complete=1`. `X-Upload-Offset`; completion `X-Checksum-SHA256`; offset/state errors 409.
- Files go to `~/Downloads/Macdro`. LAN URL phone-facing; loopback local. TLS SANs refresh on IP change. `startNewSession` rotates token/cookie and closes SSE.

## Invariants
1. Loopback HTTP only, LAN HTTPS only; remote IPs pass `NetworkInterfaces.isAllowedRemote` (loopback/RFC1918/link-local/ULA).
2. Constant-time token; never in JSON/logs/non-token pages; cookie flags; rotation closes streams.
3. Reject oversized `Content-Length` before buffering (1 MiB non-upload); stream uploads; quotas/TTL in `MacdroLimits`/`UploadStore`; drain rejected bodies bounded.
4. Sanitize controls/path components; block traversal and `.macdro-*.part` impersonation; resolve symlinks inside upload root; clean temp on abort/expiry/startup.
5. `Content-Length` exact incl 0; HEAD no body; ETag `size-epochSeconds`; ranges/HEAD/304 consistent.
6. `Date` -> `UInt64` only via `DateEpoch.seconds`; pre-1970/NaN/far-future clamp.
7. Setup server only CA/trust, auto-stop, no token; refresh SANs on IP change.

## Limits
Non-upload 1 MiB; headers 16 KiB field/32 KiB list/100; read+header timeout 30 s; connections 128/16 per IP; rejected drain 8 MiB; resumable TTL 15 min, cleanup 60 s, tombstones 10 min/4096; resumable 64/8 per client; uploads 32/4 per client; pending 8 MiB; upload write coalescing 4 MiB; file 16 GiB; total 64 GiB; reserved disk 32...512 MiB dynamic; clipboard 1 MiB; SSE 10 s/1 h; manifest 2 workers/5 min/64 MiB; ZIP 5 min/1 build/100k/64 GiB; rates/min ZIP 12, manifest 60, clipboard 60, upload 600.

## State (2026-10-25)
Clean SwiftPM build succeeds with zero compiler warnings; `swift test` 79/79; `MacdroSelfTest` 71/71; `MacdroAudit test` pass; debug app ad-hoc. XcodeGen project generates and `xcodebuild` Debug/Release succeeds; `Macdro_MacdroKit.bundle` is embedded. Release script produces universal `x86_64 arm64` app + verified ad-hoc DMG (`dist/Macdro.dmg`, ~8.0 MB). `Info.plist` local-network text is phone-neutral; unused `_macdro._tcp` Bonjour declaration removed. Stale `.build/.lock` removed after SwiftPM PID 30103/87574 diagnostics. M0.2 fixed the idle-header timeout race: `HTTPHandler.sendRequestTimeout` now closes idle connections instead of emitting an invalid 408 into an idle HTTP pipeline.

Verified: 10 GiB loopback download 1.74 GB/s; 10 GiB upload 225 MB/s with SHA-256; 1,000 sequential abandoned uploads store-level no leak; 100 slowloris sockets bounded/closed; 32 MiB non-upload 413; pre-1970 200; 4 GiB range.

Not verified: multi-hour soak, 1,000 concurrent clients, physical iOS/Android, physical transport switching/sleep-wake, browser upload cancellation/retry on a real phone, Developer ID/notarization (`spctl` rejects ad-hoc).

Repo untracked in parent git; don't commit unless asked. `Macdro-Audit-Report.pdf` is historical Oct 22. No ADB/USB/native Android transport.

## Production plan (2026-10-25)
- Target: public macOS 14+ release distributed as a universal DMG through GitHub Releases; no Mac App Store. Native Mac app + zero-install browser client; wired = USB tethering (iPhone hotspot/Android NCM), wireless = Wi-Fi/LAN. Developer ID/notarization is optional but recommended for Gatekeeper; Sparkle auto-update is optional/deferred. Native iOS/Android apps and raw USB/ADB/MTP/AFC are out of scope.
- M0 Setup & Scaffold: baseline verification, zero-warning build, docs/release checklist, XcodeGen project, verification script, release packaging, acceptance gate. M0.7 complete: full clean `verify.sh`, debug app, and universal release/DMG rerun passed.
- M1 Wireless Send: transport detection/labels, transport-aware setup, network-change observation, wired/wireless chooser UI, web send UX, 16 MiB parallel uploads + server coalescing, acceptance gate. M1.1 complete: `ConnectionOption` classifies USB tethering (iPhone/Android/NCM/RNDIS), Wi-Fi, Ethernet, unknown; labels/priorities/setup URLs tested. M1.2 complete: AppModel tracks connection options and binds temporary setup server to the selected transport address. M1.3 complete: `NWPathMonitor` path changes trigger debounced refresh; 5 s polling remains as an IP-change fallback. M1.4 complete: pairing card shows transport/IP, offers a multi-transport chooser, and shows a connect-network state with retry; trust sheet reports the selected transport. M1.5 complete: web upload rows are created immediately, with progress, cancel, retry, and clear error states; drop/choose file/folder flows remain. M1.6 complete: web client sends 16 MiB chunks with 3 parallel uploads; server coalesces inbound bodies into 4 MiB writes with bounded pending bytes. Regression tests cover 5 MiB coalesced upload and 3 parallel uploads. M1.7 automated acceptance passed: 79/79 tests, 71 self-test checks, audit, zero-warning verify, Xcode Debug, universal release app + DMG; physical iPhone/Android browser validation remains blocked.
- Baseline evidence: clean build zero warnings; tests 67/67 (~37 s); self-test 71/71; audit `test` passes. M0.2 removed the five Swift 6 warnings via `NIOLoopBound`, descriptor-owned `NIOFileHandle`, and synchronous pipeline handler installation; the timeout race is covered by the slowloris regression test. Swift 6.1 CI also required `NIOLoopBound` around upload-completion `ChannelHandlerContext` captures.
- Release blockers: no physical iPhone/Android NCM validation; `Macdro` vs existing `MacDroid` name risk. Ad-hoc GitHub DMG is usable with Gatekeeper override; Developer ID/notary remains a UX blocker for a public release.

## Release checklist
- [ ] Confirm product name/trademark and bundle ID; update display name, copyright, support URL.
- [ ] Optional: Apple Developer ID Application cert + notarytool keychain profile; hardened runtime; `spctl`/`stapler` validation.
- [x] Universal 2 app + DMG scaffold; [x] GitHub Releases workflow with SHA-256; [ ] app icon, Sparkle appcast/signing keys (optional).
- [ ] External security review; clean-install and upgrade tests; privacy/terms/support pages.
- [ ] Physical iPhone hotspot and Android NCM transfer validation; Wi-Fi/USB reconnect and sleep/wake soak.
- [x] CI release job: verify, universal DMG, SHA-256, GitHub Release asset. [ ] Optional notarization in release job.
- [ ] Beta feedback/rollback plan and signed update feed before public launch.

## Change map
Routes/HTTP -> `HTTPIntegrationTests`; uploads/cleanup -> `SecurityHardeningTests`+`HardeningTests`; regressions -> `RegressionTests`; TLS/setup -> `SecurityHardeningTests`; limits -> `MacdroLimits` + tests; UI -> `Sources/Macdro`; web -> `MacdroSelfTest`+`HTTPIntegrationTests`; packaging -> `build-app.sh`.

## Gotchas
`swift test` uses temp dirs/ephemeral ports; don't hardcode. `HTTPHandler` is large: grep route/header. Web assets use `.copy("Resources/Web")`; missing bundle breaks packaging. `dist/Macdro.app` is universal and ad-hoc; `dist/Macdro.dmg` is not notarized. Publish `dist/Macdro.dmg` + `.sha256` as GitHub Release assets; `dist/` stays ignored. Dependencies are pinned (`swift-nio` 2.104.0, `swift-nio-ssl` 2.37.5, `swift-log` 1.6.2; `Package.resolved` holds compatible `swift-collections` 1.2.1/`swift-system` 1.4.0/`swift-atomics` 1.2.0). `SCNetworkServiceCopyAll` needs an `SCPreferences` handle; `build-app.sh` uses the selected Xcode toolchain (do not force CommandLineTools). `scripts/verify.sh` uses `.build/verify-spm` so clean verification does not erase `.build/xcode*`.
