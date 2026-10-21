# Security policy

## Reporting a vulnerability

Please **do not open a public issue** for security problems. Report them
privately through GitHub's
[private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
("Report a vulnerability" on the repository's Security tab).

Include affected versions, reproduction steps and impact. We aim to acknowledge
reports within 7 days.

## Supported versions

Only the latest release receives security fixes until 1.0.

## Security model, in brief

**Privileges**

- Moorbox runs as a normal user app with the hardened runtime. It isn't
  sandboxed, because it has to run tools from your Android SDK.
- It never uses `sudo`, installs no privileged helpers or launch daemons, and
  doesn't change Gatekeeper or other system security settings.
- It never strips quarantine attributes. Release builds aren't notarized, and
  you approve them through macOS's own "Open Anyway" flow (see ADR-003).

**Consent before every install.** Moorbox shows what will be downloaded, where
it goes, which tool installs it, and the license. This matters because Google's
Android CLI no longer asks before accepting licenses.

**Downloads made by Moorbox itself** (command-line tools, JDK)

- HTTPS only, from an allow-list: `dl.google.com`, and `github.com/adoptium`
  for the JDK.
- Each archive is verified against the checksum published over HTTPS: SHA-1
  for Google's packages (the only checksum Google publishes), SHA-256 for
  Temurin.
- Archives are extracted into a staging folder. They must contain exactly one
  top-level folder, and symbolic links pointing outside it are rejected.
- Only then is the result moved into place. Partial downloads are kept only so
  a retry can resume.

**Downloads made by Google's Android CLI** (emulator, platform-tools, images) go
directly from Google. Moorbox confirms each package on disk afterwards.

**Running tools**

- External tools run directly with argument arrays, never through a shell.
- Android package names are strictly validated before reaching `adb shell`,
  because the device's shell interprets those arguments.

**Stopping devices.** Moorbox only signals emulator processes it can identify
through the emulator's own registry, and checks each process's executable path
first to guard against PID reuse.

**Privacy**

- No telemetry and no crash uploads.
- Every Google tool is run with metrics off: the Android CLI with
  `--no-metrics` (verified to write no analytics), and the emulator with
  `-no-metrics -crash-report-mode never`.
- Diagnostic reports are saved locally only. Home paths, your user name,
  email addresses and tokens are redacted.
