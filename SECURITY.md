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

- Moorbox runs as a normal user app.
- It never uses `sudo`, installs no privileged helpers or launch daemons, and
  doesn't change Gatekeeper or other system security settings.

**Downloads**

- Only over HTTPS, and only from `dl.google.com`. Any other host in the
  metadata is rejected.
- Each archive is checked against the SHA-1 checksum published in Google's
  HTTPS-served repository metadata. SHA-1 is the only checksum Google
  publishes; HTTPS transport is the primary integrity guarantee.
- Archives are extracted into a staging folder. They must contain exactly one
  top-level folder, and symbolic links that point outside it are rejected.
  Only then is the folder moved into place.

**Running tools**

- External tools (`emulator`, `adb`, `unzip`) run directly with argument
  arrays, never through a shell.
- Android package names are strictly validated before being passed to
  `adb shell`, because the device's shell interprets those arguments.

**Stopping devices**

- Moorbox only signals emulator processes it can identify through the
  emulator's own registry.
- It checks each process's executable path first, to guard against PID reuse.

**Privacy**

- No telemetry and no crash uploads.
- Emulators are launched with `-no-metrics -crash-report-mode never`.
- Diagnostic reports are saved locally. Before saving, home paths, your user
  name, email addresses and tokens are redacted.
