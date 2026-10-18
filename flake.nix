{
  description = "jh (Jekyll // Hyde): a single-binary interactive TUI web fuzzer, Hyde for recursive discovery and Jekyll for templated fuzzing";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # Bound once and read by both `eachSystem` and `meta.platforms`: written
      # out twice, the pair drifts the first time a system is added or removed.
      # Apple silicon first (Ghostty), Linux next; Intel macOS installs via the
      # release tarball (nixpkgs dropped x86_64-darwin).
      supportedSystems = [ "aarch64-darwin" "x86_64-linux" "aarch64-linux" ];

      # Takes a package set rather than closing over this flake's own nixpkgs, so
      # the same definition backs `overlays.default`: an overlay that reached back
      # into this flake's nixpkgs would build jh against a different stdenv than
      # the one it is applied onto, dragging a second glibc/openssl into a
      # consumer's closure.
      mkJh = pkgs:
        let
          inherit (pkgs) lib;

          # jh needs Crystal >= 1.21.1 (shard.yml, mise.toml); nixpkgs still lags,
          # so pin the compiler's source. Patch bumps within a minor are safe to
          # override this way.
          #
          # FIRST BUILD: the hash below is a placeholder. Run `nix build .#jh`
          # once, copy the real `sha256-...` from the mismatch error into
          # `crystalHash`, and build again. Drop this whole override and use
          # `pkgs.crystal` directly once nixpkgs ships >= 1.21.1.
          crystalVersion = "1.21.1";
          crystalHash = lib.fakeHash;
          crystal = pkgs.crystal.overrideAttrs (old: {
            version = crystalVersion;
            src = pkgs.fetchFromGitHub {
              owner = "crystal-lang";
              repo = "crystal";
              rev = crystalVersion;
              hash = crystalHash;
            };
            makeFlags = (old.makeFlags or [ ]) ++ [
              "CRYSTAL_CONFIG_VERSION=${crystalVersion}"
            ];
            # 1.21 stopped shipping a pre-generated man/crystal.1 (it is rendered
            # from doc/man/*.adoc by a make target nixpkgs' buildFlags do not run),
            # so the stock installPhase dies on it. Drop that one line rather than
            # pull asciidoctor into the compiler build for a page nothing reads.
            # Guarded: replaceStrings returns the subject UNCHANGED when the needle
            # is absent, so against a nixpkgs whose installPhase has moved on this
            # would silently no-op and fail minutes later with nothing pointing
            # back here. Throw instead, and re-check this when it fires.
            installPhase =
              let
                needle = "installManPage man/crystal.1";
                patched = builtins.replaceStrings [ needle ] [ "" ] (old.installPhase or "");
              in
              if (old.installPhase or "") == "" then
                old.installPhase
              else if patched == old.installPhase then
                throw "jh flake: nixpkgs' crystal installPhase no longer contains `${needle}` — re-check the man-page workaround in flake.nix."
              else
                patched;
          });

          # Only the files the compiler reads. `./.` would pull the whole tree
          # (refs/, .kiro/, docs) into the store, so an unrelated edit would bust
          # the derivation hash and cost every Nix user a rebuild. The compile-time
          # read_file embeds MUST be in this list: shard.yml (the version) and
          # data/ (the logo banner), or the build breaks or the binary changes
          # without busting the hash.
          src = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./src
              ./data
              ./shard.yml
              ./shard.lock
              ./README.md
              ./LICENSE
            ];
          };
        in
        crystal.buildCrystalPackage {
          pname = "jh";
          version = "0.1.0";

          inherit src;

          # `format = "crystal"` with no shardsFile: the binary has zero runtime
          # shards, so there is nothing to materialise into lib/ and no shards.nix
          # to keep in sync. Everything jh links (openssl, pcre2, zlib, boehm-gc,
          # libevent, libyaml) the `crystal` wrapper already puts on
          # CRYSTAL_LIBRARY_PATH; add a lib to buildInputs only when a new
          # @[Link(...)] appears (e.g. brotli/zstd if we ever decode those).
          format = "crystal";
          crystalBinaries.jh.src = "src/jekyll_hyde.cr";
          crystalBinaries.jh.options = [ "--release" "--no-debug" "--progress" ];
          buildInputs = [ ];

          # The spec suite binds a loopback socket (the parity fixture), which the
          # sandbox has no network for; leave it to `just verify` and CI.
          doCheck = false;

          meta = {
            description = "A single-binary interactive TUI web fuzzer: Hyde for recursive discovery, Jekyll for templated fuzzing";
            homepage = "https://github.com/hakkuri01/jh";
            license = lib.licenses.mit;
            mainProgram = "jh";
            maintainers = [{
              name = "hakkuri";
              github = "hakkuri01";
            }];
            # NOT crystal.meta.platforms (every platform the compiler builds on):
            # that would advertise systems supportedSystems leaves out.
            platforms = supportedSystems;
          };
        };
    in
    {
      # The idiomatic entry point for a NixOS or home-manager config that threads
      # its own pkgs: add this overlay and `pkgs.jh` exists everywhere. `final`,
      # not `prev`, so a consumer's later overlays are visible to the build.
      overlays.default = final: _prev: { jh = mkJh final; };
    }
    // flake-utils.lib.eachSystem supportedSystems (system:
      let
        pkgs = import nixpkgs { inherit system; };
        jh = mkJh pkgs;
      in
      {
        packages.default = jh;
        packages.jh = jh;

        apps.default = flake-utils.lib.mkApp { drv = jh; };
        apps.jh = flake-utils.lib.mkApp { drv = jh; };

        checks.default = jh;
        # Builds jh through the overlay path, which `mkJh pkgs` above does NOT
        # exercise, so a broken overlay fails `nix flake check` here instead of on
        # a NixOS user's rebuild. Same derivation when healthy, paid for once.
        checks.overlay = (import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        }).jh;

        devShells.default = pkgs.mkShell {
          # crystal + the linked libraries, straight from the package.
          inputsFrom = [ jh ];
          # `shards` is absent from a format = "crystal" build but the dev loop
          # (just setup) needs it; `just` runs the recipes, `kcov` the coverage.
          nativeBuildInputs = with pkgs; [ shards just kcov git ];
          shellHook = ''
            echo "jh dev shell (crystal $(crystal version | head -n1 | cut -d' ' -f2))"
            echo "  just setup   # build bin/ameba (first run)   just verify   # the gate"
          '';
        };
      });
}
