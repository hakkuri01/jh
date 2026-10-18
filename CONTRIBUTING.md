# Contributing to Jekyll // Hyde

Thanks for your interest in contributing.

Jekyll // Hyde (`jh`) is a single-binary Crystal TUI web fuzzer focused on practical web pentest and bug bounty workflows. Contributions are accepted through GitHub issues and pull requests, then reviewed by maintainers.

## Maintainer Merge Policy

- This repository integrates changes into `main` using **squash merges only**.
- Keep PRs scoped to one logical change so the squashed commit remains clean and readable.

## Ground Rules

- Keep discussions technical, reproducible, and professional.
- Keep pull requests focused and easy to review.
- Do not include secrets, private target data, or non-public scan results in issues or PRs.
- Do not submit code intended for unauthorized or illegal activity.

## Contribution Flow

1. Open an issue (bug, enhancement), or comment on an existing one.
2. Fork the repository and create a branch from `main`.
3. Implement your change in clear, reviewable commits.
4. Add or run tests plus validation evidence during development.
5. Update `README.md` if behavior or flags changed.
6. Before opening a PR, clean test-only scaffolding from your branch so `main` remains tidy.
7. Open a pull request and complete the PR checklist.

## Local Setup

Source development requires Crystal 1.21.1 (pinned in `mise.toml`) and `just`.

```bash
git clone https://github.com/hakkuri01/jh.git
cd jh
mise trust && mise install   # Crystal 1.21.1 + just
just setup                   # build Ameba, the one dev dependency
just verify                  # format, lint, specs, reachability, release build
```

Nix contributors can use the pinned development environment and run the complete Nix release checks:

```bash
nix develop
nix flake check
nix flake check --all-systems --no-build
```

Nix is the only maintained package-manager release target. Contributors may propose complete, contributor-owned pipelines for other package managers through a pull request.

The binary links the standard library only, so there are no runtime shards to lock. The sole development dependency is Ameba, pinned to a commit in `shard.yml` with `shard.lock` committed; changing it means updating `shard.lock` and re-checking the flake's pins in the same change.

## Coding Expectations

- Follow idiomatic Crystal and existing project conventions (`AGENTS.md` is the source of truth).
- All code should follow relevant OWASP Secure Coding guidelines; server responses are untrusted and are sanitized before they reach the terminal or the filesystem.
- Prefer simple, explicit designs over speculative abstractions.
- Keep module boundaries clear and avoid unrelated refactors in feature PRs. The scan engine stays renderer-agnostic (nothing under the engine namespaces names `View::`, `Tui::`, or `Render::`).
- Handle network failures gracefully; every request carries timeouts and a body cap.
- Never log authentication headers, cookies, or other secrets.

## Style Guide

This section defines repository style expectations and may expand over time.

### Comments

- Add comments only where intent or a design tradeoff is not obvious from the code.
- Keep them concise: ideally one line with no ending period, and at most two to three lines as a docstring-style block ending with a period.
- Start comments with a capital letter.
- Explain why the approach is used in this codebase, not just what the code does.
- Never use em dashes, in code, comments, string literals, or Markdown.

## Pull Request Expectations

A solid PR includes:

- What changed and why.
- Validation evidence (tests and/or reproducible command output used during development).
- Security impact (if any) and mitigation rationale.
- Performance impact (if relevant, with numbers).
- Any documentation updates.

Note: temporary test scaffolding is acceptable in development, but the final branch should be cleaned before merge in line with this repo's shipping style.

## Bug Report Quality

Please include:

- jh version (from `shard.yml` or the TUI HUD)
- Installation method and runtime details (Nix system, or Crystal version and OS)
- Full command used (redacted)
- Reproduction steps
- Expected vs actual behavior
- Relevant logs/output (redacted)

## Security Vulnerabilities

Do not open public issues for vulnerabilities.
Use GitHub's private vulnerability reporting flow (see `SECURITY.md`).
