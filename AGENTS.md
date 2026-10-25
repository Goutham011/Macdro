# Macdro

Native macOS 14+ menu-bar LAN file transfer (Swift/SwiftUI/SwiftNIO).

**Read `PROJECT_CONTEXT.md` first.** It is the canonical map: commands, layout, runtime model, limits, invariants, verified status, change map. Use it instead of exploring the tree, and update it when architecture, commands, limits, or test status changes.

Minimum safety rules if you do not read it: keep loopback HTTP / LAN HTTPS separation, never expose the token, bound request bodies, stream uploads, and contain paths inside the upload root.

Quick commands: `swift build`; `swift test`; `swift run MacdroSelfTest`; `swift run MacdroAudit test`; `CONFIG=debug ./scripts/build-app.sh`.
