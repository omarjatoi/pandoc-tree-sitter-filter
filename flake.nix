{
  description = "Pandoc filter that highlights code blocks with tree-sitter";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Haskell deps come from nixpkgs (not Hackage-via-cabal) so the dev
        # shell is reproducible and we never compile the full pandoc library:
        # everything we need (Block/CodeBlock/RawBlock/toJSONFilter) lives in
        # pandoc-types.
        ghc = pkgs.haskellPackages.ghcWithPackages (p: [
          p.pandoc-types
          p.text
          p.bytestring
          p.containers
          p.array
          p.file-embed
        ]);

        # Formatters used by treefmt (see treefmt.toml).
        formatters = [
          pkgs.nixfmt-rfc-style # nix
          pkgs.ormolu # haskell
          pkgs.clang-tools # clang-format, for C
        ];

        # `nix fmt` entry point: treefmt with the formatters on PATH.
        treefmt = pkgs.writeShellApplication {
          name = "treefmt";
          runtimeInputs = [ pkgs.treefmt ] ++ formatters;
          text = ''exec treefmt "$@"'';
        };

        # The filter itself. callCabal2nix reads the .cabal file; Haskell deps
        # come from haskellPackages. The `extra-libraries: tree-sitter` arg must
        # be pinned to the C library (pkgs.tree-sitter), otherwise it resolves to
        # the unrelated `tree-sitter` *Haskell* binding in haskellPackages. The
        # bundled grammars are compiled in from c-sources.
        package = pkgs.haskellPackages.callCabal2nix "pandoc-tree-sitter-filter" ./. {
          tree-sitter = pkgs.tree-sitter;
        };
      in
      {
        formatter = treefmt;

        packages.default = package;
        packages.pandoc-tree-sitter-filter = package;

        apps.default = {
          type = "app";
          program = "${package}/bin/pandoc-tree-sitter-filter";
        };

        devShells.default = pkgs.mkShell {
          packages = [
            ghc
            pkgs.cabal-install
            pkgs.haskell-language-server
            pkgs.pandoc # the `pandoc` CLI, for running/testing the filter
            pkgs.treefmt
          ]
          ++ formatters;

          # In buildInputs so the cc-wrapper exposes libtree-sitter's headers
          # (tree_sitter/api.h) and library (-ltree-sitter) via NIX_CFLAGS /
          # NIX_LDFLAGS when ghc compiles the C shim and links. Also puts the
          # `tree-sitter` CLI on PATH for reference.
          buildInputs = [
            pkgs.tree-sitter
          ];
        };
      }
    );
}
