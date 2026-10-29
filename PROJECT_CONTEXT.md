# Macdro context

Read this instead of the tree. Update after architecture/commands/limits/tests change, and after every production TODO step.

## What
Macdro is a local-first macOS menu-bar app for bidirectional file transfer with a phone, tablet, or another computer on the same network. The Mac hosts a loopback HTTP receiver and a LAN HTTPS receiver (plain HTTP when the opt-in Easy mode setting is on); the other device uses an embedded, zero-install web client. No cloud, account, Internet service, or native mobile app is required. Bundle `com.macdro.app` 0.1.0/build 1, `LSUIElement`, universal ad-hoc, not notarized.

## Features
**Mac host**
- Menu-bar-only operation (`LSUIElement`, accessory activation policy); status icon reflects starting, ready, sharing, and failed states.
- Add files or folders with the picker or drag-and-drop; recursively expand folders while preserving relative paths; remove individual shares; show name, size, path, and file-type icons.
- QR code for the selected receiver URL; copy link; open the loopback receiver in a browser; open `~/Downloads/Macdro`; start a fresh session; quit.
- Ephemeral sessions: a 32-byte hex path token plus a separate session cookie; **New Session** clears shares and rotates both. Multiple browsers can use the same session within connection limits.
- Multi-interface connection chooser with transport labels (Wi-Fi, Ethernet, USB tethering, unknown), selected IP, no-network state, manual refresh, and automatic refresh on path changes.
- Trust setup: a temporary LAN HTTP server (5 minutes) with QR/link, an iPhone/iPad `.mobileconfig`, a DER CA certificate (`/ca.der`) for Android plus PEM (`/ca.crt`) for desktop, and two SHA-256 fingerprints: the **CA fingerprint** (what a phone displays after install) and the server certificate fingerprint. The setup server binds to the selected transport and serves only trust material. Hidden when Easy mode is on (no certificate is needed).
- LAN HTTPS status, certificate fingerprint, and TLS error display; local HTTP receiver remains available even when LAN HTTPS is unavailable.
- **Easy mode** (opt-in, persisted `UserDefaults` key `easyLANMode`, default off): the LAN receiver serves plain HTTP instead of TLS — no certificate to install, no browser interstitial — reachable from a **Settings** window (`SettingsView`/`SettingsWindowController`, AppKit `NSWindowController`, never a SwiftUI `Settings` scene) and a quick **Easy Mode** toggle in the popover menu. Pairing hints, the footer chip, the Trust button, and the receiver footer text adapt to the mode; switching rebinds only the LAN listener (`MacdroServer.setLANTransport`), preserving loopback, token, and upload state.

**Phone / browser client**
- Live shared-file list over SSE, with 1.5 s polling fallback; file count and total size; per-file download; HTTP Range support (browser-dependent resume); “Download all as ZIP”; SHA-256 manifest.
- Upload files or folder trees with 16 MiB chunks and 3 parallel transfers; immediate rows; byte progress; cancel; retry; automatic retry/backoff and server-offset resume; IndexedDB resume state across reloads.
- Preserve uploaded relative paths; write received files into `~/Downloads/Macdro`; reject oversized files before writing and enforce disk quotas.
- Read the Mac clipboard or send plain text to it (1 MiB limit).
- Multiple browser clients may access the same session; access is capability-based rather than per-device approval.
- Clear connected, session-ended, connection-lost, rate-limited, insufficient-storage, and upload-error states.
- No app install required; works in modern browsers with JavaScript, Fetch, and either SSE or polling. Folder selection depends on browser `webkitdirectory` support.

**Transfer and security behavior**
- Loopback HTTP only for the Mac-local browser; LAN traffic is HTTPS with a locally generated CA and leaf certificate (TLS 1.2+), or plain HTTP when Easy mode is explicitly enabled (auth, bounds, rate limits, and RFC1918 checks unchanged; transport confidentiality is the documented tradeoff).
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
- `swift test` (~90 s, 119 tests; SSE ~18 s)
- `swift test --filter HardeningTests|SecurityHardeningTests|RegressionTests|RemediationTests`
- `swift run MacdroSelfTest` (71 checks)
- `swift run MacdroAudit test|pre1970|serve <fixtures> <uploads> <port>`
- `CONFIG=debug ./scripts/build-app.sh` -> `dist/Macdro.app` (release default)
- `swift run Macdro`
- `xcodegen generate` -> `Macdro.xcodeproj` (generated, ignored)
- `xcodebuild -project Macdro.xcodeproj -scheme Macdro -configuration Debug -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build`
- `./scripts/verify.sh [--no-clean] [--skip-xcode]` -> zero-warning build, tests, self-test, audit, XcodeGen/Xcode build
- `./scripts/build-release.sh` -> universal `dist/Macdro.app` + `dist/Macdro.dmg` + `.sha256`; honors signing/notary env
- `gh release view v0.1.1 -R Goutham011/Macdro`; tag push `v*` runs `.github/workflows/release.yml`
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
Vanilla HTML/CSS/JavaScript served from `Macdro_MacdroKit.bundle`; uses Fetch, EventSource/SSE with polling fallback, XMLHttpRequest upload progress, IndexedDB (`macdro-uploads`), Web Crypto (`randomUUID`/`getRandomValues`; upload IDs fail closed when Web Crypto is absent), and the Clipboard API with a legacy fallback. No npm, bundler, or external CDN.

**Verification tools**
XCTest for 119 tests (`RemediationTests` covers the 2026-10-29 audit remediation); `MacdroSelfTest` (71 assertions) and `MacdroAudit` (`test`, `pre1970`, `serve`) are separate executables that exercise the running server, raw HTTP, TLS, ranges, uploads, quotas, and limits. They are not part of the shipping app bundle.

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
| Trust | Main LAN receiver is HTTPS/TLS 1.2+ with a local CA (RSA 2048, 10-year CA, 365-day leaf) unless Easy mode is on (plain HTTP, no identity generated); setup server is temporary plain HTTP for certificate delivery; `NSLocalNetworkUsageDescription` is present and no Bonjour service is declared |
| TLS SANs | Leaf covers `localhost`, `127.0.0.1`, and every discovered IPv4 address; it is regenerated when the address set changes, not narrowed to the selected transport |
| Distribution | Private GitHub Releases DMG + SHA-256; ad-hoc signed; Gatekeeper override needed until Developer ID/notarization is added |
| Data path | Received files: `~/Downloads/Macdro`; identity: `~/Library/Application Support/Macdro/Identity` |

## Layout
- `README.md`: public-facing overview, feature tour, architecture diagram, engineering highlights, quick start, and roadmap.
- `Sources/Macdro/`: UI. `main.swift` AppKit entry (`MainActor.assumeIsolated` + `NSApplication.run`); `AppDelegate` status item/popover, first-run welcome window, main receiver window shown on every launch; `AppModel` servers/session/network/easy mode; `ContentView`, `CertificateSetupView`, `SettingsView` (+ `SettingsWindowController`), `WelcomeView`, `MainWindowController`, `QRCode`.
- `MacdroKit/HTTPServer`: dual listeners/config; loopback HTTP always, LAN HTTPS unless loopback **or Easy mode** (`lanUsesTLS`, `lanIsSecure`, `setLANTransport` rebinds only the LAN channel); ports 8787...8807 or 0.
- `HTTPHandler`: ~1.9k-line routes/transfer; size-aware absolute body deadline (`BodyTimeoutPolicy`), auth-before-lookup on bare `/f/*`; grep paths.
- `UploadStore`: streaming/resumable uploads, quotas with directory-scan reconciliation (`reconcileQuotaNow`), leases with an 8 h hard timeout, TTL, orphan `.part`, reserved-pattern neutralization in every path component.
- `SessionStore`: 32-byte token, `macdro_session` cookie, ordered files, auth/content generations.
- `TLSIdentity`: CA+leaf, leaf and CA fingerprints, SAN set (localhost/IPv4/mDNS), DER `.mobileconfig`; `~/Library/Application Support/Macdro/Identity`.
- `SetupServer`: temp LAN HTTP trust server, 5 min, no token; one handler per channel (independent responses).
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
├── MACDRO_EXHAUSTIVE_AUDIT_REPORT.md
├── MACDRO_REMEDIATION_REPORT.md
├── PROJECT_CONTEXT.md
├── README.md
├── Package.resolved
├── Package.swift
├── Sources/
│   ├── Macdro/
│   │   ├── AppDelegate.swift
│   │   ├── AppModel.swift
│   │   ├── CertificateSetupView.swift
│   │   ├── ContentView.swift
│   │   ├── MainWindowController.swift
│   │   ├── QRCode.swift
│   │   ├── SettingsView.swift
│   │   ├── WelcomeView.swift
│   │   └── main.swift
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
│   ├── LANTransportTests.swift
│   ├── HardeningTests.swift
│   ├── NetworkInterfacesTests.swift
│   ├── RangeRequestTests.swift
│   ├── RegressionTests.swift
│   ├── RemediationTests.swift
│   ├── SecurityHardeningTests.swift
│   ├── SessionStoreTests.swift
│   └── TLSStreamingBenchmarkTests.swift
├── project.yml
└── scripts/
    ├── build-app.sh
    ├── build-release.sh
    └── verify.sh
```
`dist/Macdro.app` and `dist/Macdro.dmg` are generated release artifacts; `.build/` is SwiftPM state; `Macdro.xcodeproj` is generated by XcodeGen. `Macdro-Audit-Report.pdf` is untracked historical audit material; `MACDRO_EXHAUSTIVE_AUDIT_REPORT.md` records the 2026-10-29 seven-finding audit and `MACDRO_REMEDIATION_REPORT.md` its remediation.

## Runtime
- URL `https://<lan-ip>:<lanPort>/s/<token>/`; sets `macdro_session` (`HttpOnly; SameSite=Strict`; `Secure` on TLS). Token paths work without cookie; bare `/api/*` and `/f/*` require it.
- Routes: `GET /health`; `/s/{token}/` UI; `/s/{token}/f/{uuid}`; `/api/{session,manifest,zip,events}`; `GET|PUT|POST /api/clipboard`; `PUT|POST /api/upload`. All also under `/s/{token}/` except `/health`.
- Temporary trust setup binds to the selected `ConnectionOption` address; `NetworkPathMonitor` triggers a 400 ms debounced URL/TLS refresh, with a 5 s polling fallback. Upload query: `name` required; `path` optional; resumable `uploadId/offset/total/complete=1`. `X-Upload-Offset`; completion `X-Checksum-SHA256`; offset/state errors 409.
- Files go to `~/Downloads/Macdro`. LAN URL phone-facing; loopback local. TLS SANs refresh on IP change. `startNewSession` rotates token/cookie and closes SSE.

## Data and state
- In-memory only: shared-file list, order, session token, session cookie, auth/content generations, SSE subscribers, upload leases, and rate-limit windows. Quitting the app or starting a new session loses the share list and old links.
- Received files: `~/Downloads/Macdro`, with nested relative paths preserved. Uploads use `.macdro-*.part` temporary files, atomic renames, quotas, and cleanup of expired/orphaned state.
- TLS identity: `~/Library/Application Support/Macdro/Identity` contains `ca.crt`, `ca.key`, `leaf.crt`, `leaf.key`, and `leaf.sans`. Directory mode is `0700`; private keys/certificates are `0600`. The CA private key is not stored in Keychain. Two fingerprints are computed as SHA-256 over DER: the **CA fingerprint** (shown on the phone after install, and in the app/setup page) and the leaf/server fingerprint.
- Browser state: IndexedDB database `macdro-uploads` stores upload resume IDs/offsets; no account data is stored.
- Clipboard: reads/writes the macOS general pasteboard.
- No app/server database, analytics, telemetry, cloud storage, or persistent share history (browser IndexedDB is only for upload resume state).

## Concepts and design
- Local-first client/server, with strict loopback HTTP versus LAN HTTPS separation (LAN plain HTTP only via the explicit persisted Easy mode setting) and no public relay.
- SwiftNIO event-loop networking plus `NIOThreadPool` for blocking file hashing/archive work; immutable/sendable request state and `NIOLoopBound` where NIO callbacks cross isolation.
- AppKit lifecycle (`NSStatusItem`/`NSPopover`) hosting a SwiftUI `AppModel` (`@MainActor`, `ObservableObject`); lock-protected `SessionStore`, `UploadStore`, and rate-limit state for shared access.
- Streaming and backpressure: bounded body buffering, coalesced 4 MiB upload writes, paused channel reads, and 8 MiB rejected-body drain.
- Resumable upload protocol: client-supplied upload ID, explicit offsets, `409` with `X-Upload-Offset`, server-side leases/tombstones, and atomic completion.
- HTTP correctness: exact `Content-Length`, HEAD without body, ETag `size-epoch`, conditional requests, byte ranges, and consistent 304/206/416 responses.
- Local CA trust: OpenSSL-generated CA + leaf, CA delivered as DER in `.mobileconfig` (iOS) and `/ca.der` (Android) plus PEM at `/ca.crt` (desktop), CA fingerprint verification against what the phone displays, and TLS 1.2+ on the LAN listener.
- Capability-style session auth: unguessable token in the URL path, constant-time comparison, `HttpOnly`/`SameSite=Strict` cookie (plus `Secure` on TLS), auth rotations, and no token in JSON or logs. Anyone with the link/cookie on an allowed network can transfer; there is no per-device approval.
- Content integrity and archive generation: SHA-256 manifests, server-computed SHA-256 upload checksums, ZIP64 streaming with CRC32, single-flight caches, and TTLs.
- Defense-in-depth HTTP headers: CSP, `X-Content-Type-Options: nosniff`, frame denial, and no-referrer policy.
- Live UI updates via SSE (`text/event-stream`), with polling fallback when EventSource is unavailable.
- Resource governance: per-IP/global connection gates, per-route rate limits, disk-reservation checks, quotas, and TTL cleanup.
- Filesystem safety: control/Unicode normalization, traversal checks, symlink resolution inside the upload root, and rejection of temporary-file impersonation.
- Zero-install browser client: embedded HTML/CSS/JS, no build pipeline, responsive layout, and graceful degradation when optional browser APIs are missing.

## Invariants
1. Loopback HTTP only; LAN HTTPS only, except plain HTTP when the persisted Easy mode setting is explicitly on (never silently degraded); remote IPs pass `NetworkInterfaces.isAllowedRemote` (loopback/RFC1918/link-local/ULA).
2. Constant-time token; never in JSON/logs/non-token pages; cookie flags; rotation closes streams.
3. Reject oversized `Content-Length` before buffering (1 MiB non-upload); stream uploads; quotas/TTL in `MacdroLimits`/`UploadStore`; drain rejected bodies bounded.
4. Sanitize controls/path components; block traversal and `.macdro-*.part` impersonation; resolve symlinks inside upload root; clean temp on abort/expiry/startup.
5. `Content-Length` exact incl 0; HEAD no body; ETag `size-epochSeconds`; ranges/HEAD/304 consistent.
6. `Date` -> `UInt64` only via `DateEpoch.seconds`; pre-1970/NaN/far-future clamp.
7. Setup server only CA/trust, auto-stop, no token; refresh SANs on IP change.
8. Never pass `IOData.fileRegion` through NIOSSL. TLS file/ZIP bodies must be streamed as ByteBuffers (256 KiB chunks); loopback may use `sendfile`.
9. Trust material is never degraded silently: `.mobileconfig` payload is DER (never PEM), setup routes return 500 instead of an empty certificate, SAN entries are classified as `IP.` vs `DNS.` correctly, and the setup server serves the identity the LAN listener currently uses (refresh first, pass it in) so the displayed fingerprint matches the served certificate.

## Limits
Non-upload 1 MiB; headers 16 KiB field/32 KiB list/100; read+header timeout 30 s; absolute body deadline 60 s…6 h by `Content-Length` at a 64 KiB/s floor (chunked/unknown 15 min); connections 128/16 per IP; rejected drain 8 MiB; resumable TTL 15 min, cleanup 60 s (+ quota rescan), lease hard timeout 8 h, tombstones 10 min/4096; resumable 64/8 per client; uploads 32/4 per client; pending 8 MiB; upload write coalescing 4 MiB; file 16 GiB; total 64 GiB; reserved disk 32...512 MiB dynamic; clipboard 1 MiB; SSE 10 s/1 h; manifest 2 workers/5 min/64 MiB; ZIP 5 min/1 build/100k/64 GiB; rates/min ZIP 12, manifest 60, clipboard 60, upload 600.

## State (2026-10-29)
Clean SwiftPM build succeeds with zero compiler warnings; `swift test` 119/119 (89 legacy + 30 `RemediationTests`); `MacdroSelfTest` 71/71; `MacdroAudit test` pass; `scripts/verify.sh` (build+tests+self-test+audit+XcodeGen+Xcode) pass; debug app ad-hoc. XcodeGen project generates and `xcodebuild` Debug/Release succeeds; `Macdro_MacdroKit.bundle` is embedded. Release script produces universal `x86_64 arm64` app + verified ad-hoc DMG (`dist/Macdro.dmg`, ~8.0 MB). Private GitHub release `v0.1.0` published at https://github.com/Goutham011/Macdro/releases/tag/v0.1.0 with `Macdro.dmg` (8,131,270 bytes) + SHA-256; downloaded asset re-verified universal, version 0.1.0, web assets present, ad-hoc signature valid. Private GitHub release `v0.1.1` published at https://github.com/Goutham011/Macdro/releases/tag/v0.1.1 by `.github/workflows/release.yml` on tag push (verify + universal build green) with `Macdro.dmg` (8,156,855 bytes, SHA-256 `03a576fc56893fdf77d392a3161922cec95bbeebe530b1e05c1c3cb2cb2ec4bc`); downloaded asset re-verified universal, version 0.1.1, blob-download web assets present, ad-hoc signature valid. Tag `v0.1.1` = commit `709d883` (CFBundleVersion 2). `Info.plist` local-network text is phone-neutral; unused `_macdro._tcp` Bonjour declaration removed. Stale `.build/.lock` removed after SwiftPM PID 30103/87574 diagnostics. M0.2 fixed the idle-header timeout race: `HTTPHandler.sendRequestTimeout` now closes idle connections instead of emitting an invalid 408 into an idle HTTP pipeline. Post-release fix (2026-10-26) replaced TLS `FileRegion` responses with bounded ByteBuffer streaming; HTTPS file, range, and ZIP downloads now complete without crashing `NIOSSL`. Trust-path fix (2026-10-28): the CA fingerprint (what iOS/Android displays) is now shown in the app and on the setup page, `/ca.der` serves the Android certificate, profile/CA failures return 500 instead of empty data, the setup server is handed the identity the LAN listener uses, SANs gained a validated mDNS name with correct `IP.`/`DNS.` classification, and SecTrust-based tests evaluate the served chain (positive + wrong-CA/wrong-hostname negatives). The file/ZIP download route logs `download start/done/failed` (client IP, target, offset, length) and connection errors log the client IP; those logs isolated the failing Android download to the phone's download component rejecting the CA at the TLS handshake (`certificate_unknown`) while page-context TLS succeeds, so the web client now saves files ≤ 512 MiB (and the ZIP within that cap) via in-page `fetch` → blob URL with progress instead of handing the URL to the download component — confirmed working on the Android phone (2026-10-28). The blank "Macdro Settings" launch window is fixed: plain AppKit entry, one-time Welcome window, launch-count toast (see change log); `scripts/verify.sh` stays green (89/89). Easy mode (2026-10-29): the LAN listener can serve plain HTTP via the persisted `easyLANMode` setting (Settings window + popover toggle), with `lanUsesTLS`/`lanIsSecure`/`setLANTransport` in `MacdroServer`, mode-aware UI copy and footer wording, and `LANTransportTests` covering the TLS default, plain-HTTP mode, listener rebinding, and footer honesty. TLS streaming isolation (2026-10-29): `TLSStreamingBenchmarkTests` measures 64 MiB LAN-TLS vs loopback throughput with byte-for-byte integrity (660 MB/s vs 1848 MB/s on the dev Mac — far above any LAN link), proving the bounded-ByteBuffer streaming path healthy and the Android symptom to be handshake trust (`certificate_unknown`), not streaming.

**Main window on launch (2026-10-29)**: every launch now opens a screen — `AppDelegate.announceLaunch()` shows a `MainWindowController` (AppKit window hosting `ContentView`, 380×620, titled/closable/miniaturizable, centered, activated) once `hasCompletedWelcome` is set; the first run shows Welcome first and both "Open Macdro" and the red close lead to the main window. The launch-count toast flow (launches 2–3) and `StatusToast.swift` were removed — a window replaces it — along with the `$status` sink that only drove the toast. The popover ellipsis menu gained **Show Window** (`ContentView.onShowMainWindow`, passed only when hosted by the popover) so the window can be reopened after closing; closing the last window still keeps the app running in the menu bar. `NSLog` records `Macdro main window shown visibleWindows=…`.

Verified: 10 GiB loopback download 1.74 GB/s; 10 GiB upload 225 MB/s with SHA-256; 1,000 sequential abandoned uploads store-level no leak; 100 slowloris sockets bounded/closed; 32 MiB non-upload 413; pre-1970 200; 4 GiB range; 2 MiB HTTPS full/range/ZIP download regression; served LAN certificate validates under `SecTrust` with the CA from the installed profile as anchor and fails for an unrelated CA or a non-SAN hostname/IP.

Not verified: multi-hour soak, 1,000 concurrent clients, physical iOS (Android Wi-Fi download verified 2026-10-28), physical transport switching/sleep-wake, browser upload cancellation/retry on a real phone, Developer ID/notarization (`spctl` rejects ad-hoc), phone-side display of the CA fingerprint after a clean profile reinstall.

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
- Tag/release `v0.1.1` (CFBundleShortVersionString 0.1.1, CFBundleVersion 2) bundles everything since v0.1.0: the DER trust profile + `caFingerprint` display + `/ca.der`/SAN/setup-race trust-path fixes, download-path logging, the Android in-page blob save (≤ 512 MiB), the `nosniff` dedupe, and docs; `.github/workflows/release.yml` verifies, builds, and publishes it on tag push.
- CI and Release workflows both pass on GitHub; future `v*` tags publish new assets automatically.

**Tests and docs**
- Test suite grew from 67 to 80: 10 `NetworkInterfacesTests`, two upload regression tests, and a TLS full/range/ZIP download regression; four trust-path tests later raised it to 84, four `LANTransportTests` raised it to 88, and a 64 MiB `TLSStreamingBenchmarkTests` raised it to 89; self-test remains 71 checks.
- `PROJECT_CONTEXT.md` now records the GitHub-release model, feature inventory, technology/dependency stack, platform matrix, data/state model, concepts, full file tree, release asset, package pins, and Swift 6.1 constraints.
- Added `README.md` and `.github/assets/macdro-banner.svg` as a recruiter-facing project overview with a custom hero banner.

**Post-release fix (2026-10-26)**
- Fixed mobile/LAN HTTPS downloads that appeared to pause: `serveFile` and `serveTemporaryArchive` sent `FileRegion` to `HTTPResponseEncoder` and then `NIOSSLHandler`, which only accepts `ByteBuffer`; the server trapped in `NIOAny.forceAsByteBuffer` and the browser stalled. Loopback HTTP keeps `sendfile`; TLS now streams 256 KiB ByteBuffers with write-promise backpressure and closes the file handle on success/failure.
- Added `SecurityHardeningTests.testLANHTTPSFileDownloadReturnsFullBody`: 2 MiB+ full download, byte-range 206, and ZIP over TLS. Full suite: 80/80.
- Fixed the iOS trust profile: `.mobileconfig` certificate payloads were PEM bytes; `com.apple.security.root` requires DER. The profile now uses the CA certificate DER via `NIOSSLCertificate.toDERBytes()`, and the certificate test parses the generated plist and compares the installed payload with the CA DER.
- Remaining validation: repeat the physical mobile download after relaunching the fixed build and reinstalling the regenerated trust profile.

**Trust-path diagnosis and fix (2026-10-28)**
- Diagnosed the phone's "Not Secure / connection is not private" warning: the published `v0.1.0` DMG (built 2026-10-25 21:08) predates the DER profile fix, so a phone that installed its `.mobileconfig` received PEM bytes iOS cannot decode and therefore never gained trust; secondary causes were the skipped iOS "Enable Full Trust" toggle, a fingerprint display that showed the **leaf** while the phone shows the **CA**, IP-only SANs (no hostname coverage), a setup-server/leaf-regeneration race, and Android receiving PEM under a `.crt` name.
- `TLSIdentity` now carries `caFingerprint` (SHA-256 of the CA DER) next to the leaf fingerprint; `AppModel`, `CertificateSetupView`, and the setup page show the CA fingerprint as the value to compare with the phone, with the server fingerprint secondary.
- Setup server: added `/ca.der` (`application/pkix-cert`) for Android, kept `/ca.crt` PEM for desktop; all certificate routes and the page now fail with HTTP 500 (logged) instead of returning an empty certificate/profile; profile `PayloadIdentifier`/`PayloadUUID` are derived from the CA fingerprint so reinstalls replace the same profile instead of stacking duplicates; `start(host:preferredPort:identity:)` accepts the identity the LAN listener already uses, and `AppModel.startCertificateSetup` calls `refreshTLSIdentity()` first, closing the regeneration race.
- SAN generation accepts validated DNS names in addition to IPv4, adds the Mac's mDNS hostname (`<computer>.local`, sanitized), and `sanLines` classifies entries as `DNS.`/`IP.` by actual IP-ness instead of treating every non-`localhost` value as an IP.
- Added four tests: `testPhoneTrustPathValidatesServedCertificate` (SecTrust with the CA extracted from the generated profile as anchor validates the served chain over URLSession; an unrelated CA must fail), `testServedCertificatePassesHostnameChecks` (correct IP passes, non-SAN hostname and non-SAN IP fail), `testSubjectAlternativeNamesEncodeIPAndDNSEntries` (openssl `subjectAltName` contains `IP Address:`/`DNS:` correctly and rejects junk inputs), and `testSetupServerFailsLoudlyWhenCertificateMaterialIsMissing` (missing `ca.crt` yields HTTP 500 with no certificate bytes on every trust route). Full suite: 84/84.

- Android-download diagnosis (2026-10-28, **resolved**): the instrumented server logs isolated the failure to the **TLS handshake**, not streaming: Chrome's download path on the phone sends `SSLV3_ALERT_CERTIFICATE_UNKNOWN` on every attempt while page-context TLS from the same phone succeeds in the same window (`uncleanShutdown` = established connection), so the phone's download component rejects the user-installed CA even though the browser context trusts it. The server chain is provably fine: CA-pinned `openssl verify`/live handshake against the running app returns `Verify return code: 0`, and the earlier Android-Chrome curl battery (1 GB CA-pinned transfer with matching SHA-256, `Range`/`If-Range`/HEAD, cancel+resume, keep-alive reuse, concurrent SSE) passed over LAN TLS. Fix: the web client now downloads files ≤ 512 MiB (and the ZIP when total ≤ 512 MiB) through in-page `fetch` with percentage progress, saved via a blob URL — data still traverses TLS, but inside the page's trust context, bypassing the download component's CA rejection; larger files keep the direct link, and fetch failures surface as an `offline` status. `download start/done/failed` logs with client IP distinguish an arriving-then-aborting request from one that never arrives; connection errors log the client IP. The duplicate `X-Content-Type-Options: nosniff` on file responses (explicit + `addSecurityHeaders`) was removed. Resolved on the physical Android phone: the blob path saves files and the download works (user-confirmed, 2026-10-28). Current CA fingerprint (for comparison against the phone's installed credential): SHA-256 `40:F7:40:8D:C7:88:24:87:65:00:51:64:EF:55:D6:4A:74:45:C6:AB:D8:58:16:F7:07:19:E9:3E:1A:E4:86:08`. Still unverified: behavior for files > 512 MiB on this phone (they keep the direct link, which the download component rejects).

- Blank "Macdro Settings" window at launch (2026-10-28, fixed): the app's only SwiftUI scene was a placeholder `Settings { EmptyView() }`, which macOS presents at launch as an empty window. The SwiftUI `App` lifecycle was removed in favor of a plain AppKit entry (`main.swift` + `NSApplication.run()`), so no scene system exists to show phantom windows; `AppDelegate` now drives launch UX explicitly: a one-time **Welcome** window on first run (UserDefaults `hasCompletedWelcome`, closed by either button or the red close → never again), then a **menu-bar toast** ("Macdro is running in the menu bar") below the status icon for launches 2–3 only (UserDefaults `launchCount` ≤ 3), auto-dismissing after 3 s and suppressed while the popover is open. Launch diagnostics log via `NSLog` (lands on stderr, e.g. `Macdro launch count=…`/`Macdro menu-bar toast shown`). Verified matrix: fresh defaults → welcome shown and keyed (410×339 window confirmed via CGWindowList), launches 2–3 → toast shown/closed at +3 s, launch 4+ → silent; `scripts/verify.sh` green (84/84, self-test, audit, Xcode). The `$status` sink must be registered **after** `announceLaunch()` — `@Published` replays the current value on subscription, and the server is usually already `.ready` by then (fixed ordering bug found during testing).

**Easy mode: plain-HTTP LAN transport (2026-10-29)**
- Motivation: Android Chrome (and browsers generally) cannot be made to trust a local CA without a one-time certificate install, so first-run users saw "Connection is not secure" interstitials. Easy mode is the opt-out: with the setting on, the LAN receiver serves plain HTTP — no certificate, no interstitial, direct downloads through the browser's download manager — while the default remains loopback HTTP + LAN HTTPS with the full trust flow.
- `MacdroServerConfiguration.lanUsesTLS` (default `true`) selects the LAN transport at startup; `MacdroServer.lanIsSecure` reports the active mode; `lanURLBase` and `AppModel.refreshNetworkURLs` build `http`/`https` URLs from it; `refreshTLSIdentity()` is a no-op in plain mode (no identity generated, `tlsIdentity` nil, no stale TLS error cards). `setLANTransport(useTLS:)` rebinds only the LAN channel (loopback listener, session token, and upload state survive); no HSTS is ever emitted, so browsers never pin the origin to HTTPS and the toggle works both directions.
- `MacdroHTTPHandler` gained `isLAN`; for `index.html` on the plain LAN listener the footer sentence is replaced at serve time with honest wording ("…Easy mode: connections are not encrypted in transit."); loopback and TLS responses keep the original text. Cookie `Secure` flag remains conditional on the listener (already correct). Auth (`/s/<token>`, constant-time compare, `HttpOnly`/`SameSite=Strict` cookie), body bounds, rate limits, path containment, and `isAllowedRemote` are unchanged — only transport confidentiality changes.
- UI: `SettingsView` + `SettingsWindowController` (AppKit `NSWindowController`, mirroring the welcome-window pattern — never a SwiftUI `Settings` scene) explains the tradeoff and shows the current mode; the popover ellipsis menu has a quick **Easy Mode** toggle and **Settings…**. Easy mode hides the **Trust** button and certificate hints ("No certificate needed · just open the link"), and switches the pairing hint, connection hint, and footer chip to HTTP wording.
- Docs: `AGENTS.md` safety rule, `PROJECT_CONTEXT.md` invariants/concepts, and `README.md` now record that LAN plain HTTP is only allowed via the explicit persisted setting (`UserDefaults` key `easyLANMode`, default off).
- Tests (`LANTransportTests`, 4): default config is TLS (https health, `lanIsSecure`, identity present, `Secure` cookie, plaintext rejected); easy mode serves plain HTTP (http health, https rejected, no identity, non-`Secure` cookie); `setLANTransport` rebinds both directions; footer wording matches transport (plain-LAN index has the easy-mode sentence, loopback/TLS keep "Encrypted transfer…"). Full suite: 89/89.

**TLS streaming isolation (2026-10-29)**: `TLSStreamingBenchmarkTests` stores a 64 MiB payload, downloads it over the LAN TLS listener and the loopback HTTP listener, and asserts byte-for-byte integrity on both; throughput is printed for observability (660 MB/s TLS vs 1848 MB/s loopback on the development Mac — ~9× any real LAN link). Confirms the 2026-10-26 bounded-ByteBuffer TLS streaming fix is healthy and that the Android download symptom was handshake trust (`certificate_unknown`), not a streaming bottleneck. No timing assertion, so the test cannot flake.

**Security remediation (2026-10-29)**: all seven findings from `MACDRO_EXHAUSTIVE_AUDIT_REPORT.md` are fixed. BUG-001: `MacdroSetupServer` installs a fresh `SetupHTTPHandler` per child channel, so interleaved clients can no longer receive each other's responses (per-connection `Connection: close`/complete-read behavior verified with raw sockets). SEC-001: every accepted request head arms a size-aware absolute body deadline — `BodyTimeoutPolicy` in `MacdroLimits` (`deadlineSeconds(contentLength:)` = `clamp(⌈CL/64 KiB/s⌉, 60 s, 6 h)`, chunked/unknown 15 min) plumbed through `MacdroServerConfiguration.bodyTimeoutPolicy` into `MacdroHTTPHandler` — which fires without resetting on incoming bytes, answers `408` on normal requests, closes rejected-drain connections, and is cancelled at `.end`/`channelInactive`/`errorCaught`. SEC-002: the bare `/f/{id}` route checks `cookieAuthorized` before UUID parsing or `store.file(id:)`, returning an identical `401 Unauthorized` body for known and unknown ids (existence oracle closed), with invalid/unknown ids falling through to `404`. SEC-003: resumable leases now carry an 8 h hard timeout (`UploadStore.Configuration.leaseHardTimeout`, `leaseAcquiredAt` set on acquire and cleared on `releaseLease`) that `cleanupExpired` enforces even when activity is constantly touched; reaping cancels the transaction and returns its written bytes to the quota. SEC-004: `.macdro-*.part` neutralization moved from `sanitizeName` into `sanitizeComponent`, so every path component is covered (directory names too), applied after truncation. SEC-005: `makeUploadID` uses Web Crypto only (`randomUUID`, then `getRandomValues`) and returns `null` without it; the upload path fails closed with "Secure random IDs are unavailable in this browser"; `Math.random` is gone from `app.js`. BUG-002: quota admission is reconciled from a real directory scan (`reconcileQuotaNow`, guarded by `commitGeneration` so in-flight commits cannot double-count) on the 60 s cleanup timer and via a coalesced async rescan after every quota rejection, so external deletions (Finder) restore admission within one scan. 30 new tests in `Tests/MacdroKitTests/RemediationTests.swift` cover all seven findings plus deferred gaps (session rotation mid-upload, SSE close on rotation, stale-cookie rejection, slowloris partial-body deadline, setup-server concurrency) and property-style Range/path fuzzing. Full suite 119/119, self-test 71/71, audit pass, clean `scripts/verify.sh` (zero-warning build + XcodeGen + Xcode) pass. Residual issues are recorded in `MACDRO_REMEDIATION_REPORT.md` (physical-device paths incl. the Android ≤512 MiB blob limit, multi-hour soak, Developer ID/notarization remain untested).

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
- [x] CI release job: verify, universal DMG, SHA-256, GitHub Release asset. [x] Private GitHub repo + `v0.1.0` and `v0.1.1` releases published. [ ] Optional notarization in release job.
- [ ] Beta feedback/rollback plan and signed update feed before public launch.

## Change map
Routes/HTTP -> `HTTPIntegrationTests`; uploads/cleanup -> `SecurityHardeningTests`+`HardeningTests`; regressions -> `RegressionTests`; audit remediation (body deadline, auth ordering, lease hard timeout, quota reconciliation, reserved prefixes, secure upload IDs, setup-server isolation) -> `RemediationTests` (+ `MACDRO_EXHAUSTIVE_AUDIT_REPORT.md` findings, `MACDRO_REMEDIATION_REPORT.md` outcomes); transport selection -> `NetworkInterfacesTests`; TLS/setup/trust chain -> `SecurityHardeningTests`; limits -> `MacdroLimits` + tests; UI -> `Sources/Macdro`; web -> `MacdroSelfTest`+`HTTPIntegrationTests`+`RegressionTests`; packaging -> `build-app.sh`.

## Gotchas
`swift test` uses temp dirs/ephemeral ports; don't hardcode. `HTTPHandler` is large: grep route/header. The app entry is `Sources/Macdro/main.swift` (AppKit, `MainActor.assumeIsolated` + `NSApplication.run()`); never reintroduce a SwiftUI `App`/`Settings` scene — with no other scene, macOS shows the Settings scene as a blank "Macdro Settings" window at launch. Web assets use `.copy("Resources/Web")`; missing bundle breaks packaging. `dist/Macdro.app` is universal and ad-hoc; `dist/Macdro.dmg` is not notarized. GitHub source is a standalone repo at `Goutham011/Macdro`; the parent home git repo must not be used. Publish `dist/Macdro.dmg` + `.sha256` as GitHub Release assets; `dist/` stays ignored. Dependencies are pinned (`swift-nio` 2.104.0, `swift-nio-ssl` 2.37.5, `swift-log` 1.6.2; `Package.resolved` holds compatible `swift-collections` 1.2.1/`swift-system` 1.4.0/`swift-atomics` 1.2.0). `SCNetworkServiceCopyAll` needs an `SCPreferences` handle; `build-app.sh` uses the selected Xcode toolchain (do not force CommandLineTools). `scripts/verify.sh` uses `.build/verify-spm` so clean verification does not erase `.build/xcode*`. Do not use `IOData.fileRegion` on the TLS listener; NIOSSL accepts only `ByteBuffer`, so stream TLS file/ZIP bodies in chunks. For iOS configuration profiles, `PayloadContent` for `com.apple.security.root` must be DER certificate bytes, not PEM (use `/ca.der` for Android, not `/ca.crt`). The phone displays the **CA** fingerprint, so the app and setup page must show `caFingerprint` as the comparison value; `fingerprint` is the leaf/server value. Don't regenerate an identity from the setup server while the LAN listener runs: call `MacdroServer.refreshTLSIdentity()` and pass `server.tlsIdentity` into `MacdroSetupServer.start`. The published `v0.1.0` DMG ships the PEM-profile bug — only `v0.1.1` and later should be handed to phones (tag push runs the release workflow; local `build-release.sh` output is for local testing only). Trust tests evaluate the served chain with `SecTrust` anchors rather than blanket-accepting, so regressions in chain, anchor, or SAN handling fail CI.
