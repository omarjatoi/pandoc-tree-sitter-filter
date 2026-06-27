{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Turn a snippet of source code into highlighted HTML using tree-sitter.
--
-- The flow is: compile the grammar's @highlights.scm@ into a 'TSQuery', run it
-- over the parsed source (in the C shim), then fold the resulting capture spans
-- down to a per-byte "winning" capture and emit @<span>@-wrapped HTML.
module PandocTreeSitterFilter.Highlight
  ( highlightToHtml,
  )
where

import Control.Exception (finally)
import Control.Monad (forM, when)
import Data.Array.ST (newArray, runSTUArray, writeArray)
import Data.Array.Unboxed (UArray, bounds, (!))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Unsafe as BU
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Foreign.C.String (peekCStringLen)
import Foreign.C.Types (CUInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Marshal.Array (peekArray)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (peek)
import PandocTreeSitterFilter.FFI

-- | @highlightToHtml lang query name code@ produces an HTML fragment
-- (@\<pre\>\<code\>...\</code\>\</pre\>@) for @code@, highlighted with the
-- grammar @lang@ and its @highlights.scm@ @query@. @name@ is the language name,
-- used for a @data-lang@ attribute.
highlightToHtml :: Ptr TSLanguage -> BS.ByteString -> Text -> Text -> IO Text
highlightToHtml lang queryBytes name code = do
  let codeBytes = TE.encodeUtf8 code
  spans <- collectSpans lang queryBytes codeBytes
  pure (renderHtml name codeBytes spans)

-- | A resolved highlight span: a byte range, its capture name (e.g.
-- @"keyword"@, @"function.special"@), and the query pattern index it came from
-- (later patterns win ties between equally-wide overlapping captures).
data NamedSpan = NamedSpan
  { nsStart :: !Int,
    nsEnd :: !Int,
    nsName :: !Text,
    nsPattern :: !Int
  }

-- | Compile the query, run it over the source via the C shim, and resolve each
-- capture index back to its name.
collectSpans :: Ptr TSLanguage -> BS.ByteString -> BS.ByteString -> IO [NamedSpan]
collectSpans lang queryBytes codeBytes =
  BU.unsafeUseAsCStringLen queryBytes $ \(qPtr, qLen) ->
    alloca $ \errOffset ->
      alloca $ \errType -> do
        query <- c_ts_query_new lang qPtr (fromIntegral qLen) errOffset errType
        when (query == nullPtr) $ do
          off <- peek errOffset
          fail
            ( "tree-sitter: failed to parse highlights query at byte offset "
                ++ show (off :: CUInt)
            )
        collect query `finally` c_ts_query_delete query
  where
    collect query =
      BU.unsafeUseAsCStringLen codeBytes $ \(cPtr, cLen) ->
        alloca $ \countPtr -> do
          spansPtr <- c_ts_hl_collect lang query cPtr (fromIntegral cLen) countPtr
          if spansPtr == nullPtr
            then pure []
            else do
              count <- peek countPtr
              raw <- peekArray (fromIntegral count) spansPtr
              c_ts_hl_free spansPtr
              forM raw $ \s -> do
                nm <- captureName query (spanCapture s)
                pure
                  ( NamedSpan
                      (fromIntegral (spanStart s))
                      (fromIntegral (spanEnd s))
                      nm
                      (fromIntegral (spanPattern s))
                  )

-- | Look up the textual name of a capture by its query index.
captureName :: Ptr TSQuery -> CUInt -> IO Text
captureName query idx =
  alloca $ \lenPtr -> do
    cstr <- c_ts_query_capture_name_for_id query idx lenPtr
    len <- peek lenPtr
    T.pack <$> peekCStringLen (cstr, fromIntegral (len :: CUInt))

-- | Render the source bytes to HTML, colouring each byte by the most specific
-- (narrowest) capture that covers it.
renderHtml :: Text -> BS.ByteString -> [NamedSpan] -> Text
renderHtml name codeBytes spans =
  T.concat
    [ "<pre class=\"tree-sitter\" data-lang=\"",
      escapeAttr name,
      "\"><code>",
      body,
      "</code></pre>"
    ]
  where
    n = BS.length codeBytes

    -- Map every capture name to a small integer id (0 reserved for "no
    -- capture") so we can use an unboxed array for the per-byte winner.
    namesList = uniq (map nsName spans)
    nameToId = Map.fromList (zip namesList [1 ..]) :: Map.Map Text Int
    idToName = Map.fromList (zip [1 ..] namesList) :: Map.Map Int Text

    -- Per-byte winning capture id. We want each byte coloured by the narrowest
    -- (most specific) span covering it, and for spans of equal width the one
    -- from the later query pattern (tree-sitter's convention: later patterns
    -- override earlier, more general ones). We get that by applying spans in
    -- order of *increasing* precedence (widest first; for equal width, lower
    -- pattern index first) so the winner is written last.
    owners :: UArray Int Int
    owners = runSTUArray $ do
      arr <- newArray (0, max 0 (n - 1)) 0
      let ordered =
            sortOn (\s -> (Down (nsEnd s - nsStart s), nsPattern s)) spans
      mapM_ (fillSpan arr) ordered
      pure arr
      where
        fillSpan arr s =
          let i0 = clamp (nsStart s)
              i1 = clamp (nsEnd s)
              cid = Map.findWithDefault 0 (nsName s) nameToId
           in mapM_ (\i -> writeArray arr i cid) [i0 .. i1 - 1]
        clamp = max 0 . min n

    body = if n == 0 then "" else T.concat (map renderGroup (groups owners))

    -- Split [0,n) into maximal runs of equal owner id.
    groups :: UArray Int Int -> [(Int, Int, Int)]
    groups arr = go 0
      where
        (_, hi) = bounds arr
        go i
          | i > hi = []
          | otherwise =
              let cid = arr ! i
                  j = runEnd cid (i + 1)
               in (i, j, cid) : go j
        runEnd cid j
          | j <= hi && arr ! j == cid = runEnd cid (j + 1)
          | otherwise = j

    renderGroup (i, j, cid) =
      let chunk = escapeHtml (decodeSlice codeBytes i j)
       in case Map.lookup cid idToName of
            Nothing -> chunk
            Just nm -> T.concat ["<span class=\"", classFor nm, "\">", chunk, "</span>"]

-- | Decode the UTF-8 byte slice @[i, j)@. Capture boundaries always fall on
-- character boundaries, so this never splits a multi-byte sequence.
decodeSlice :: BS.ByteString -> Int -> Int -> Text
decodeSlice bs i j = TE.decodeUtf8 (BS.take (j - i) (BS.drop i bs))

-- | tree-sitter capture names are dotted hierarchies (@function.special@);
-- emit them as a CSS class like @ts-function-special@.
classFor :: Text -> Text
classFor nm = "ts-" <> T.replace "." "-" nm

escapeHtml :: Text -> Text
escapeHtml =
  T.replace ">" "&gt;"
    . T.replace "<" "&lt;"
    . T.replace "&" "&amp;"

escapeAttr :: Text -> Text
escapeAttr = T.replace "\"" "&quot;" . escapeHtml

uniq :: (Ord a) => [a] -> [a]
uniq = go mempty
  where
    go _ [] = []
    go seen (x : xs)
      | x `Map.member` seen = go seen xs
      | otherwise = x : go (Map.insert x () seen) xs
