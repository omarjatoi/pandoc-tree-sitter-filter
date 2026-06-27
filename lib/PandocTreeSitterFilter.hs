{-# LANGUAGE OverloadedStrings #-}

-- | A Pandoc filter that highlights code blocks with tree-sitter.
--
-- The language is taken from the code block's first class (the @```rust@ info
-- string in Markdown becomes the class @rust@):
--
--   * no class            -> the block is left untouched (no highlighting);
--   * a known language    -> the block is replaced with highlighted HTML;
--   * an unknown language  -> the filter fails loudly.
module PandocTreeSitterFilter (highlight) where

import qualified Data.Text as T
import PandocTreeSitterFilter.Grammars (Grammar (..), lookupGrammar)
import PandocTreeSitterFilter.Highlight (highlightToHtml)
import Text.Pandoc.JSON

highlight :: Block -> IO Block
highlight cb@(CodeBlock (_, classes, _) contents) =
  case classes of
    [] -> pure cb -- no language specified: leave the block alone
    (lang : _) ->
      case lookupGrammar lang of
        Just g -> do
          html <- highlightToHtml (grammarLanguage g) (grammarQuery g) lang contents
          pure (RawBlock (Format "html") html)
        Nothing ->
          errorWithoutStackTrace
            ( "pandoc-tree-sitter-filter: no grammar bundled for language "
                <> T.unpack lang
            )
highlight x = pure x
