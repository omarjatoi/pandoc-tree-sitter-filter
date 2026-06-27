# pandoc-tree-sitter-filter

A Pandoc [filter](https://pandoc.org/filters.html) that highlights code blocks with [tree-sitter](https://tree-sitter.github.io/).

When converting Markdown to HTML, a fenced code block tagged with a language is replaced with `<pre class="tree-sitter">…</pre>` containing `<span class="ts-…">` elements you can style with CSS (see [`theme.css`](theme.css)). A block with no language is left as-is; a language with no bundled grammar is an error.

The filter is a self-contained binary, with each grammar's parser and `highlights.scm` query compiled into the executable via FFI over `libtree-sitter` with no dependency on the `tree-sitter` CLI or any separately-installed grammars.

**Bundled languages:** `bash`, `c`, `clojure`, `cpp`, `css`, `diff`,
`dockerfile`, `elixir`, `go`, `haskell`, `html`, `java`, `javascript`, `json`,
`kotlin`, `markdown`, `nix`, `ocaml`, `python`, `ruby`, `rust`, `scala`, `scss`,
`sql`, `swift`, `toml`, `typescript`, `yaml`.

## Usage

```sh
pandoc --filter pandoc-tree-sitter-filter -s -c theme.css input.md -o output.html
```

## Development

Development uses nix. Run `nix develop` (or `direnv allow`) to get a shell with GHC, `cabal`, `pandoc`, and `libtree-sitter`. Then:

```sh
cabal build
pandoc --filter "$(cabal list-bin pandoc-tree-sitter-filter)" -t html test/input.md
```

To add a language, vendor its grammar from nixpkgs, copy the `parser.c` (+ `scanner.c` if present), the `tree_sitter/` headers, and `highlights.scm` from `nixpkgs#tree-sitter-grammars.tree-sitter-<lang>.src` into `grammars/<lang>/`, add the `.c` files to `c-sources` in the `.cabal`, and register it in `lib/PandocTreeSitterFilter/Grammars.hs`.

##  License

Licensed under either of

- Apache License, Version 2.0, ([LICENSE-APACHE](./LICENSE-APACHE) or https://www.apache.org/licenses/LICENSE-2.0)
- MIT license ([LICENSE-MIT](./LICENSE-MIT) or https://opensource.org/licenses/MIT)

at your option.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in the work by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any additional terms or conditions.

