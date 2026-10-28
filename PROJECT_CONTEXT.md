# Macdro context

Read this instead of the tree. Update after architecture/commands/limits/tests change, and after every production TODO step.

## What
Macdro is a local-first macOS menu-bar app for bidirectional file transfer with a phone, tablet, or another computer on the same network. The Mac hosts a loopback HTTP receiver and a LAN HTTPS receiver; the other device uses an embedded, zero-install web client. No cloud, account, Internet service, or native mobile app is required. Bundle `com.macdro.app` 0.1.0/build 1, `LSUIElement`, universal ad-hoc, not notarized.

## Features
**Mac host**
- Menu-bar-only operation (`LSUIElement`, accessory activation policy); status icon reflects starting, ready, sharing, and failed states.
- Add files or folders with the picker or drag-and-drop; recursively expand folders while preserving relative paths; remove individual shares; show name, size, path, and file-type icons.
- QR code for the selected receiver URL; copy link; open the loopback receiver in a browser; open `~/Downloads/Macdro`; start a fresh session; quit.
- Ephemeral sessions: a 32-byte hex path token plus a separate session cookie; **New Session** clears shares and rotates both. Multiple browsers can use the same session within connection limits.
- Multi-interface connection chooser with transport labels (Wi-Fi, Ethernet, USB tethering, unknown), selected IP, no-network state, manual refresh, and automatic refresh on path changes.
- Trust setup: a temporary LAN HTTP server (5 minutes) with QR/link, an iPhone/iPad `.mobileconfig`, a downloadable CA certificate for Android/desktop, and a SHA-256 certificate fingerprint. The setup server binds to the selected transport and serves only trust material.
- LAN HTTPS status, certificate fingerprint, and TLS error display; local HTTP receiver remains available even when LAN HTTPS is unavailable.

**Phone / browser client**
- Live shared-file list over SSE, with 1.5 s polling fallback; file count and total size; per-file download; HTTP Range support (browser-dependent resume); “Download all as ZIP”; SHA-256 manifest.
- Upload files or folder trees with 16 MiB chunks and 3 parallel transfers; immediate rows; byte progress; cancel; retry; automatic retry/backoff and server-offset resume; IndexedDB resume state across reloads.
- Preserve uploaded relative paths; write received files into `~/Downloads/Macdro`; reject oversized files before writing and enforce disk quotas.
- Read the Mac clipboard or send plain text to it (1 MiB limit).
- Multiple browser clients may access the same session; access is capability-based rather than per-device approval.
- Clear connected, session-ended, connection-lost, rate-limited, insufficient-storage, and upload-error states.
- No app install required; works in modern browsers with JavaScript, Fetch, and either SSE or polling. Folder selection depends on browser `webkitdirectory` support.

**Transfer and security behavior**
- Loopback HTTP only for the Mac-local browser; LAN traffic is HTTPS with a locally generated CA and leaf certificate (TLS 1.2+).
- Resumable uploads with 15-minute idle TTL, completed-upload tombstones, per-client/global caps, server-computed SHA-256 upload checksums, and atomic finalization.
- Streaming ZIP64 archives and cacheable SHA-256 manifests, with single-flight generation and rate limits.
- Remote-address allowlist for loopback, RFC1918, link-local, and ULA addresses; path traversal, symlink escape, control-character, and partial-file impersonation defenses.
- Clipboard, upload, manifest, and ZIP rate limits; connection caps per IP and globally; rejected-body draining; bounded headers and non-upload bodies.

**Not included**
- No native iOS/iPadOS/Android app, App Store build, Windows/Linux host, cloud relay, account system, telemetry, Bonjour/mDNS discovery, Sparkle updater, app icon, or Developer ID/notarization yet.
- The private repo has no LICENSE, privacy policy, or support page yet.
- No ADB, raw USB, MTP, AFC, Bluetooth, or AirDrop transport. Android USB tethering requires NCM; RNDIS is not supported by macOS.
- No per-device pairing list or individual device revocation; rotating the session invalidates every client.

## Commands
- `swift build`
- `swift test` (~47 s, 80 tests; SSE ~18 s)
- `swift test --filter HardeningTests|SecurityHardeningTests|RegressionTests`
- `swift run MacdroSelfTest` (71 checks)
- `swift run MacdroAudit test|pre1970|serve <fixtures> <uploads> <port>`
- `CONFIG=debug ./scripts/build-app.sh` -> `dist/Macdro.app` (release default)
- `swift run Macdro`
- `xcodegen generate` -> `Macdro.xcodeproj` (generated, ignored)
- `xcodebuild -project Macdro.xcodeproj -scheme Macdro -configuration Debug -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build`
- `./scripts/verify.sh [--no-clean] [--skip-xcode]` -> zero-warning build, tests, self-test, audit, XcodeGen/Xcode build
- `./scripts/build-release.sh` -> universal `dist/Macdro.app` + `dist/Macdro.dmg` + `.sha256`; honors signing/notary env
- `gh release view v0.1.0 -R Goutham011/Macdro`; tag push `v*` runs `.github/workflows/release.yml`
- If Xcode reports a missing plugin: `xcodebuild -runFirstLaunch`

CI `.github/workflows/ci.yml`: macOS 15 installs XcodeGen, runs `scripts/verify.sh`, bundles app. `.github/workflows/release.yml`: tag `v*` (or manual tag) verifies, builds the universal DMG, and publishes DMG + SHA-256 to GitHub Releases. `MACDRO_SIGNING_IDENTITY` (default `-`), optional `MACDRO_NOTARY_PROFILE`.

## Technology and dependencies
**Language and build**
- Swift tools 5.10 package; Xcode project Swift 5 language mode; deployment target macOS 14.0. Builds with Swift 6.1 in CI and Swift 6.4 locally without warnings. Other languages: JavaScript/HTML/CSS, Bash, YAML, XML/plist.
- SwiftPM for library/executables/tests; XcodeGen + `xcodebuild` for the `.app`; `swift build`, `swift test`, `swift run` for development.
- XcodeGen 2.46 used locally with Xcode 27.1/Swift 6.4 (Homebrew install in CI); generated `Macdro.xcodeproj` is intentionally not committed. Xcode 16+ is required for the generated project format; CI runs `macos-15` with Swift 6.1.
- Release app is Universal 2 (`arm64` + `x86_64`). `scripts/build-release.sh` uses `xcodebuild`, `ditto`, `codesign`, `lipo`, `hdiutil`, `shasum`; optional `xcrun notarytool`/`stapler`.
- `scripts/verify.sh` runs a warning-as-failure build, XCTest, self-test, audit, XcodeGen, and an Xcode build.
- GitHub Actions handles CI and tag-driven Release publishing; `gh`/`GH_TOKEN` are used by the Release workflow.

**Swift packages**
| Dependency | Pin | Used for |
|---|---|---|
| `swift-nio` | 2.104.0 | `NIOCore`, `NIOPosix`, `NIOHTTP1`; event loops, TCP servers, HTTP pipeline |
| `swift-nio-ssl` | 2.37.5 | `NIOSSL`; TLS server and certificate loading |
| `swift-log` | 1.6.2 | `Logging`; server/setup logs |
| `swift-atomics` | 1.2.0 (transitive) | NIO concurrency primitives |
| `swift-collections` | 1.2.1 (transitive) | NIO collections |
| `swift-system` | 1.4.0 (transitive) | NIO file-system primitives |

**Apple frameworks and system libraries**
`SwiftUI`, `AppKit`, `Combine`, `Foundation`, `Network`, `SystemConfiguration`, `CryptoKit` (SHA-256), `UniformTypeIdentifiers`, `CoreImage`/`CoreImage.CIFilterBuiltins` (QR), `Darwin` (POSIX), and system `zlib` (ZIP streaming/CRC32).
Runtime certificate generation invokes `/usr/bin/openssl` with `OPENSSL_CONF=/etc/ssl/openssl.cnf`; OpenSSL is not bundled. No Keychain, server-side database, or third-party frontend framework is used.

**Web client**
Vanilla HTML/CSS/JavaScript served from `Macdro_MacdroKit.bundle`; uses Fetch, EventSource/SSE with polling fallback, XMLHttpRequest upload progress, IndexedDB (`macdro-uploads`), Web Crypto (`randomUUID`/`getRandomValues` with fallback), and the Clipboard API with a legacy fallback. No npm, bundler, or external CDN.

**Verification tools**
XCTest for 80 tests; `MacdroSelfTest` (71 assertions) and `MacdroAudit` (`test`, `pre1970`, `serve`) are separate executables that exercise the running server, raw HTTP, TLS, ranges, uploads, quotas, and limits. They are not part of the shipping app bundle.

## Platforms and compatibility
| Surface | Requirement / behavior |
|---|---|
| Mac host | macOS 14 or later; Intel or Apple Silicon; universal DMG; menu-bar accessory app; no Dock icon; App Sandbox not configured; no Windows/Linux host |
| Phone/tablet | Modern browser; iPhone/iPad Safari with the Macdro CA profile installed and full trust enabled; Android Chrome with the CA installed as a user certificate |
| Other computers | Modern browser on the same allowed private/link-local network; no Mac app required; Windows/Linux clients use the browser |
| Wireless | Same Wi-Fi/LAN; Ethernet also supported |
| Wired | iPhone Personal Hotspot over USB; Android USB tethering via NCM; Android RNDIS is unsupported by macOS |
| Address family | IPv4 for interface discovery and QR URLs; remote allowlist also accepts IPv6 loopback, IPv6 link-local, and ULA |
| Ports | Loopback and LAN listeners prefer 8787, try through 8807, or use an ephemeral port (`0`); LAN binds `0.0.0.0` by default; setup uses the selected IP and an ephemeral port |
| Trust | Main LAN receiver is HTTPS/TLS 1.2+ with a local CA (RSA 2048, 10-year CA, 365-day leaf); setup server is temporary plain HTTP for certificate delivery; `NSLocalNetworkUsageDescription` is present and no Bonjour service is declared |
| TLS SANs | Leaf covers `localhost`, `127.0.0.1`, and every discovered IPv4 address; it is regenerated when the address set changes, not narrowed to the selected transport |
| Distribution | Private GitHub Releases DMG + SHA-256; ad-hoc signed; Gatekeeper override needed until Developer ID/notarization is added |
| Data path | Received files: `~/Downloads/Macdro`; identity: `~/Library/Application Support/Macdro/Identity` |

## Layout
- `README.md`: public-facing overview, feature tour, architecture diagram, engineering highlights, quick start, and roadmap.
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

## File tree
Repository files (generated `.build/`, `dist/`, `Macdro.xcodeproj/`, and `Macdro-Audit-Report.pdf` are excluded):
```
.
├── .github/
│   ├── assets/
│   │   └── macdro-banner.svg
│   └── workflows/
│       ├── ci.yml
│       └── release.yml
├── .gitignore
├── AGENTS.md
├── App/
│   └── Info.plist
├── PROJECT_CONTEXT.md
├── README.md
├── Package.resolved
├── Package.swift
├── Sources/
│   ├── Macdro/
│   │   ├── AppModel.swift
│   │   ├── CertificateSetupView.swift
│   │   ├── ContentView.swift
│   │   ├── MacdroApp.swift
│   │   └── QRCode.swift
│   ├── MacdroAudit/
│   │   └── main.swift
│   ├── MacdroKit/
│   │   ├── ArchiveService.swift
│   │   ├── Checksums.swift
│   │   ├── DateEpoch.swift
│   │   ├── FileMetadata.swift
│   │   ├── HTTPGuards.swift
│   │   ├── HTTPHandler.swift
│   │   ├── HTTPServer.swift
│   │   ├── MacdroLimits.swift
│   │   ├── ManifestService.swift
│   │   ├── Models.swift
│   │   ├── NetworkInterfaces.swift
│   │   ├── NetworkPathMonitor.swift
│   │   ├── RangeRequest.swift
│   │   ├── RequestRateLimiter.swift
│   │   ├── Resources/Web/
│   │   │   ├── app.js
│   │   │   ├── index.html
│   │   │   └── styles.css
│   │   ├── SessionStore.swift
│   │   ├── SetupServer.swift
│   │   ├── SharedFileExpander.swift
│   │   ├── TLSIdentity.swift
│   │   ├── UploadStore.swift
│   │   └── ZipArchive.swift
│   └── MacdroSelfTest/
│       └── main.swift
├── Tests/MacdroKitTests/
│   ├── HTTPIntegrationTests.swift
│   ├── HardeningTests.swift
│   ├── NetworkInterfacesTests.swift
│   ├── RangeRequestTests.swift
│   ├── RegressionTests.swift
│   ├── SecurityHardeningTests.swift
│   └── SessionStoreTests.swift
├── project.yml
└── scripts/
    ├── build-app.sh
    ├── build-release.sh
    └── verify.sh
```
`dist/Macdro.app` and `dist/Macdro.dmg` are generated release artifacts; `.build/` is SwiftPM state; `Macdro.xcodeproj` is generated by XcodeGen. `Macdro-Audit-Report.pdf` is untracked historical audit material.

## Runtime
- URL `https://<lan-ip>:<lanPort>/s/<token>/`; sets `macdro_session` (`HttpOnly; SameSite=Strict`; `Secure` on TLS). Token paths work without cookie; bare `/api/*` and `/f/*` require it.
- Routes: `GET /health`; `/s/{token}/` UI; `/s/{token}/f/{uuid}`; `/api/{session,manifest,zip,events}`; `GET|PUT|POST /api/clipboard`; `PUT|POST /api/upload`. All also under `/s/{token}/` except `/health`.
- Temporary trust setup binds to the selected `ConnectionOption` address; `NetworkPathMonitor` triggers a 400 ms debounced URL/TLS refresh, with a 5 s polling fallback. Upload query: `name` required; `path` optional; resumable `uploadId/offset/total/complete=1`. `X-Upload-Offset`; completion `X-Checksum-SHA256`; offset/state errors 409.
- Files go to `~/Downloads/Macdro`. LAN URL phone-facing; loopback local. TLS SANs refresh on IP change. `startNewSession` rotates token/cookie and closes SSE.

## Data and state
- In-memory only: shared-file list, order, session token, session cookie, auth/content generations, SSE subscribers, upload leases, and rate-limit windows. Quitting the app or starting a new session loses the share list and old links.
- Received files: `~/Downloads/Macdro`, with nested relative paths preserved. Uploads use `.macdro-*.part` temporary files, atomic renames, quotas, and cleanup of expired/orphaned state.
- TLS identity: `~/Library/Application Support/Macdro/Identity` contains `ca.crt`, `ca.key`, `leaf.crt`, `leaf.key`, and `leaf.sans`. Directory mode is `0700`; private keys/certificates are `0600`. The CA private key is not stored in Keychain. The displayed fingerprint is SHA-256 over the leaf DER.
- Browser state: IndexedDB database `macdro-uploads` stores upload resume IDs/offsets; no account data is stored.
- Clipboard: reads/writes the macOS general pasteboard.
- No app/server database, analytics, telemetry, cloud storage, or persistent share history (browser IndexedDB is only for upload resume state).

## Concepts and design
- Local-first client/server, with strict loopback HTTP versus LAN HTTPS separation and no public relay.
- SwiftNIO event-loop networking plus `NIOThreadPool` for blocking file hashing/archive work; immutable/sendable request state and `NIOLoopBound` where NIO callbacks cross isolation.
- AppKit lifecycle (`NSStatusItem`/`NSPopover`) hosting a SwiftUI `AppModel` (`@MainActor`, `ObservableObject`); lock-protected `SessionStore`, `UploadStore`, and rate-limit state for shared access.
- Streaming and backpressure: bounded body buffering, coalesced 4 MiB upload writes, paused channel reads, and 8 MiB rejected-body drain.
- Resumable upload protocol: client-supplied upload ID, explicit offsets, `409` with `X-Upload-Offset`, server-side leases/tombstones, and atomic completion.
- HTTP correctness: exact `Content-Length`, HEAD without body, ETag `size-epoch`, conditional requests, byte ranges, and consistent 304/206/416 responses.
- Local CA trust: OpenSSL-generated CA + leaf, CA delivered via `.mobileconfig`/PEM, SHA-256 fingerprint verification, and TLS 1.2+ on the LAN listener.
- Capability-style session auth: unguessable token in the URL path, constant-time comparison, `HttpOnly`/`SameSite=Strict` cookie (plus `Secure` on TLS), auth rotations, and no token in JSON or logs. Anyone with the link/cookie on an allowed network can transfer; there is no per-device approval.
- Content integrity and archive generation: SHA-256 manifests, server-computed SHA-256 upload checksums, ZIP64 streaming with CRC32, single-flight caches, and TTLs.
- Defense-in-depth HTTP headers: CSP, `X-Content-Type-Options: nosniff`, frame denial, and no-referrer policy.
- Live UI updates via SSE (`text/event-stream`), with polling fallback when EventSource is unavailable.
- Resource governance: per-IP/global connection gates, per-route rate limits, disk-reservation checks, quotas, and TTL cleanup.
- Filesystem safety: control/Unicode normalization, traversal checks, symlink resolution inside the upload root, and rejection of temporary-file impersonation.
- Zero-install browser client: embedded HTML/CSS/JS, no build pipeline, responsive layout, and graceful degradation when optional browser APIs are missing.

## Invariants
1. Loopback HTTP only, LAN HTTPS only; remote IPs pass `NetworkInterfaces.isAllowedRemote` (loopback/RFC1918/link-local/ULA).
2. Constant-time token; never in JSON/logs/non-token pages; cookie flags; rotation closes streams.
3. Reject oversized `Content-Length` before buffering (1 MiB non-upload); stream uploads; quotas/TTL in `MacdroLimits`/`UploadStore`; drain rejected bodies bounded.
4. Sanitize controls/path components; block traversal and `.macdro-*.part` impersonation; resolve symlinks inside upload root; clean temp on abort/expiry/startup.
5. `Content-Length` exact incl 0; HEAD no body; ETag `size-epochSeconds`; ranges/HEAD/304 consistent.
6. `Date` -> `UInt64` only via `DateEpoch.seconds`; pre-1970/NaN/far-future clamp.
7. Setup server only CA/trust, auto-stop, no token; refresh SANs on IP change.
8. Never pass `IOData.fileRegion` through NIOSSL. TLS file/ZIP bodies must be streamed as ByteBuffers (256 KiB chunks); loopback may use `sendfile`.

## Limits
Non-upload 1 MiB; headers 16 KiB field/32 KiB list/100; read+header timeout 30 s; connections 128/16 per IP; rejected drain 8 MiB; resumable TTL 15 min, cleanup 60 s, tombstones 10 min/4096; resumable 64/8 per client; uploads 32/4 per client; pending 8 MiB; upload write coalescing 4 MiB; file 16 GiB; total 64 GiB; reserved disk 32...512 MiB dynamic; clipboard 1 MiB; SSE 10 s/1 h; manifest 2 workers/5 min/64 MiB; ZIP 5 min/1 build/100k/64 GiB; rates/min ZIP 12, manifest 60, clipboard 60, upload 600.

## State (2026-10-26)
Clean SwiftPM build succeeds with zero compiler warnings; `swift test` 80/80; `MacdroSelfTest` 71/71; `MacdroAudit test` pass; debug app ad-hoc. XcodeGen project generates and `xcodebuild` Debug/Release succeeds; `Macdro_MacdroKit.bundle` is embedded. Release script produces universal `x86_64 arm64` app + verified ad-hoc DMG (`dist/Macdro.dmg`, ~8.0 MB). Private GitHub release `v0.1.0` published at https://github.com/Goutham011/Macdro/releases/tag/v0.1.0 with `Macdro.dmg` (8,131,270 bytes) + SHA-256; downloaded asset re-verified universal, version 0.1.0, web assets present, ad-hoc signature valid. `Info.plist` local-network text is phone-neutral; unused `_macdro._tcp` Bonjour declaration removed. Stale `.build/.lock` removed after SwiftPM PID 30103/87574 diagnostics. M0.2 fixed the idle-header timeout race: `HTTPHandler.sendRequestTimeout` now closes idle connections instead of emitting an invalid 408 into an idle HTTP pipeline. Post-release fix (2026-10-26) replaced TLS `FileRegion` responses with bounded ByteBuffer streaming; HTTPS file, range, and ZIP downloads now complete without crashing `NIOSSL`.

Verified: 10 GiB loopback download 1.74 GB/s; 10 GiB upload 225 MB/s with SHA-256; 1,000 sequential abandoned uploads store-level no leak; 100 slowloris sockets bounded/closed; 32 MiB non-upload 413; pre-1970 200; 4 GiB range; 2 MiB HTTPS full/range/ZIP download regression.

Not verified: multi-hour soak, 1,000 concurrent clients, physical iOS/Android, physical transport switching/sleep-wake, browser upload cancellation/retry on a real phone, Developer ID/notarization (`spctl` rejects ad-hoc).

Standalone git repo at `Goutham011/Macdro`; `Macdro-Audit-Report.pdf` stays untracked as historical Oct 22. No ADB/USB/native Android transport.

## Change log (2026-10-25)
Incremental changes from the existing codebase; no rewrite. Baseline was 67 tests and five Swift 6 warnings.

**Build, server, and safety**
- Removed the five Swift 6 warnings in `SetupServer`/`HTTPServer`/`HTTPHandler` with event-loop-bound state, synchronous pipeline-handler installation, and descriptor-owned `NIOFileHandle` handling.
- Fixed the idle-header timeout race: `HTTPHandler.sendRequestTimeout` closes idle connections instead of writing an invalid 408 into an idle HTTP pipeline; covered by the slowloris regression test.
- Added `MacdroLimits.uploadCoalesceBytes` (4 MiB) and coalesced upload-body writes to avoid tiny writes while retaining the 8 MiB pending limit.
- Fixed the Swift 6.1 CI sendability failure by using `NIOLoopBound` for `ChannelHandlerContext` in upload completion callbacks; local and CI verification now report zero warnings.

**Transport and reconnect UX**
- `NetworkInterfaces` gained `ConnectionOption` (`usbTethering`, `wifi`, `ethernet`, `unknown`) with labels, details, setup URLs, priorities, classification, and `preferredConnection`; covered by 10 new tests.
- Added `NetworkPathMonitor` (`NWPathMonitor`) and wired `AppModel` to refresh connection options and URLs on path changes, with a 400 ms debounce and 5 s polling fallback.
- Setup-server binding can now target the selected transport address; `AppModel` tracks the selected option, refreshes the URL/TLS state, and exposes a transport-aware connection label.
- `ContentView` now shows transport/IP, a multi-transport chooser, and a no-network state with retry; `CertificateSetupView` reports the selected transport and offers retry.

**Web transfer UX**
- Web upload rows appear immediately and show progress, cancel, retry, and explicit error states; file/folder drag-and-drop remains supported.
- Web client now sends 16 MiB chunks with 3 parallel uploads and schedules task refreshes without over-fetching.
- Added regression coverage for a 5 MiB upload using coalesced body writes and three concurrent uploads.

**App project and packaging**
- Added `project.yml` for XcodeGen (Xcode 16-compatible project, `LSUIElement`, bundle `com.macdro.app` 0.1.0); `Macdro.xcodeproj` remains generated/ignored.
- Embedded the `Macdro_MacdroKit` resource bundle correctly and made `build-app.sh` use the selected Xcode toolchain.
- Updated `Info.plist` local-network text to be phone-neutral and removed the unused `_macdro._tcp` Bonjour declaration.
- Added `scripts/verify.sh` (clean zero-warning build, tests, self-test, audit, XcodeGen/Xcode build) and `scripts/build-release.sh` (universal app/DMG, SHA-256, optional signing/notarization).
- Pinned `swift-nio` 2.104.0, `swift-nio-ssl` 2.37.5, and `swift-log` 1.6.2, with compatible transitive pins in `Package.resolved`, so CI on macOS 15/Swift 6.1 no longer pulls tools-6.2/6.4-only releases.
- Added `.github/workflows/ci.yml` (macOS 15 verify + app bundle) and `.github/workflows/release.yml` (tag/manual universal DMG + SHA-256 + GitHub Release).

**Distribution**
- Moved the standalone project into the private repo `Goutham011/Macdro`; no App Store or committed DMG binary.
- Published tag/release `v0.1.0` with `Macdro.dmg` (8,131,270 bytes) and `Macdro.dmg.sha256`; downloaded asset re-verified as universal `arm64/x86_64`, version 0.1.0, with web assets and a valid ad-hoc signature.
- CI and Release workflows both pass on GitHub; future `v*` tags publish new assets automatically.

**Tests and docs**
- Test suite grew from 67 to 80: 10 `NetworkInterfacesTests`, two upload regression tests, and a TLS full/range/ZIP download regression; self-test remains 71 checks.
- `PROJECT_CONTEXT.md` now records the GitHub-release model, feature inventory, technology/dependency stack, platform matrix, data/state model, concepts, full file tree, release asset, package pins, and Swift 6.1 constraints.
- Added `README.md` and `.github/assets/macdro-banner.svg` as a recruiter-facing project overview with a custom hero banner.

**Post-release fix (2026-10-26)**
- Fixed mobile/LAN HTTPS downloads that appeared to pause: `serveFile` and `serveTemporaryArchive` sent `FileRegion` to `HTTPResponseEncoder` and then `NIOSSLHandler`, which only accepts `ByteBuffer`; the server trapped in `NIOAny.forceAsByteBuffer` and the browser stalled. Loopback HTTP keeps `sendfile`; TLS now streams 256 KiB ByteBuffers with write-promise backpressure and closes the file handle on success/failure.
- Added `SecurityHardeningTests.testLANHTTPSFileDownloadReturnsFullBody`: 2 MiB+ full download, byte-range 206, and ZIP over TLS. Full suite: 80/80.
- Fixed the iOS trust profile: `.mobileconfig` certificate payloads were PEM bytes; `com.apple.security.root` requires DER. The profile now uses the CA certificate DER via `NIOSSLCertificate.toDERBytes()`, and the certificate test parses the generated plist and compares the installed payload with the CA DER.
- Remaining validation: repeat the physical mobile download after relaunching the fixed build and reinstalling the regenerated trust profile.

**Not changed / still open**
- No native iOS/Android app, App Store listing, ADB, raw USB/MTP/AFC, or Sparkle update feed.
- No Developer ID/notarization yet, so the ad-hoc DMG still needs Gatekeeper approval; app icon and support/legal pages are absent.
- Physical iPhone-hotspot and Android-NCM browser transfers, transport switching, sleep/wake, and physical cancel/retry still need validation.
- `Macdro` versus existing `MacDroid` naming/trademark clearance remains unresolved.

## Production plan (2026-10-25)
- Target: macOS 14+ release distributed as a universal DMG through private GitHub Releases at `Goutham011/Macdro`; no Mac App Store. Native Mac app + zero-install browser client; wired = USB tethering (iPhone hotspot/Android NCM), wireless = Wi-Fi/LAN. Developer ID/notarization is optional but recommended for Gatekeeper; Sparkle auto-update is optional/deferred. Native iOS/Android apps and raw USB/ADB/MTP/AFC are out of scope.
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
- [x] CI release job: verify, universal DMG, SHA-256, GitHub Release asset. [x] Private GitHub repo + `v0.1.0` release published. [ ] Optional notarization in release job.
- [ ] Beta feedback/rollback plan and signed update feed before public launch.

## Change map
Routes/HTTP -> `HTTPIntegrationTests`; uploads/cleanup -> `SecurityHardeningTests`+`HardeningTests`; regressions -> `RegressionTests`; transport selection -> `NetworkInterfacesTests`; TLS/setup -> `SecurityHardeningTests`; limits -> `MacdroLimits` + tests; UI -> `Sources/Macdro`; web -> `MacdroSelfTest`+`HTTPIntegrationTests`+`RegressionTests`; packaging -> `build-app.sh`.

## Gotchas
`swift test` uses temp dirs/ephemeral ports; don't hardcode. `HTTPHandler` is large: grep route/header. Web assets use `.copy("Resources/Web")`; missing bundle breaks packaging. `dist/Macdro.app` is universal and ad-hoc; `dist/Macdro.dmg` is not notarized. GitHub source is a standalone repo at `Goutham011/Macdro`; the parent home git repo must not be used. Publish `dist/Macdro.dmg` + `.sha256` as GitHub Release assets; `dist/` stays ignored. Dependencies are pinned (`swift-nio` 2.104.0, `swift-nio-ssl` 2.37.5, `swift-log` 1.6.2; `Package.resolved` holds compatible `swift-collections` 1.2.1/`swift-system` 1.4.0/`swift-atomics` 1.2.0). `SCNetworkServiceCopyAll` needs an `SCPreferences` handle; `build-app.sh` uses the selected Xcode toolchain (do not force CommandLineTools). `scripts/verify.sh` uses `.build/verify-spm` so clean verification does not erase `.build/xcode*`. Do not use `IOData.fileRegion` on the TLS listener; NIOSSL accepts only `ByteBuffer`, so stream TLS file/ZIP bodies in chunks. For iOS configuration profiles, `PayloadContent` for `com.apple.security.root` must be DER certificate bytes, not PEM.
