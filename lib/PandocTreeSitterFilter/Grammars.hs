{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

-- | The registry of grammars compiled into this filter.
--
-- Each grammar bundles two things, both baked into the binary at build time so
-- the filter is self-contained (no external @tree-sitter@ CLI or on-disk
-- grammars required): the parser, exposed as a @tree_sitter_<lang>@ C symbol
-- (its @parser.c@ is listed in @c-sources@), and the @highlights.scm@ query,
-- embedded with "Data.FileEmbed".
module PandocTreeSitterFilter.Grammars
  ( Grammar (..),
    lookupGrammar,
  )
where

import qualified Data.ByteString as BS
import Data.FileEmbed (embedFile)
import Data.Text (Text)
import qualified Data.Text as T
import Foreign.Ptr (Ptr)
import PandocTreeSitterFilter.FFI (TSLanguage)
import System.IO.Unsafe (unsafePerformIO)

-- | A grammar available for highlighting.
data Grammar = Grammar
  { -- | The opaque tree-sitter language (a constant pointer).
    grammarLanguage :: Ptr TSLanguage,
    -- | The grammar's @highlights.scm@ source.
    grammarQuery :: BS.ByteString
  }

-- | Look up a grammar by language name (case-insensitive), as taken from a code
-- block's first class, resolving common aliases (@c++@, @ts@, @yml@, ...).
-- 'Nothing' means we have no grammar for it.
lookupGrammar :: Text -> Maybe Grammar
lookupGrammar name = lookup (resolveAlias (T.toLower name)) registry

resolveAlias :: Text -> Text
resolveAlias name = maybe name id (lookup name aliases)

-- | Common code-fence tags that should map onto a bundled grammar.
aliases :: [(Text, Text)]
aliases =
  [ ("c++", "cpp"),
    ("cxx", "cpp"),
    ("cc", "cpp"),
    ("hs", "haskell"),
    ("js", "javascript"),
    ("mjs", "javascript"),
    ("ts", "typescript"),
    ("py", "python"),
    ("rb", "ruby"),
    ("rs", "rust"),
    ("kt", "kotlin"),
    ("ml", "ocaml"),
    ("ex", "elixir"),
    ("exs", "elixir"),
    ("yml", "yaml"),
    ("md", "markdown"),
    ("sh", "bash"),
    ("shell", "bash"),
    ("zsh", "bash"),
    ("docker", "dockerfile")
  ]

-- | @tree_sitter_<lang>@ returns a pointer to a statically-allocated language,
-- so it is safe to treat the result as a constant.
grammar :: IO (Ptr TSLanguage) -> BS.ByteString -> Grammar
grammar getLanguage = Grammar (unsafePerformIO getLanguage)
{-# NOINLINE grammar #-}

registry :: [(Text, Grammar)]
registry =
  [ ("bash", grammar c_tree_sitter_bash $(embedFile "grammars/bash/highlights.scm")),
    ("c", grammar c_tree_sitter_c $(embedFile "grammars/c/highlights.scm")),
    ("clojure", grammar c_tree_sitter_clojure $(embedFile "grammars/clojure/highlights.scm")),
    -- cpp/typescript/scss inherit their base grammar's highlights upstream
    -- (tree-sitter's `inherits:`), so we prepend the parent query. The parent's
    -- patterns get lower indices, so the child's more specific rules win ties.
    ( "cpp",
      grammar
        c_tree_sitter_cpp
        ( $(embedFile "grammars/c/highlights.scm")
            <> "\n"
            <> $(embedFile "grammars/cpp/highlights.scm")
        )
    ),
    ("css", grammar c_tree_sitter_css $(embedFile "grammars/css/highlights.scm")),
    ("diff", grammar c_tree_sitter_diff $(embedFile "grammars/diff/highlights.scm")),
    ("dockerfile", grammar c_tree_sitter_dockerfile $(embedFile "grammars/dockerfile/highlights.scm")),
    ("elixir", grammar c_tree_sitter_elixir $(embedFile "grammars/elixir/highlights.scm")),
    ("go", grammar c_tree_sitter_go $(embedFile "grammars/go/highlights.scm")),
    ("haskell", grammar c_tree_sitter_haskell $(embedFile "grammars/haskell/highlights.scm")),
    ("html", grammar c_tree_sitter_html $(embedFile "grammars/html/highlights.scm")),
    ("java", grammar c_tree_sitter_java $(embedFile "grammars/java/highlights.scm")),
    ("javascript", grammar c_tree_sitter_javascript $(embedFile "grammars/javascript/highlights.scm")),
    ("json", grammar c_tree_sitter_json $(embedFile "grammars/json/highlights.scm")),
    ("kotlin", grammar c_tree_sitter_kotlin $(embedFile "grammars/kotlin/highlights.scm")),
    ("markdown", grammar c_tree_sitter_markdown $(embedFile "grammars/markdown/highlights.scm")),
    ("nix", grammar c_tree_sitter_nix $(embedFile "grammars/nix/highlights.scm")),
    ("ocaml", grammar c_tree_sitter_ocaml $(embedFile "grammars/ocaml/highlights.scm")),
    ("python", grammar c_tree_sitter_python $(embedFile "grammars/python/highlights.scm")),
    ("ruby", grammar c_tree_sitter_ruby $(embedFile "grammars/ruby/highlights.scm")),
    ("rust", grammar c_tree_sitter_rust $(embedFile "grammars/rust/highlights.scm")),
    ("scala", grammar c_tree_sitter_scala $(embedFile "grammars/scala/highlights.scm")),
    ("scss", grammar c_tree_sitter_scss $(embedFile "grammars/scss/highlights.scm")),
    ("sql", grammar c_tree_sitter_sql $(embedFile "grammars/sql/highlights.scm")),
    ("swift", grammar c_tree_sitter_swift $(embedFile "grammars/swift/highlights.scm")),
    ("toml", grammar c_tree_sitter_toml $(embedFile "grammars/toml/highlights.scm")),
    ( "typescript",
      grammar
        c_tree_sitter_typescript
        ( $(embedFile "grammars/javascript/highlights.scm")
            <> "\n"
            <> $(embedFile "grammars/typescript/highlights.scm")
        )
    ),
    ("yaml", grammar c_tree_sitter_yaml $(embedFile "grammars/yaml/highlights.scm"))
  ]

foreign import ccall unsafe "tree_sitter_bash" c_tree_sitter_bash :: IO (Ptr TSLanguage)

foreign import ccall unsafe "tree_sitter_c" c_tree_sitter_c :: IO (Ptr TSLanguage)

foreign import ccall unsafe "tree_sitter_clojure" c_tree_sitter_clojure :: IO (Ptr TSLanguage)

foreign import ccall unsafe "tree_sitter_cpp" c_tree_sitter_cpp :: IO (Ptr TSLanguage)

foreign import ccall unsafe "tree_sitter_css" c_tree_sitter_css :: IO (Ptr TSLanguage)

foreign import ccall unsafe "tree_sitter_diff" c_tree_sitter_diff :: IO (Ptr TSLanguage)

foreign import ccall unsafe "tree_sitter_dockerfile" c_tree_sitter_dockerfile :: IO (Ptr TSLanguage)

foreign import ccall unsafe "tree_sitter_elixir" c_tree_sitter_elixir :: IO (Ptr TSLanguage)

foreign import ccall unsafe "tree_sitter_go" c_tree_sitter_go :: IO (Ptr TSLanguage)

foreign import ccall unsafe "tree_sitter_haskell" c_tree_sitter_haskell :: IO (Ptr TSLanguage)

foreign import ccall unsafe "tree_sitter_html" c_tree_sitter_html :: IO (Ptr TSLanguage)

foreign import ccall unsafe "tree_sitter_java" c_tree_sitter_java :: IO (Ptr TSLanguage)

foreign import ccall unsafe "tree_sitter_javascript" c_tree_sitter_javascript :: IO (Ptr TSLanguage)

foreign import ccall unsafe "tree_sitter_json" c_tree_sitter_json :: IO (Ptr TSLanguage)

foreign import ccall unsafe "tree_sitter_kotlin" c_tree_sitter_kotlin :: IO (Ptr TSLanguage)

foreign import ccall unsafe "tree_sitter_markdown" c_tree_sitter_markdown :: IO (Ptr TSLanguage)

foreign import ccall unsafe "tree_sitter_nix" c_tree_sitter_nix :: IO (Ptr TSLanguage)

foreign import ccall unsafe "tree_sitter_ocaml" c_tree_sitter_ocaml :: IO (Ptr TSLanguage)

foreign import ccall unsafe "tree_sitter_python" c_tree_sitter_python :: IO (Ptr TSLanguage)

foreign import ccall unsafe "tree_sitter_ruby" c_tree_sitter_ruby :: IO (Ptr TSLanguage)

foreign import ccall unsafe "tree_sitter_rust" c_tree_sitter_rust :: IO (Ptr TSLanguage)

foreign import ccall unsafe "tree_sitter_scala" c_tree_sitter_scala :: IO (Ptr TSLanguage)

foreign import ccall unsafe "tree_sitter_scss" c_tree_sitter_scss :: IO (Ptr TSLanguage)

foreign import ccall unsafe "tree_sitter_sql" c_tree_sitter_sql :: IO (Ptr TSLanguage)

foreign import ccall unsafe "tree_sitter_swift" c_tree_sitter_swift :: IO (Ptr TSLanguage)

foreign import ccall unsafe "tree_sitter_toml" c_tree_sitter_toml :: IO (Ptr TSLanguage)

foreign import ccall unsafe "tree_sitter_typescript" c_tree_sitter_typescript :: IO (Ptr TSLanguage)

foreign import ccall unsafe "tree_sitter_yaml" c_tree_sitter_yaml :: IO (Ptr TSLanguage)
