# ADR-003: Distribution without an Apple Developer ID

- **Status:** Accepted
- **Date:** 2026-10-21
- **Decided by:** the project owner

## Context

Moorbox is free and open source. The owner chose not to join the Apple Developer
Program, so release builds are **ad-hoc signed and not notarized**.

**How macOS treats such a build.** When it is downloaded, Gatekeeper blocks the
first launch until the user allows it in **System Settings → Privacy & Security →
Open Anyway**. This is Apple's supported path for apps that aren't notarized.

**How Homebrew treats it.** Since 2026-09-01, Homebrew:

- no longer accepts casks that fail Gatekeeper;
- has removed `--no-quarantine`.

See [Homebrew/brew#20755](https://github.com/Homebrew/brew/issues/20755) and
[Workbrew's Homebrew 5.0 notes](https://workbrew.com/blog/homebrew-5-0-0).

Some projects work around this with their own tap that strips the quarantine
attribute after install. That bypasses Gatekeeper, which Moorbox's security
principles rule out.

## Decision

**1. GitHub Releases**

- Publish a universal DMG and a zip, each with a SHA-256 file.
- The release notes explain the one-time "Open Anyway" step.

**2. Homebrew tap formula (not a cask)**

- `web-dev-akash/homebrew-moorbox` provides `Formula/moorbox.rb`, which **builds
  Moorbox from source on the user's Mac**: XcodeGen, then `xcodebuild`, then an
  ad-hoc signature.
- A locally built app carries no quarantine attribute, so nothing is bypassed.
- It requires Xcode, which is declared as a build dependency.

**3. Building from source**

`make app` works for anyone with Xcode. This is documented in the README.

## Consequences

- No Gatekeeper bypass anywhere.
- First launch from the DMG takes one extra approval step, and the README says so.
- Homebrew users need Xcode installed.
- If the project later gets a Developer ID, the same pipeline can sign and notarize:
  `scripts/package-app.sh` accepts `CODESIGN_IDENTITY` and `DEVELOPMENT_TEAM`. An
  official cask then becomes possible.
