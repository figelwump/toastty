# Native iOS `RemoteProtocol` Source Sharing

Status: viable as of 2026-08-11.

## Decision

Keep `Sources/RemoteProtocol/` as the single source-owned wire-contract directory and compile it into an independently named `RemoteProtocol` static framework in both Tuist graphs. The iOS graph references the directory with `../Sources/RemoteProtocol/**`; it does not copy the sources and does not introduce a local Swift package.

Both targets compile with Swift 6. The iOS graph additionally pins complete strict-concurrency checking at the project and shared-target levels. Shared sources remain Foundation-only, enforced from both macOS and iOS protocol-boundary tests.

## Stop/go evidence

The external source glob passed generation, source-file/build ownership, strict fixture decoding, simulator execution, and the macOS regression gate on toastty-mini:

- `phase1-ios-source-sharing-stop-go`: remote iOS generation plus the complete `ToasttyMobileApp` test scheme passed. The generated graph contained a standalone dependency-free `RemoteProtocol` target, all 25 canonical `Tests/RemoteProtocol/Fixtures/v1/` cases decoded through their concrete shared models, and the domain/app/UI tests passed on an iPhone Simulator.
- `phase1-mac-remote-protocol-regression-final`: the merged child worktree generated and built the root macOS graph; `RemoteProtocolGoldenTests` and `RemoteProtocolBoundaryTests` passed (3 tests across 2 suites), including byte-identical host encoding of the canonical fixtures.

The local artifact summaries for these ignored validation runs are under `artifacts/remote-tests/<label>/result.json`. Both record `executionTarget: remote`, `status: pass`, and no local fallback.

## Ownership rules

- Add or change wire models only under `Sources/RemoteProtocol/`.
- Keep canonical fixtures under `Tests/RemoteProtocol/Fixtures/v1/`; the iOS tests consume that folder in place.
- A shared-protocol change must pass both the remote iOS tier and the root macOS golden/boundary tier.
- `ToasttyMobileDomain` depends directly on `RemoteProtocol`. App or test targets add a direct dependency and import only when their own source names shared types.
- If a future Tuist/Xcode version stops supporting this external source ownership reliably, stop at generation/build and reconsider the planned local-package fallback. Do not duplicate the protocol sources into `ios/`.
