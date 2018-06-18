{-# LANGUAGE DeriveFoldable, DeriveFunctor, DeriveTraversable, FlexibleContexts, FlexibleInstances, GADTs, OverloadedStrings, TemplateHaskell #-}
module Syntax.Pre.Definition where

import Control.Monad
import Data.Bifunctor
import Data.Bitraversable
import Data.Deriving
import Data.Functor.Classes
import Data.HashSet(HashSet)
import Data.List.NonEmpty(NonEmpty)
import Data.Maybe
import Data.Traversable
import qualified Data.Vector as Vector
import Data.Vector(Vector)
import Data.Void

import Syntax
import Syntax.Pre.Pattern
import Util

data TopLevelPatDefinition expr v
  = TopLevelPatDefinition (PatDefinition (Clause Void expr v))
  | TopLevelPatDataDefinition (DataDef expr v)
  | TopLevelPatClassDefinition (ClassDef expr v)
  | TopLevelPatInstanceDefinition (PatInstanceDef expr v)
  deriving (Foldable, Functor, Show, Traversable)

data PatDefinition clause
  = PatDefinition Abstract IsInstance (NonEmpty clause)
  deriving (Foldable, Functor, Show, Traversable)

data PatInstanceDef expr v = PatInstanceDef (Vector (Name, SourceLoc, PatDefinition (Clause Void expr v), Maybe (expr v)))
  deriving (Foldable, Functor, Show, Traversable)

data Clause b expr v = Clause
  { clausePatterns :: Vector (Plicitness, Pat (HashSet QConstr) (Scope (Var PatternVar b) expr v) ())
  , clauseScope :: Scope (Var PatternVar b) expr v
  } deriving (Show)

clausePatterns'
  :: Functor expr
  => Clause Void expr v
  -> Vector (Plicitness, Pat (HashSet QConstr) (Scope PatternVar expr v) ())
clausePatterns' (Clause pats _) = fmap (first $ mapBound $ unvar id absurd) <$> pats

clauseScope'
  :: Functor expr
  => Clause Void expr v
  -> Scope PatternVar expr v
clauseScope' (Clause _ s) = mapBound (unvar id absurd) s

-------------------------------------------------------------------------------
-- Instances
instance Traversable expr => Functor (Clause b expr) where fmap = fmapDefault
instance Traversable expr => Foldable (Clause b expr) where foldMap = foldMapDefault

instance Traversable expr => Traversable (Clause b expr) where
  traverse f (Clause pats s)
    = Clause
    <$> traverse (traverse (bitraverse (traverse f) pure)) pats
    <*> traverse f s

instance (Eq1 expr, Monad expr, Eq b) => Eq1 (Clause b expr) where
  liftEq f (Clause ps1 s1) (Clause ps2 s2) = liftEq (\(p1, pat1) (p2, pat2) -> p1 == p2 && liftPatEq (==) (liftEq f) (==) pat1 pat2) ps1 ps2 && liftEq f s1 s2

instance Bound TopLevelPatDefinition where
  TopLevelPatDefinition d >>>= f = TopLevelPatDefinition $ (>>>= f) <$> d
  TopLevelPatDataDefinition dataDef >>>= f = TopLevelPatDataDefinition $ dataDef >>>= f
  TopLevelPatClassDefinition classDef >>>= f = TopLevelPatClassDefinition $ classDef >>>= f
  TopLevelPatInstanceDefinition instanceDef >>>= f = TopLevelPatInstanceDefinition $ instanceDef >>>= f

instance GBound TopLevelPatDefinition where
  gbound f (TopLevelPatDefinition d) = TopLevelPatDefinition $ gbound f <$> d
  gbound f (TopLevelPatDataDefinition dataDef) = TopLevelPatDataDefinition $ gbound f dataDef
  gbound f (TopLevelPatClassDefinition classDef) = TopLevelPatClassDefinition $ gbound f classDef
  gbound f (TopLevelPatInstanceDefinition instanceDef) = TopLevelPatInstanceDefinition $ gbound f instanceDef

instance Bound PatInstanceDef where
  PatInstanceDef ms >>>= f = PatInstanceDef $ (\(name, loc, def, mtyp) -> (name, loc, (>>>= f) <$> def, (>>= f) <$> mtyp)) <$> ms

instance GBound PatInstanceDef where
  gbound f (PatInstanceDef ms) = PatInstanceDef $ (\(name, loc, def, mtyp) -> (name, loc, gbound f <$> def, gbind f <$> mtyp)) <$> ms

instance Bound (Clause b) where
  Clause pats s >>>= f = Clause (fmap (first (>>>= f)) <$> pats) (s >>>= f)

instance GBound (Clause b) where
  gbound f (Clause pats s) = Clause (fmap (first (gbound f)) <$> pats) (gbound f s)

instance (Pretty (expr v), Monad expr, v ~ Doc, void ~ Void)
  => PrettyNamed (Clause void expr v) where
  prettyNamed name (Clause pats s)
    = withNameHints (join $ nameHints . snd <$> pats) $ \ns -> do
      let go (p, pat)
            = prettyAnnotation p
            $ prettyM $ first (instantiatePattern (pure . fromName) ns) pat
          removeVoid = mapBound $ unvar id absurd
      prettyApps name (go <$> renamePatterns ns (fmap (first removeVoid) <$> pats))
        <+> "=" <+> prettyM (instantiatePattern (pure . fromName) ns $ removeVoid s)

instance (Pretty (expr v), Monad expr, v ~ Doc, void ~ Void)
  => Pretty (Clause void expr v) where
  prettyM = prettyNamed "_"

instance (Pretty (expr v), Monad expr, v ~ Doc)
  => Pretty (TopLevelPatDefinition expr v) where
  prettyM = prettyNamed "_"

instance (Pretty (expr v), Monad expr, v ~ Doc)
  => PrettyNamed (TopLevelPatDefinition expr v) where
  prettyNamed name (TopLevelPatDefinition d) = prettyNamed name d
  prettyNamed name (TopLevelPatDataDefinition dataDef) = prettyNamed name dataDef
  prettyNamed name (TopLevelPatClassDefinition c) = prettyNamed name c
  prettyNamed name (TopLevelPatInstanceDefinition i) = prettyNamed name i

instance PrettyNamed clause => PrettyNamed (PatDefinition clause) where
  prettyNamed name (PatDefinition a i clauses) = prettyM a <+> prettyM i <$$> vcat (prettyNamed name <$> clauses)

deriveEq1 ''PatDefinition

instance (Pretty (expr v), Monad expr, v ~ Doc) => PrettyNamed (PatInstanceDef expr v) where
  prettyNamed name (PatInstanceDef ms) = name <+> "=" <+> "instance" <+> "where" <$$> do
    let go (n, _, m, Nothing) = prettyNamed (prettyM n) m
        go (n, _, m, Just typ) = prettyM n <+> ":" <+> prettyM typ <$$> prettyNamed (prettyM n) m
    indent 2 (vcat $ go <$> ms)

instantiateClause
  :: Monad expr
  => (b -> expr v)
  -> Clause b expr v
  -> Clause void expr v
instantiateClause f (Clause pats s) = Clause (fmap (first go) <$> pats) (go s)
  where
    go = rebind $ Scope . unvar (pure . B . B) (pure . F . f)

instantiateLetClause
  :: Monad expr
  => (v -> expr a)
  -> Vector v
  -> Clause LetVar expr a
  -> Clause Void expr a
instantiateLetClause f vs
  = instantiateClause (f . fromMaybe (error "instantiateLetClause") . (vs Vector.!?) . unLetVar)

abstractClause
  :: Monad expr
  => (v -> Maybe b)
  -> Clause Void expr v
  -> Clause b expr v
abstractClause f (Clause pats s) = Clause (fmap (first go) <$> pats) (go s)
  where
    go = abstractSomeMore vacuous (fmap F . f)