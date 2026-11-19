# gchat-mac

Native macOS 27 Google Chat client. Swift 6 language mode, SwiftPM modules in `Sources/`, app target in `App/` (generated with xcodegen).

- Build: `make build` · Tests: `swift test` · Lint: `make lint` (format with `make format`)
- Try without an account: `make fake` (sample data). UI checks: `make snapshots`.
- Memory and CPU footprint are product features: measure (`make bench`, `make footprint`) and prefer the lighter option.
- This repository is public. Tracked files, commit messages and PR text contain no personal names, emails, local paths, internal hostnames or secrets.
- Planning notes, decision journals and ADRs stay local; never commit them.
