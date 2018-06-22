{-# LANGUAGE DeriveFoldable, DeriveFunctor, DeriveTraversable, FlexibleContexts, FlexibleInstances, GADTs, OverloadedStrings, TemplateHaskell #-}
module Syntax.Pre.Definition where

import Data.Bifunctor
import Data.Bitraversable
import Data.Deriving
import Data.Foldable
import Data.Functor.Classes
import Data.HashSet(HashSet)
import Data.List.NonEmpty(NonEmpty)
import Data.Traversable
import qualified Data.Vector as Vector
import Data.Vector(Vector)

import Syntax hiding (Definition, DataDefinition)
import Syntax.Pre.Pattern

data Definition expr v
  = ConstantDefinition (ConstantDef expr v)
  | DataDefinition (DataDef expr v)
  | ClassDefinition (ClassDef expr v)
  | InstanceDefinition (PatInstanceDef expr v)
  deriving (Foldable, Functor, Show, Traversable)

data Clause expr v = Clause
  { clausePatterns :: Vector (Plicitness, Pat (HashSet QConstr) (Scope PatternVar expr v) ())
  , clauseScope :: Scope PatternVar expr v
  } deriving Show

data ConstantDef expr v
  = ConstantDef Abstract IsInstance (NonEmpty (Clause expr v)) (Maybe (expr v))
  deriving (Foldable, Functor, Show, Traversable)

data PatInstanceDef expr v = PatInstanceDef
  { instanceType :: expr v
  , instanceMethods :: Vector (Name, SourceLoc, ConstantDef expr v)
  }
  deriving (Foldable, Functor, Show, Traversable)

instantiateLetConstantDef
  :: Monad expr
  => (b -> expr v)
  -> Vector b
  -> ConstantDef expr (Var LetVar v)
  -> ConstantDef expr v
instantiateLetConstantDef f vs = instantiateConstantDef (f . (vs Vector.!) . unLetVar)

instantiateConstantDef
  :: Monad expr
  => (b -> expr v)
  -> ConstantDef expr (Var b v)
  -> ConstantDef expr v
instantiateConstantDef f (ConstantDef a i cls mtyp)
  = ConstantDef a i (instantiateClause f <$> cls) ((>>= unvar f pure) <$> mtyp)

abstractConstantDef
  :: Monad expr
  => (v -> Maybe b)
  -> ConstantDef expr v
  -> ConstantDef expr (Var b v)
abstractConstantDef f (ConstantDef a i cls mtyp)
  = ConstantDef a i (abstractClause f <$> cls) (fmap go <$> mtyp)
  where
    go v = case f v of
      Nothing -> F v
      Just b -> B b

instantiateClause
  :: Monad expr
  => (b -> expr v)
  -> Clause expr (Var b v)
  -> Clause expr v
instantiateClause f (Clause pats s) = Clause (fmap (first go) <$> pats) (go s)
  where
    go = (>>>= unvar f pure)

abstractClause
  :: Monad expr
  => (v -> Maybe b)
  -> Clause expr v
  -> Clause expr (Var b v)
abstractClause f (Clause pats s) = Clause (fmap (first $ fmap go) <$> pats) (go <$> s)
  where
    go v = case f v of
      Nothing -> F v
      Just b -> B b

-------------------------------------------------------------------------------
-- Instances
instance Traversable expr => Functor (Clause expr) where
  fmap = fmapDefault
instance Traversable expr => Foldable (Clause expr) where
  foldMap = foldMapDefault
instance Traversable expr => Traversable (Clause expr) where
  traverse f (Clause pats s) = Clause <$> traverse (traverse $ bitraverse (traverse f) pure) pats <*> traverse f s

instance Bound Definition where
  ConstantDefinition d >>>= f = ConstantDefinition $ d >>>= f
  DataDefinition ddef >>>= f = DataDefinition $ ddef >>>= f
  ClassDefinition classDef >>>= f = ClassDefinition $ classDef >>>= f
  InstanceDefinition instanceDef >>>= f = InstanceDefinition $ instanceDef >>>= f

instance GBound Definition where
  gbound f (ConstantDefinition d) = ConstantDefinition $ gbound f d
  gbound f (DataDefinition ddef) = DataDefinition $ gbound f ddef
  gbound f (ClassDefinition classDef) = ClassDefinition $ gbound f classDef
  gbound f (InstanceDefinition instanceDef) = InstanceDefinition $ gbound f instanceDef

instance Bound ConstantDef where
  ConstantDef a i cls mtyp >>>= f = ConstantDef a i ((>>>= f) <$> cls) ((>>= f) <$> mtyp)

instance GBound ConstantDef where
  gbound f (ConstantDef a i cls mtyp) = ConstantDef a i (gbound f <$> cls) (gbind f <$> mtyp)

instance Bound PatInstanceDef where
  PatInstanceDef typ ms >>>= f = PatInstanceDef (typ >>= f) $ (\(name, loc, def) -> (name, loc, def >>>= f)) <$> ms

instance GBound PatInstanceDef where
  gbound f (PatInstanceDef typ ms) = PatInstanceDef (gbind f typ) $ (\(name, loc, def) -> (name, loc, gbound f def)) <$> ms

$(return mempty)

instance (Eq1 expr, Monad expr) => Eq1 (Clause expr) where
  liftEq f (Clause ps1 s1) (Clause ps2 s2)
    = liftEq (\(p1, pat1) (p2, pat2) -> p1 == p2 && liftPatEq (==) (liftEq f) (==) pat1 pat2) ps1 ps2
    && liftEq f s1 s2

instance Bound Clause where
  Clause pats s >>>= f = Clause (fmap (first (>>>= f)) <$> pats) (s >>>= f)

instance GBound Clause where
  gbound f (Clause pats s) = Clause (fmap (first $ gbound f) <$> pats) (gbound f s)

instance (Pretty (expr v), Monad expr, v ~ Doc)
  => PrettyNamed (Clause expr v) where
  prettyNamed name (Clause pats s)
    = withNameHints (nameHints . snd =<< pats) $ \ns -> do
      let go (p, pat)
            = prettyAnnotation p
            $ prettyM $ first (instantiatePattern (pure . fromName) ns) pat
          -- removeVoid = mapBound $ unvar id absurd
      prettyApps name (go <$> renamePatterns ns pats)
        <+> "=" <+> prettyM (instantiatePattern (pure . fromName) ns s)

instance (Pretty (expr v), Monad expr, v ~ Doc)
  => Pretty (Clause expr v) where
  prettyM = prettyNamed "_"

instance (Pretty (expr v), Monad expr, Eq1 expr, v ~ Doc)
  => Pretty (Definition expr v) where
  prettyM = prettyNamed "_"

instance (Pretty (expr v), Monad expr, Eq1 expr, v ~ Doc)
  => PrettyNamed (Definition expr v) where
  prettyNamed name (ConstantDefinition d) = prettyNamed name d
  prettyNamed name (DataDefinition d) = prettyNamed name d
  prettyNamed name (ClassDefinition c) = prettyNamed name c
  prettyNamed name (InstanceDefinition i) = prettyNamed name i

instance (Pretty (expr v), Monad expr, v ~ Doc)  => PrettyNamed (ConstantDef expr v) where
  prettyNamed name (ConstantDef a i clauses mtyp) = prettyM a <+> prettyM i <$$> vcat ([prettyM name <+> ":" <+> prettyM typ | Just typ <- [mtyp]] ++ toList (prettyNamed name <$> clauses))

instance (Eq1 expr, Monad expr) => Eq1 (ConstantDef expr) where
  liftEq = $(makeLiftEq ''ConstantDef)

instance (Pretty (expr v), Monad expr, v ~ Doc) => PrettyNamed (PatInstanceDef expr v) where
  prettyNamed name (PatInstanceDef typ ms) = name <+> "=" <+> "instance" <+> prettyM typ <+> "where" <$$> do
    let go (n, _, m) = prettyNamed (prettyM n) m
    indent 2 (vcat $ go <$> ms)
