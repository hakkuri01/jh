# Security Policy

## Supported Versions

The latest tagged release and current `main` branch receive security fixes. Versioned Nix flake tags are the official packaged artifacts; git clones and source tarballs remain supported installation methods.

## Reporting a Vulnerability

Please report suspected vulnerabilities through GitHub's private advisory workflow:

- Go to the repository's **Security** tab.
- Use **Report a vulnerability** to submit a private report.

Do not open public issues for security vulnerabilities.

## Preferred Report Contents

Include the following to speed up triage:

- A clear issue description and impact statement.
- Steps to reproduce or proof of concept.
- Affected version/commit.
- Any suggested remediation.

Please redact secrets, tokens, and private target data.

## Triage Targets

Project maintainers aim to:

- Acknowledge reports within 3 business days.
- Provide an initial triage decision within 7 business days.

Timelines may vary based on report complexity and maintainer availability.

## Scope

This policy covers vulnerabilities in Jekyll // Hyde source code and official release artifacts.

Out of scope unless chained into a Jekyll // Hyde defect:

- The behavior of targets jh is pointed at (jh sends operator-authored payloads by design).
- General misuse of fuzzing or content-discovery tooling.
- Vulnerabilities in unrelated external systems.

## Disclosure

Coordinated disclosure is preferred. Reporter credit can be provided after a fix ships, if requested.
