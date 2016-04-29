{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ViewPatterns #-}

-- | Implementation of a 'Storable' deriver for data types. This works for
-- any non-recursive datatype which has 'Storable' fields.
--
-- Most users won't need to import this module directly. Instead, use
-- 'derive' / 'Deriving' to create 'Storable' instances.
module TH.Derive.Storable
    ( makeStorableInst
    ) where

import           Control.Monad
import           Data.Data (Data, gmapT)
import           Data.Generics.Aliases (extT)
import           Data.List (find)
import qualified Data.Map as M
import           Data.Maybe (fromMaybe)
import           Data.Primitive.Types (Prim(..))
import           Data.Typeable
import           Data.Word
import           Foreign.Ptr
import           Foreign.Storable
import           Language.Haskell.TH
import           Language.Haskell.TH.Syntax
import           TH.ReifyDataType
import           TH.Utilities
import           TH.Derive.Internal

instance Deriver (Storable a) where
    runDeriver _ = makeStorableInst

-- | Implementation used for 'runDeriver'.
makeStorableInst :: Cxt -> Type -> Q [Dec]
makeStorableInst cxt ty = do
    argTy <- expectTyCon1 ''Storable ty
    dt <- reifyDataTypeSubstituted argTy
    makeStorableImpl cxt ty (dtCons dt)

-- TODO: recursion check? At least document that this could in some
-- cases work, but produce a bogus instance.

makeStorableImpl :: Cxt -> Type -> [DataCon] -> Q [Dec]
makeStorableImpl cxt headTy cons = do
    -- Since this instance doesn't pay attention to alignment, we
    -- just say alignment doesn't matter.
    alignmentMethod <- [| 1 |]
    sizeOfMethod <- sizeExpr
    peekMethod <- peekExpr
    pokeMethod <- pokeExpr
    let methods =
            [ FunD (mkName "alignment") [Clause [WildP] (NormalB alignmentMethod) []]
            , FunD (mkName "sizeOf") [Clause [WildP] (NormalB sizeOfMethod) []]
            , FunD (mkName "peek") [Clause [VarP ptrName] (NormalB peekMethod) []]
            , FunD (mkName "poke") [Clause [VarP ptrName, VarP valName] (NormalB pokeMethod) []]
            ]
    return [InstanceD cxt headTy methods]
  where
    -- NOTE: Much of the code here resembles code in store for deriving
    -- Store instances. Changes here may be relevant there as well.
    (tagType, _, tagSize) =
        fromMaybe (error "Too many constructors") $
        find (\(_, maxN, _) -> maxN >= length cons) tagTypes
    tagTypes :: [(Name, Int, Int)]
    tagTypes =
        [ ('(), 1, 0)
        , (''Word8, fromIntegral (maxBound :: Word8), 1)
        , (''Word16, fromIntegral (maxBound :: Word16), 2)
        , (''Word32, fromIntegral (maxBound :: Word32), 4)
        , (''Word64, fromIntegral (maxBound :: Word64), 8)
        ]
    valName = mkName "val"
    tagName = mkName "tag"
    ptrName = mkName "ptr"
    fName ix = mkName ("f" ++ show ix)
    ptrExpr = varE ptrName
    -- [[Int]] expression, where the inner lists are the sizes of the
    -- fields. Each member of the outer list corresponds to a different
    -- constructor.
    sizeExpr = appE (varE 'maximum) $
        listE [ appE (varE 'sum) (listE [sizeOfExpr ty | (_, ty) <- fields])
              | (DataCon cname _ _ fields) <- cons
              ]
    -- Choose a tag size large enough for this constructor count.
    -- Expression used for the definition of peek.
    peekExpr = case cons of
        [] -> [| error ("Attempting to peek type with no constructors (" ++ $(lift (pprint headTy)) ++ ")") |]
        [con] -> peekCon con
        _ -> doE
            [ bindS (varP tagName) [| peek (castPtr $(ptrExpr)) |]
            , noBindS (caseE (sigE (varE tagName) (conT tagType))
                             (map peekMatch (zip [0..] cons) ++ [peekErr]))
            ]
    peekMatch (ix, con) = match (litP (IntegerL ix)) (normalB (peekCon con)) []
    peekErr = match wildP (normalB [| error ("Found invalid tag while peeking (" ++ $(lift (pprint headTy)) ++ ")") |]) []
    peekCon (DataCon cname _ _ fields) =
        letE (offsetDecls fields) $
        case fields of
            [] -> [| pure $(conE cname) |]
            (_:fields') ->
                foldl (\acc (ix, _) -> [| $(acc) <*> $(peekOffset ix) |] )
                      [| $(conE cname) <$> $(peekOffset 0) |]
                      (zip [1..] fields')
    peekOffset ix = [| peek (castPtr (plusPtr $(ptrExpr) $(varE (offset ix)))) |]
    -- Expression used for the definition of poke.
    pokeExpr = caseE (varE valName) (map pokeMatch (zip [0..] cons))
    pokeMatch :: (Int, DataCon) -> MatchQ
    pokeMatch (ixcon, DataCon cname _ _ fields) =
        match (conP cname (map varP (map fName ixs)))
              (normalB (doE (tagPokes ++ offsetLet ++ fieldPokes)))
              []
      where
        tagPokes = case cons of
            (_:_:_) -> [noBindS [| poke (castPtr $(ptrExpr)) (ixcon :: $(conT tagType)) |]]
            _ -> []
        offsetLet
            | null ixs = []
            | otherwise = [letS (offsetDecls fields)]
        fieldPokes = map (noBindS . pokeField) ixs
        ixs = map fst (zip [0..] fields)
    pokeField ix = [| poke (castPtr (plusPtr $(ptrExpr)
                                             $(varE (offset ix))))
                           $(varE (fName ix)) |]
    -- Generate declarations which compute the field offsets.
    offsetDecls fields =
        -- Skip the last one, to avoid unused variable warnings.
        init $
        map (\(ix, expr) -> valD (varP (offset ix)) (normalB expr) []) $
        -- Initial offset is the tag size.
        ((0, [| tagSize |]) :) $
        map (\(ix, (_, ty)) -> (ix, offsetExpr ix ty)) $
        zip [1..] fields
      where
        offsetExpr ix ty = [| $(sizeOfExpr ty) + $(varE (offset (ix - 1))) |]
    sizeOfExpr ty = [| $(varE 'sizeOf) (error "sizeOf evaluated its argument" :: $(return ty)) |]
    offset ix = mkName ("offset" ++ show ix)
