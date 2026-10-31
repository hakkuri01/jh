# Jekyll // Hyde | AI Agent Guidelines

Working rules for AI coding agents on this project.

## Mandatory Rules

### Development Environment

Enter the project dev shell with `nix develop` before beginning work. Run all
project development tools from that shell rather than using environment-level
toolchains.

### Algorithmic Complexity (Big O)

**Complexity is a builder step.** Run it on every change and in every review: name what grows,
name the path the code runs on, and meet that path's target. O(1) is the gold
standard, O(log n) excellent, O(n) often optimal (the lower bound for anything
that must read every item or byte), O(n log n) optimal for general sorting, and
O(n squared) or worse needs a stated bound on n or a redesign. O(n cubed),
O(2^n), and O(n!) never ship.

1. **Name what grows.** Here: wordlist entries (W, often hundreds of thousands to
   millions), concurrent requests in flight (C, user-set, bounded), the Hyde
   recursion queue (directories discovered, each enqueuing another W-sized pass,
   bounded by depth and a seen-URL set), links extracted per response, and
   results accumulated. Above all, text from outside: response bodies, headers,
   status reasons, and extracted links, all untrusted and unbounded unless
   capped. In a session: input messages per second (every mouse motion is one)
   and cells per frame.
2. **Name the path, and meet its target.**

   | Path | Runs | Target | Accepted ceiling (with a `ponytail:` comment naming n's bound) |
   |---|---|---|---|
   | Per request dispatch | Once per wordlist entry, C in flight | O(1) to pull the next entry and send; the wordlist is iterated, never rescanned | None worse than O(1) amortized |
   | Per response filter | Once per response | O(1) for status, size, word, and line checks (counts, not rescans); O(body) only when a regex matcher is set | O(body) for an explicit regex, one pass |
   | Text from outside (sanitize, extract links, measure) | Over every byte of a response | One O(n) pass, with a size cap. Untrusted, so worse than linear in its length is a denial of service | None |
   | Recursion queue (Hyde) | Once per discovered directory | O(1) seen-URL check through a `Set`; never rescan a URL already queued | Depth-bounded fan-out on a fixed worker pool |
   | Wordlist load | Once at scan start | O(W) read, O(W) dedup through a `Set` | O(W) memory, or streamed when a list is too large to hold |
   | Per frame (`view`) | Dozens to hundreds of times a second while the mouse moves | O(cells drawn): the view slices rows prepared ahead of time | O(n) over a bounded on-screen window, never O(results), never O(body) |
   | Per input change (results arrive, width changes, filter changes) | Once per change, memoized | O(n) to prepare, O(n log n) to sort the visible set | O(n log n) |

3. **Look up by key.** A membership test inside a loop over wordlist entries,
   responses, or results goes through a `Hash` or `Set`, never a `find`,
   `includes?`, or `select` (a hidden O(n squared)).
4. **Crystal strings index in O(n).** On any string holding a non-ASCII byte,
   `str[i]` and `str[a..]` scan from the start, so a per-character loop is
   O(n squared). Walk with `each_char` or a `Char::Reader` kept in one scope,
   work in byte offsets (`byte_index`, `byte_slice`), and build with
   `String.build`.
5. **Prepare off the frame.** Work that depends only on the data and the width
   (sanitizing, wrapping, column widths, sorting the result set) runs once per
   input change, never in `view`.
6. **Space counts.** Everything read from the network has a cap (body size,
   header size, line length, extracted-link count, recursion depth and queue
   size). A large body streams or is truncated at the cap, never fully buffered
   past it.
7. **Pin the target with a check.** A target that matters gets a spec that fails
   when it regresses: a count (requests sent for a wordlist and config, requests
   in flight at once, duplicate requests to one URL, link-extraction passes per
   response), never a wall-clock timing.

### Security

**All code is OWASP Top 10 avoidant by construction**, and every block that touches untrusted data is reasoned through
before it is written.

1. **Server data is untrusted and hostile.** jh renders arbitrary HTTP responses
   from arbitrary targets. All external text (response bodies, headers, status
   reasons, extracted links, redirect targets, filenames) passes a `sanitize`
   pass before it touches the terminal or the filesystem: strip escape
   sequences, the C0 controls (newline and tab included, since a result renders
   on a single cell), DEL, the C1 controls, and bidirectional overrides. A
   malicious or compromised target must not be able to inject terminal escapes
   into the TUI. Styles are applied after sanitizing.
2. **Provenance decides handling, and the payload is the point.** A fuzzer that
   encodes its operator's payload is broken. The axis is where a byte came from,
   not its value:
   - **Operator bytes** (a `FUZZ` substitution, a hand-authored request, a
     replay) go out verbatim. Encoding is opt-in (the `-enc` convention), never a
     default; the whole job is to send `../`, `%00`, and other "malformed" input.
   - **Page-authored bytes** (a Hyde wordlist word placed as a path segment, a
     crawled link) are percent-encoded only where they would otherwise break the
     request line.
   - **Remote-chosen bytes** (a redirect `Location`, a link's host) are validated
     (scheme and host) and refused when unsafe, never repaired; no outbound URL
     is built from unvalidated server data.
   Nothing of any provenance is ever shell-interpolated.
3. **No shell.** Subprocesses, if ever needed, use argument arrays, never a
   shell, with a timeout and a cleaned environment.
4. **Network limits.** Every request has connect and read timeouts. Every
   response has its status, content type, and size (against a cap) checked before
   use. TLS verification is on by default; the operator may disable it explicitly
   (the `-k` convention), and that choice is theirs.
5. **Secrets.** Authentication headers and cookies the operator supplies are
   never written to result files or logs. Reference credentials by name, never
   persist them silently.
6. **Filesystem.** Output paths and anything derived from server data (an
   extracted link saved as a file) are reduced to a safe basename; no path
   traversal.
7. **Errors.** Every expected failure is one actionable line, with no stack
   trace or internal path.
8. **Authorization is the operator's.** jh scans what it is pointed at; scanning
   a target you are not authorized to test is the operator's responsibility, and
   the README says so.
9. **A safety predicate has one home.** A request-line, encoding, or validation
    check (is this host frameable, is this redirect in scope, is this byte
    safe in a request token) is written once and called everywhere; never
    re-derive it beside a new caller. The second copy is where the two drift and
    one of them becomes the bug.

### Code Quality

1. **Maximum 40 lines per method or macro.** Extract private helpers.
2. **File size: 500 lines is a hard limit, 300 the soft target.** Split past 300
   unless the code is one cohesive unit that reads worse split.
3. **Maximum 4 parameters per method.** Group more into a `record` or struct, or
   use named arguments.
4. **No duplicated blocks over 6 lines.** Extract the shared code.
5. **No `not_nil!`, `.as(T)` cast, or `uninitialized` in `src/`** without an
   inline comment saying why the type cannot be narrowed. Prefer `if value = ...`
   narrowing and exhaustive `case ... in`. In `spec/`, `not_nil!` is the ordinary
   way to assert a value is present and is allowed (`.ameba.yml` matches).
   - `Char::Reader` (like every struct) is copied when passed to a method, so a
     helper that advances it advances a copy and the caller loops forever. Keep a
     reader in one method, or in an instance variable.
6. **No dead code.** `crystal tool unreachable --check` fails the gate on any
   method the binary never calls, so nothing is written ahead of its caller.
7. **`src/` has no side effects when required.** Only `src/jekyll_hyde.cr` runs
   anything. Nested namespaces use the compact form (`module JekyllHyde::Http`).

#### Naming

Crystal community conventions: `snake_case` for methods, variables, and files;
`CamelCase` for types; `SCREAMING_CASE` for constants; predicates end in `?` and
raising variants in `!`. One primary type per file, named after it in
snake_case, with directories mirroring namespaces (`JekyllHyde::Http::Client`
lives in `src/jekyll_hyde/http/client.cr`). The two modes live under
`JekyllHyde::Hyde` and `JekyllHyde::Jekyll`.

#### Comments / Documentation

- A comment appears only where the code is not readably self-explanatory and the
  block genuinely needs explaining.
- Ideally one line, no ending period.
- Otherwise two to three lines at most, ending in a period, as a docstring-style
  block comment.
- **One exception runs longer:** a non-obvious security decision or a known gotcha (a crash, a DoS, an ordering trap)
  may take a short block, ideally ending with a pointer (the function
  it mirrors, the principle it serves). Explain the *why*; keep the *what*
  terse. This is the only comment allowed past three lines.
- No commented-out code, no `TODO` or `FIXME`.
- **Never use em dashes anywhere:** code, comments, string literals, Markdown,
   or commit messages. Use commas, semicolons, colons, parentheses, or separate
   sentences.

### Dependencies

- **Zero runtime shards.** `shard.yml` has no `dependencies` key; the binary uses
  the standard library only. (unless it becomes clear in the future that we need a shard for some implementation that makes sense)
- **Ameba is the only development dependency.** It is pinned to a commit,
  `shard.lock` is committed, and `just setup` installs it with
  `--frozen --skip-postinstall` and builds it from `lib/ameba`, so no install
  script runs. Adding any other dependency is the owner's decision.
- **Nothing in `src/` requires from `lib/`.**

### Testing

- `spec/` mirrors `src/` (the Crystal convention). New logic ships with a spec.
  A cross-cutting invariant that no single file owns is a *seam spec* at the
  `spec/` root (the architecture boundary, the mode-switch flicker): it asserts a
  property of several files at once and fails the moment one of them breaks: a
  layering ratchet.
- **The engine is renderer-agnostic.** Nothing under `core`, `http`, `wordlist`,
  `filter`, `results`, `hyde`, or `jekyll` names `View::`, `Tui::`, or `Render::`;
  `spec/architecture_spec.cr` fails on any non-comment hit.
- Engine behavior is verified by a dev-only parity harness that drives the
  engine directly (no TUI) against a loopback `HTTP::Server` fixture with a known
  route tree and configurable wildcard and not-found behavior, with hand-authored
  expectations. The harness is never a shipped feature.
- `just verify` never touches the network. The fixture binds `127.0.0.1` only.
- Before trusting a new lint or source rule, prove it fires on a probe.

### What NOT to Do

- Do NOT add a runtime shard, or a development dependency, without the owner's
  decision.
- Do NOT encode or sanitize an operator's payload bytes; that is the payload.

## Dev

The task runner is `just` (`just --list` shows every recipe). Two ways in:

```sh
# Nix (primary: how it ships, and how hakkuri develops)
nix develop            # dev shell: crystal, just, and the linked libraries
just verify            # the canonical gate

# non-Nix
mise trust && mise install   # once per machine: pins crystal + just
just setup                   # once after cloning, and again when shard.lock changes (the only networked recipe)
just verify                  # the canonical gate
```

`just verify` runs, stopping at the first failure:

1. `crystal tool format --check src spec`
2. `bin/ameba` (default rules, scoped to `src` and `spec`)
3. `crystal spec --order random`
4. `crystal tool unreachable --check --exclude lib src/jekyll_hyde.cr`
5. `crystal build --release` into `bin/jh`

`nix build .#jh` (or `just nix-build`) builds the shipping binary through the
flake; `doCheck` is off there, so the socket-binding fixture never runs inside
the Nix sandbox (that is `just verify`'s job, and CI's). `just coverage` writes a
kcov line-coverage report; no floor yet, to be set from a baseline and folded
into `verify` later.

### Nix Packaging

- **`flake.nix`** exposes `packages.default`/`packages.jh`, an `apps` entry,
  `overlays.default` (so a NixOS or home-manager config gets `pkgs.jh`),
  `checks.default` + `checks.overlay` (the overlay path is built by
  `nix flake check`, so a broken overlay fails there, not on someone's rebuild),
  and `devShells.default`. One `mkJh pkgs` function backs both the package and
  the overlay; `supportedSystems` is bound once and reused by the system loop and
  `meta.platforms`.
- **No `shards.nix`.** The binary has zero runtime shards, so the build is
  `format = "crystal"` with no dependency materialization: none of the usual
  `crystal2nix` / `shards.nix` / drift-gate machinery is needed. That whole class
  of upkeep is what the stdlib-only rule buys us.
- **Crystal comes from the locked nixpkgs input.** Keep that input on a Crystal
  version satisfying `shard.yml` and `mise.toml`.
- **`doCheck = false`.** The spec suite binds a loopback socket (the parity
  fixture); it must not run in the sandboxed Nix build.
- **Source is an allowlist** (`lib.fileset.toSource`): `src`, `data`, `shard.yml`,
  `shard.lock`, `README.md`, `LICENSE`. Compile-time `read_file` embeds
  (`shard.yml` for the version, `data/logo/*` for the banner) must stay in it, or
  the build breaks, or the binary changes without busting the derivation hash.
- Changing `shard.lock` or `mise.toml` means re-checking the flake's pins in the
  same change.

### Committing

- **One logical change per commit.** Messages are a single line, no body:
  Capitalized, no trailing period. A release commit leads with its version and a
  colon (`0.1.0: Add the Jekyll regex matcher`); a smaller supporting commit uses
  a category prefix (`Docs:`, `Chore:`, `Fix:`) or a brief bare summary
  (`README update`).
- **No AI attribution** anywhere: commit or PR. End after the content and any
  real human trailer.
- **Commit format**: <type>: <description>

### Refactoring and Bulk Edits

Never use blanket find-and-replace (sed, regex bulk replacement) across the code.
Work occurrence by occurrence, reading the context of each before changing it.
