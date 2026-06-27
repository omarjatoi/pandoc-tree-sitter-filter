{-# LANGUAGE OverloadedStrings #-}

-- | Tests for the highlight filter. Deliberately framework-free (just base +
-- pandoc-types + text) so the dev shell stays small.
module Main (main) where

import Control.Exception (SomeException, try)
import Control.Monad (forM, unless)
import Data.Text (Text)
import qualified Data.Text as T
import PandocTreeSitterFilter (highlight)
import System.Exit (exitFailure)
import Text.Pandoc.Definition

codeBlock :: [Text] -> Text -> Block
codeBlock classes src = CodeBlock ("", classes, []) src

htmlOf :: Block -> Maybe Text
htmlOf (RawBlock (Format "html") t) = Just t
htmlOf _ = Nothing

-- | A highlighted block whose HTML contains all of the given substrings.
expectHtml :: [Text] -> Text -> [Text] -> IO Bool
expectHtml classes src needles = do
  block <- highlight (codeBlock classes src)
  pure $ case htmlOf block of
    Just html -> all (`T.isInfixOf` html) needles
    Nothing -> False

-- | A block that should pass through 'highlight' unchanged.
expectUnchanged :: Block -> IO Bool
expectUnchanged block = (== block) <$> highlight block

-- | 'highlight' should throw for this block.
expectError :: Block -> IO Bool
expectError block = do
  result <- try (highlight block) :: IO (Either SomeException Block)
  pure $ case result of
    Left _ -> True
    Right _ -> False

tests :: [(String, IO Bool)]
tests =
  [ ( "untagged code block is left unchanged",
      expectUnchanged (codeBlock [] "print('hi')")
    ),
    ( "non-code blocks are left unchanged",
      expectUnchanged (Para [Str "hello"])
    ),
    ( "unknown language is an error",
      expectError (codeBlock ["nope-not-a-language"] "x")
    ),
    ( "C highlights keyword/function/type",
      expectHtml
        ["c"]
        "int main(void) { return 0; }"
        [ "class=\"tree-sitter\"",
          "data-lang=\"c\"",
          "<span class=\"ts-keyword\">return</span>",
          "<span class=\"ts-function\">main</span>",
          "<span class=\"ts-type\">int</span>"
        ]
    ),
    ( "Python highlights the def keyword",
      expectHtml
        ["python"]
        "def f():\n    pass"
        ["<span class=\"ts-keyword\">def</span>"]
    ),
    ( "HTML special characters are escaped",
      expectHtml
        ["c"]
        "int x = 1 < 2 && 3 > 2;"
        ["&lt;", "&gt;", "&amp;"]
    ),
    ( "alias c++ resolves to the cpp grammar",
      expectHtml
        ["c++"]
        "int main() { return 0; }"
        ["class=\"tree-sitter\"", "ts-keyword"]
    ),
    ( "alias ts resolves to the typescript grammar",
      expectHtml
        ["ts"]
        "const x: number = 1;"
        ["class=\"tree-sitter\""]
    ),
    ( "extra classes after the language are ignored",
      expectHtml
        ["rust", "numberLines"]
        "fn main() {}"
        ["class=\"tree-sitter\"", "data-lang=\"rust\""]
    ),
    ( "empty code block still produces a highlighted shell",
      expectHtml
        ["c"]
        ""
        ["<pre class=\"tree-sitter\" data-lang=\"c\"><code></code></pre>"]
    )
  ]

main :: IO ()
main = do
  results <- forM tests $ \(name, action) -> do
    ok <- action
    putStrLn ((if ok then "ok   - " else "FAIL - ") ++ name)
    pure ok
  let failures = length (filter not results)
  unless (failures == 0) $ do
    putStrLn (show failures ++ " test(s) failed")
    exitFailure
  putStrLn ("All " ++ show (length results) ++ " tests passed")
