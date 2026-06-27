module Main where

import qualified PandocTreeSitterFilter (highlight)
import Text.Pandoc.JSON

main :: IO ()
main = do
  toJSONFilter PandocTreeSitterFilter.highlight
