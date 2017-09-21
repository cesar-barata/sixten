{-# LANGUAGE DeriveFoldable, DeriveFunctor, DeriveTraversable, OverloadedStrings, PatternSynonyms, TemplateHaskell, TypeFamilies, ViewPatterns #-}
module Syntax.Abstract where

import Control.Monad
import Data.Deriving
import Data.Monoid
import Data.String

import Syntax
import Util
import TypeRep(TypeRep)

-- | Expressions with variables of type @v@.
data Expr v
  = Var v
  | Global QName
  | Con QConstr
  | Lit Literal
  | Pi !NameHint !Plicitness (Type v) (Scope1 Expr v)
  | Lam !NameHint !Plicitness (Type v) (Scope1 Expr v)
  | App (Expr v) !Plicitness (Expr v)
  | Let (LetRec Expr v) (Scope LetVar Expr v)
  | Case (Expr v) (Branches QConstr Plicitness Expr v) (Type v)
  | ExternCode (Extern (Expr v)) (Type v)
  deriving (Foldable, Functor, Traversable)

-- | Synonym for documentation purposes
type Type = Expr

-------------------------------------------------------------------------------
-- Helpers
pattern MkType :: TypeRep -> Expr v
pattern MkType rep = Lit (TypeRep rep)

let_ :: NameHint -> Expr v -> Type v -> Scope1 Expr v -> Expr v
let_ h e t s = Let (LetRec $ pure $ LetBinding h (abstractNone e) t) (mapBound (\() -> 0) s)

-------------------------------------------------------------------------------
-- Instances
instance GlobalBind Expr where
  global = Global
  bind f g expr = case expr of
    Var v -> f v
    Global v -> g v
    Con c -> Con c
    Lit l -> Lit l
    Pi h a t s -> Pi h a (bind f g t) (bound f g s)
    Lam h a t s -> Lam h a (bind f g t) (bound f g s)
    App e1 a e2 -> App (bind f g e1) a (bind f g e2)
    Let ds scope -> Let (bound f g ds) (bound f g scope)
    Case e brs retType -> Case (bind f g e) (bound f g brs) (bind f g retType)
    ExternCode c t -> ExternCode (bind f g <$> c) (bind f g t)

instance Syntax Expr where
  lam = Lam

  lamView (Lam n a e s) = Just (n, a, e, s)
  lamView _ = Nothing

  pi_ = Pi

  piView (Pi n a e s) = Just (n, a, e, s)
  piView _ = Nothing

instance AppSyntax Expr where
  app = App

  appView (App e1 a e2) = Just (e1, a, e2)
  appView _ = Nothing

deriveEq1 ''Expr
deriveEq ''Expr
deriveOrd1 ''Expr
deriveOrd ''Expr
deriveShow1 ''Expr
deriveShow ''Expr

instance Applicative Expr where
  pure = return
  (<*>) = ap

instance Monad Expr where
  return = Var
  expr >>= f = bind f Global expr

instance (Eq v, IsString v, Pretty v) => Pretty (Expr v) where
  prettyM expr = case expr of
    Var v -> prettyM v
    Global g -> prettyM g
    Con c -> prettyM c
    Lit l -> prettyM l
    Pi _ a t (unusedScope -> Just e) -> parens `above` arrPrec $
      prettyAnnotation a (prettyM t)
      <+> "->" <+>
      associate arrPrec (prettyM e)
    (usedPisViewM -> Just (tele, s)) -> withTeleHints tele $ \ns ->
      parens `above` absPrec $
      prettyTeleVarTypes ns tele <+> "->" <+>
      associate arrPrec (prettyM $ instantiateTele (pure . fromName) ns s)
    Pi {} -> error "impossible prettyPrec pi"
    (lamsViewM -> Just (tele, s)) -> withTeleHints tele $ \ns ->
      parens `above` absPrec $
      "\\" <> prettyTeleVarTypes ns tele <> "." <+>
      prettyM (instantiateTele (pure . fromName) ns s)
    Lam {} -> error "impossible prettyPrec lam"
    App e1 a e2 -> prettyApp (prettyM e1) (prettyAnnotation a $ prettyM e2)
    Let ds s -> parens `above` letPrec $ withLetHints ds $ \ns ->
      "let" <+> align (prettyLet ns ds)
      <+> "in" <+> prettyM (instantiateLet (pure . fromName) ns s)
    Case e brs retType -> parens `above` casePrec $
      "case" <+> inviolable (prettyM e) <+> "of" <+> parens (prettyM retType)
        <$$> indent 2 (prettyM brs)
    ExternCode c t -> parens `above` annoPrec $
      prettyM c <+> ":" <+> prettyM t
