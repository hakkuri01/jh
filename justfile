# Jekyll // Hyde task runner. `just verify` is the canonical gate: it stops at
# the first failure and never touches the network. `just setup` is the only
# networked recipe (it fetches Ameba's locked source once). On Nix, `nix develop`
# provides crystal + just + the linked libraries first; elsewhere `mise install`
# pins both crystal and just.

crystal := env_var_or_default("CRYSTAL", "crystal")
shards := env_var_or_default("SHARDS", "shards")
kcov := env_var_or_default("KCOV", "kcov")

# List the recipes.
_default:
    @just --list

# The canonical gate: format, lint, spec, unreachable, build (first failure wins).
[group('check')]
verify: format-check lint spec unreachable build

# Build bin/ameba from Ameba's locked source. The only networked recipe; rerun when shard.lock changes.
[group('setup')]
setup:
    {{shards}} install --frozen --skip-postinstall
    mkdir -p bin
    {{crystal}} build lib/ameba/bin/ameba.cr -o bin/ameba

# Run the specs in random order.
[group('check')]
spec:
    {{crystal}} spec --order random

# Lint with the pinned Ameba. Requires `just setup` to have built bin/ameba, keeping the gate offline.
[group('check')]
lint:
    @test -x bin/ameba || { echo "Ameba is missing: run 'just setup'" >&2; exit 1; }
    bin/ameba

# Format src and spec in place.
[group('format')]
format:
    {{crystal}} tool format src spec

# Check formatting without writing.
[group('check')]
format-check:
    {{crystal}} tool format --check src spec

# Fail on any method called by neither the binary nor a spec. The engine is a
# spec-covered library the TUI consumes mode by mode, so a landed-and-tested
# method counts as live before its UI consumer; the view, tui, and render layers
# are still reached only through the binary, so dead UI code is still caught.
[group('check')]
unreachable:
    printf 'require "./src/jekyll_hyde"\nrequire "./spec/**"\n' | {{crystal}} tool unreachable --check --exclude lib --exclude spec --stdin-filename unreachable.cr

# ponytail: plain release build; static OpenSSL linking waits until we ship binaries, after the HTTP engine.
# Build bin/jh (release), always rebuilt: a gate that passes on a stale binary is not a gate.
[group('build')]
build:
    mkdir -p bin
    {{crystal}} build --release src/jekyll_hyde.cr -o bin/jh

# Build the shipping binary through the flake. doCheck is off there, so the socket fixture never runs.
[group('build')]
nix-build:
    nix build .#jh

# Write a kcov line-coverage report (Homebrew kcov). No floor yet.
[group('check')]
coverage:
    mkdir -p bin coverage
    echo 'require "./spec/**"' | {{crystal}} build --debug --stdin-filename all_specs.cr -o bin/specs
    {{kcov}} --clean --include-path={{justfile_directory()}}/src coverage bin/specs --order=random

# Remove bin/ and coverage/.
[group('build')]
clean:
    rm -rf bin coverage
