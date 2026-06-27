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

        # Everything we need is in pandoc-types, so we never build full pandoc.
        ghc = pkgs.haskellPackages.ghcWithPackages (p: [
          p.pandoc-types
          p.text
          p.bytestring
          p.containers
          p.array
          p.file-embed
        ]);

        formatters = [
          pkgs.nixfmt-rfc-style
          pkgs.ormolu
          pkgs.clang-tools # clang-format
        ];

        treefmt = pkgs.writeShellApplication {
          name = "treefmt";
          runtimeInputs = [ pkgs.treefmt ] ++ formatters;
          text = ''exec treefmt "$@"'';
        };

        # Pin tree-sitter to the C library, else `extra-libraries: tree-sitter`
        # resolves to the unrelated Haskell binding of the same name.
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
            pkgs.pandoc
            pkgs.treefmt
          ]
          ++ formatters;

          # buildInputs (not packages) so the cc-wrapper exposes libtree-sitter's
          # headers and library via NIX_CFLAGS / NIX_LDFLAGS when ghc builds the
          # C shim.
          buildInputs = [
            pkgs.tree-sitter
          ];
        };
      }
    );
}
