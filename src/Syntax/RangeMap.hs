------------------------------------------------------------------------------
-- Copyright 2012-2021, Microsoft Research, Daan Leijen.
--
-- This is free software; you can redistribute it and/or modify it under the
-- terms of the Apache License, Version 2.0. A copy of the License can be
-- found in the LICENSE file at the root of this distribution.
-----------------------------------------------------------------------------
module Syntax.RangeMap( RangeMap, RangeInfo(..), NameInfo(..)
                      , rangeMapNew
                      , rangeMapInsert
                      , rangeMapSort
                      , rangeMapLookup
                      , rangeMapFindAt
                      , rangeMapFindIn
                      , rangeMapFind
                      , rangeMapAppend
                      , rangeInfoType
                      , mangle
                      , mangleConName
                      , mangleTypeName
                      ) where

import Debug.Trace(trace)
import Data.Char    ( isSpace )
import Common.Failure
import Data.List    (sortBy, groupBy, minimumBy, foldl')
import Lib.PPrint
import Common.Range
import Common.Name
import Common.NamePrim (nameUnit, nameListNil, isNameTuple)
import Common.File( startsWith )
import Type.Type
import Kind.Kind
import Type.TypeVar
import Type.Pretty()
import Data.Maybe (fromMaybe)
import Syntax.Lexeme

newtype RangeMap = RM [(Range,RangeInfo)]
  deriving Show

mangleConName :: Name -> Name
mangleConName name
  = prepend "con " name

mangleTypeName :: Name -> Name
mangleTypeName name
  = prepend "type " name

mangle :: Name -> Type -> Name
mangle name tp
  = name
  -- newQualified (nameModule name) (nameId name ++ ":" ++ compress (show tp))
  where
    compress cs
      = case cs of
          [] -> []
          (c:cc) ->
            if (isSpace c)
             then ' ' : compress (dropWhile isSpace cc)
             else c : compress cc

data RangeInfo
  = Decl String Name Name  -- alias, type, cotype, rectype, fun, val
  | Block String           -- type, kind, pattern
  | Error Doc
  | Warning Doc
  | Id Name NameInfo [Doc] Bool  -- qualified name, info, extra doc (from implicits), is this the definition?
  | Implicits Doc                -- inferred implicit arguments

data NameInfo
  = NIValue   Type String Bool -- Has annotated type already
  | NICon     Type String
  | NITypeCon Kind
  | NITypeVar Kind
  | NIModule
  | NIKind


instance Show RangeInfo where
  show ri
    = case ri of
        Decl kind nm1 nm2 -> "Decl " ++ kind ++ " " ++ show nm1 ++ " " ++ show nm2
        Block kind        -> "Block " ++ kind
        Error doc         -> "Error"
        Warning doc       -> "Warning"
        Id name info docs isDef -> "Id " ++ show name ++ (if isDef then " (def)" else "") ++ " " ++ show docs
        Implicits doc        -> "Implicits " ++ show doc

instance Enum RangeInfo where
  fromEnum r
    = case r of
        Decl _ name _    -> 0
        Block _          -> 10
        Id name info _ _ -> 20
        Implicits _      -> 25
        Warning _        -> 40
        Error _          -> 50

  toEnum i
    = failure "Syntax.RangeMap.RangeInfo.toEnum"

penalty :: Name -> Int
penalty name
  = if (nameModule name == "std/core/hnd")
     then 10 else 0

-- (inverse) priorities
instance Enum NameInfo where
  fromEnum ni
    = case ni of
        NIValue _ _ _   -> 1
        NICon   _ _  -> 2
        NITypeCon _ -> 3
        NITypeVar _ -> 4
        NIModule    -> 5
        NIKind      -> 6

  toEnum i
    = failure "Syntax.RangeMap.NameInfo.toEnum"

isHidden ri
  = case ri of
      Decl kind nm1 nm2       -> isHiddenName nm1
      Id name info docs isDef -> isHiddenName name
      _ -> False


rangeMapNew :: RangeMap
rangeMapNew
  = RM []

cut r
  = (makeRange (rangeStart r) (rangeStart r))

rangeMapInsert :: Range -> RangeInfo -> RangeMap -> RangeMap
rangeMapInsert r info (RM rm)
  = -- trace ("rangemap insert: " ++ show r ++ ": " ++ show info) $
    if isHidden info
     then RM rm
    else if beginEndToken info
     then RM ((r,info):(makeRange (rangeEnd r) (rangeEnd r),info):rm)
     else RM ((r,info):rm)
  where
    beginEndToken info
      = case info of
          Id name _ _ _ -> (name == nameUnit || name == nameListNil || isNameTuple name)
          _ -> False

rangeMapAppend :: RangeMap -> RangeMap -> RangeMap
rangeMapAppend (RM rm1) (RM rm2)
  = RM (rm1 ++ rm2)

rangeMapSort :: RangeMap -> RangeMap
rangeMapSort (RM rm)
  = RM (sortBy (\(r1,_) (r2,_) -> compare r1 r2) rm)

-- | select the best matching range infos from a selection
prioritize :: [(Range,RangeInfo)] -> [(Range,RangeInfo)]
prioritize rinfos
  = let idocs = concatMap (\(_,rinfo) -> case rinfo of
                                            Implicits doc -> [doc]
                                            _             -> []) rinfos
    in map (mergeDocs idocs) $
        map last $
        groupBy eq $
        sortBy cmp $
        filter (not . isImplicits . snd) rinfos
  where
    isImplicits (Implicits _) = True
    isImplicits _             = False

    eq (_,ri1) (_,ri2)  = (EQ == compare ((fromEnum ri1) `div` 10) ((fromEnum ri2) `div` 10))
    cmp (_,ri1) (_,ri2) = compare (fromEnum ri1) (fromEnum ri2)

    -- merge implicit documentation into identifiers
    mergeDocs ds (rng, Id name info docs isDef) = (rng, Id name info (docs ++ ds) isDef)
    mergeDocs ds x = x


rangeMapLookup :: Range -> RangeMap -> ([(Range,RangeInfo)],RangeMap)
rangeMapLookup r (RM rm)
  = let (rinfos,rm') = span startsAt (dropWhile isBefore rm)
    in -- trace ("lookup: " ++ show r ++ ": " ++ show rinfos) $
       (prioritize rinfos, RM rm')
  where
    pos = rangeStart r
    isBefore (rng,_)  = rangeStart rng < pos
    startsAt (rng,_)  = rangeStart rng == pos

rangeMapFindIn :: Range -> RangeMap -> [(Range, RangeInfo)]
rangeMapFindIn rng (RM rm)
  = filter (\(rng, info) -> rangeStart rng >= start || rangeEnd rng <= end) rm
    where start = rangeStart rng
          end = rangeEnd rng

-- we should use the lexemes to find the right start token
rangeMapFindAt :: [Lexeme] -> Pos -> RangeMap -> Maybe (Range, RangeInfo)
rangeMapFindAt lexemes pos (RM rm)
  = let lexStart  = case dropWhile (\lex -> not (rangeContains (getRange lex) pos)) lexemes of
                      (lex:_) -> rangeStart (getRange lex)
                      []      -> pos
        rinfos    = takeWhile (\(rng,_) -> rangeStart rng == lexStart) $
                    dropWhile (\(rng,_) -> rangeStart rng < lexStart) rm
    in  {- trace ("range map find at: " ++ show pos ++ "\n"
               ++ "start pos: " ++ show lexStart ++ "\n"
               ++ "rinfos: " ++ show rinfos ++ "\n"
               ++ "prioritized: " ++ show (prioritize rinfos)
               -- ++ unlines (map show lexemes)
               -- ++ unlines (map show rm)
             ) $ -}
        maybeHead (prioritize rinfos)

maybeHead []    = Nothing
maybeHead (x:_) = Just x


rangeMapFind :: Range -> RangeMap -> [(Range, RangeInfo)]
rangeMapFind rng (RM rm)
  = filter ((== rng) . fst) rm

minimumByList :: Foldable t => (a -> a -> Ordering) -> t a -> [a]
minimumByList cmp la = fromMaybe [] (foldl' min' Nothing la)
  where
    min' mx y = Just $! case mx of
      Nothing -> [y]
      Just (x:xs) -> case cmp x y of
        GT -> [y]
        EQ -> y:x:xs
        _ -> x:xs

rangeInfoType :: RangeInfo -> Maybe Type
rangeInfoType ri
  = case ri of
      Id _ info _ _ -> case info of
                          NIValue tp _ _  -> Just tp
                          NICon tp _      -> Just tp
                          _               -> Nothing
      _ -> Nothing

rangeInfoDoc :: RangeInfo -> Maybe String
rangeInfoDoc ri
  = case ri of
      Id _ info _ _ -> case info of
                         NIValue _ doc _ -> Just doc
                         NICon _ doc  -> Just doc

      _ -> Nothing

instance HasTypeVar RangeMap where
  sub `substitute` (RM rm)
    = RM (map (\(r,ri) -> (r,sub `substitute` ri)) rm)

  ftv (RM rm)
    = ftv (map snd rm)

  btv (RM rm)
    = btv (map snd rm)

instance HasTypeVar RangeInfo where
  sub `substitute` (Id nm info docs isdef)  = Id nm (sub `substitute` info) docs isdef
  sub `substitute` ri                       = ri

  ftv (Id nm info _ _) = ftv info
  ftv ri               = tvsEmpty

  btv (Id nm info _ _) = btv info
  btv ri               = tvsEmpty

instance HasTypeVar NameInfo where
  sub `substitute` ni
    = case ni of
        NIValue tp annotated doc  -> NIValue (sub `substitute` tp) annotated doc
        NICon tp doc   -> NICon (sub `substitute` tp) doc
        _           -> ni

  ftv ni
    = case ni of
        NIValue tp _ _ -> ftv tp
        NICon tp _   -> ftv tp
        _           -> tvsEmpty

  btv ni
    = case ni of
        NIValue tp _ _  -> btv tp
        NICon tp _    -> btv tp
        _           -> tvsEmpty
