{-# LANGUAGE ForeignFunctionInterface #-}

-- | Minimal FFI bindings to libtree-sitter plus our C shim ('ts_shim.c').
--
-- We deliberately bind only the handful of functions needed for highlighting.
-- Anything that involves passing a @TSNode@ by value is handled in the C shim
-- ('c_ts_hl_collect'), so the Haskell side only ever deals with opaque pointers
-- and flat arrays.
module PandocTreeSitterFilter.FFI
  ( TSLanguage,
    TSQuery,
    TSHLSpan (..),
    c_ts_query_new,
    c_ts_query_delete,
    c_ts_query_capture_name_for_id,
    c_ts_hl_collect,
    c_ts_hl_free,
  )
where

import Foreign.C.String (CString)
import Foreign.C.Types (CUInt (..))
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (Storable (..))

-- | Opaque @TSLanguage@. Obtained from a grammar's @tree_sitter_<lang>@ symbol.
data TSLanguage

-- | Opaque @TSQuery@ (a compiled highlights query).
data TSQuery

-- | A single highlight span, mirroring @TSHLSpan@ in @cbits/ts_shim.c@: a byte
-- range, the query capture index that applies to it, and the index of the
-- query pattern it came from (used to break ties between overlapping captures).
data TSHLSpan = TSHLSpan
  { spanStart :: !CUInt,
    spanEnd :: !CUInt,
    spanCapture :: !CUInt,
    spanPattern :: !CUInt
  }

instance Storable TSHLSpan where
  sizeOf _ = 4 * sizeOf (undefined :: CUInt)
  alignment _ = alignment (undefined :: CUInt)
  peek p = do
    let q = castPtr p :: Ptr CUInt
    s <- peekElemOff q 0
    e <- peekElemOff q 1
    c <- peekElemOff q 2
    pat <- peekElemOff q 3
    pure (TSHLSpan s e c pat)
  poke p (TSHLSpan s e c pat) = do
    let q = castPtr p :: Ptr CUInt
    pokeElemOff q 0 s
    pokeElemOff q 1 e
    pokeElemOff q 2 c
    pokeElemOff q 3 pat

-- ts_query_new(language, source, source_len, *error_offset, *error_type)
foreign import ccall unsafe "ts_query_new"
  c_ts_query_new ::
    Ptr TSLanguage -> CString -> CUInt -> Ptr CUInt -> Ptr CUInt -> IO (Ptr TSQuery)

foreign import ccall unsafe "ts_query_delete"
  c_ts_query_delete :: Ptr TSQuery -> IO ()

-- ts_query_capture_name_for_id(query, id, *length) -> const char*
foreign import ccall unsafe "ts_query_capture_name_for_id"
  c_ts_query_capture_name_for_id :: Ptr TSQuery -> CUInt -> Ptr CUInt -> IO CString

-- Our shim: ts_hl_collect(language, query, source, source_len, *out_count)
foreign import ccall unsafe "ts_hl_collect"
  c_ts_hl_collect ::
    Ptr TSLanguage -> Ptr TSQuery -> CString -> CUInt -> Ptr CUInt -> IO (Ptr TSHLSpan)

foreign import ccall unsafe "ts_hl_free"
  c_ts_hl_free :: Ptr TSHLSpan -> IO ()
