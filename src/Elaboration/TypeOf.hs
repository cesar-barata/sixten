{-# LANGUAGE ConstraintKinds, FlexibleContexts, OverloadedStrings, TypeFamilies #-}
module Elaboration.TypeOf where

import Protolude

import qualified Data.Text.Prettyprint.Doc as PP

import qualified Builtin.Names as Builtin
import Driver.Query
import Effect
import qualified Effect.Context as Context
import Elaboration.MetaVar
import Elaboration.Monad
import qualified Elaboration.Normalise as Normalise
import Syntax
import Syntax.Core
import Util

type MonadTypeOf meta m = (Show meta, MonadIO m, MonadFetch Query m, MonadFresh m, MonadLog m, MonadContext (Expr meta Var) m, MonadReport m)

data Args meta m = Args
  { typeOfMeta :: !(meta -> Closed (Expr meta))
  , normaliseArgs :: !(Normalise.Args meta m)
  }

metaVarArgs :: (MonadContext e m, MonadIO m, MonadLog m) => Args MetaVar m
metaVarArgs = Args metaType Normalise.metaVarSolutionArgs

voidArgs :: MonadContext e m => Args Void m
voidArgs = Args absurd Normalise.voidArgs

typeOf :: MonadTypeOf MetaVar m => CoreM -> m CoreM
typeOf = typeOf' metaVarArgs

typeOf'
  :: MonadTypeOf meta m
  => Args meta m
  -> Expr meta Var
  -> m (Expr meta Var)
typeOf' args expr = case expr of
  Global v -> fetchType v
  Var v -> Context.lookupType v
  Meta m es -> case typeApps (open $ typeOfMeta args m) es of
    Nothing -> panic "typeOf meta typeApps"
    Just t -> return t
  Con qc -> snd <$> fetchQConstructor qc
  Lit l -> return $ typeOfLiteral l
  Pi {} -> return Builtin.Type
  Lam h p t s ->
    Context.freshExtend (binding h p t) $ \x -> do
      resType <- typeOf' args $ instantiate1 (pure x) s
      pi_ x resType
  App e1 p e2 -> do
    e1type <- typeOf' args e1
    e1type' <- Normalise.whnf' (normaliseArgs args) e1type mempty
    case e1type' of
      Pi _ p' _ resType | p == p' -> return $ instantiate1 e2 resType
      _ -> do
        prettye1type' <- Normalise._prettyExpr (normaliseArgs args) e1type'
        panic $ show $ "typeOf: expected" PP.<+> shower p PP.<+> "pi type"
          <> PP.line <> "actual type: " PP.<+> prettye1type'
  Let ds s ->
    letExtendContext ds $ \xs ->
      typeOf' args $ instantiateLet pure xs s
  Case _ _ retType -> return retType
  ExternCode _ retType -> return retType
  SourceLoc _ e -> typeOf' args e

typeOfLiteral
  :: Literal
  -> Expr meta v
typeOfLiteral Integer {} = Builtin.IntType
typeOfLiteral Natural {} = Builtin.Nat
typeOfLiteral Byte {} = Builtin.ByteType
typeOfLiteral TypeRep {} = Builtin.Type
