{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE OverloadedStrings #-}
module Syntax.Direction where

import Protolude hiding (TypeRep)

import Data.Hashable.Lifted
import Data.Vector(Vector)

import Pretty
import Syntax.Annotation
import Syntax.Extern
import TypeRep

data Direction = Direct TypeRep | Indirect
  deriving (Eq, Ord, Show, Generic, Hashable)

instance Pretty Direction where
  prettyM (Direct rep) = "direct(" <> prettyM rep <> ")"
  prettyM Indirect = "indirect"

instance PrettyAnnotation Direction where
  prettyAnnotation (Direct rep) = prettyTightApp (prettyM rep <> "~")
  prettyAnnotation Indirect = prettyTightApp "&"

data ReturnDirection a
  = ReturnDirect TypeRep
  | ReturnIndirect a
  deriving (Eq, Ord, Show, Functor, Foldable, Traversable, Generic, Hashable, Generic1, Hashable1)

instance Pretty a => Pretty (ReturnDirection a) where
  prettyM (ReturnDirect sz) = "direct(" <> prettyM sz <> ")"
  prettyM (ReturnIndirect a) = "indirect" <+> prettyM a

instance PrettyAnnotation a => PrettyAnnotation (ReturnDirection a) where
  prettyAnnotation (ReturnDirect rep) = prettyTightApp (prettyM rep <> "~")
  prettyAnnotation (ReturnIndirect a) = prettyAnnotation a

data ReturnIndirect
  = Projection
  | OutParam
  deriving (Eq, Ord, Show, Generic, Hashable)

instance PrettyAnnotation ReturnIndirect where
  prettyAnnotation Projection = prettyTightApp "*"
  prettyAnnotation OutParam = prettyTightApp "&"

instance Pretty ReturnIndirect where
  prettyM OutParam = "outparam"
  prettyM Projection = "projection"

type RetDir = ReturnDirection ReturnIndirect

toReturnDirection :: d -> Direction -> ReturnDirection d
toReturnDirection _ (Direct sz) = ReturnDirect sz
toReturnDirection d Indirect = ReturnIndirect d

-- | Should the name be mangled and calling convention be adjusted to be C-compatible?
data Compatibility
  = CompatibleWith Language
  | SixtenCompatible
  deriving (Eq, Ord, Show, Generic, Hashable)

data Signature a
  = FunctionSig Compatibility (ReturnDirection a) (Vector Direction)
  | ConstantSig Direction
  deriving (Eq, Ord, Show, Functor, Foldable, Traversable, Generic, Hashable, Generic1, Hashable1)
