{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MonadComprehensions #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE ViewPatterns #-}
module Backend.SLam where

import Protolude

import Bound.Scope hiding (instantiate1)
import Control.Lens hiding (Context, parts)
import Control.Monad.Reader
import qualified Data.Vector as Vector

import qualified Builtin.Names as Builtin
import Driver.Query
import Effect
import qualified Effect.Context as Context
import Effect.Log as Log
import qualified Elaboration.Normalise as Normalise
import qualified Elaboration.TypeOf as TypeOf
import Syntax
import qualified Syntax.Core as Core
import Syntax.Sized.Anno
import qualified Syntax.Sized.SLambda as SLambda
import Util
import VIX

data SLamEnv = SLamEnv
  { _context :: !(Context (Core.Expr Void Var))
  , _vixEnv :: !VIX.Env
  }

makeLenses ''SLamEnv

instance HasLogEnv SLamEnv where
  logEnv = vixEnv.logEnv

instance HasReportEnv SLamEnv where
  reportEnv = vixEnv.reportEnv

instance HasFreshEnv SLamEnv where
  freshEnv = vixEnv.freshEnv

instance Context.HasContext (Core.Expr Void Var) SLamEnv where
  context = Backend.SLam.context

newtype SLam a = SLam (ReaderT SLamEnv (Task Query) a)
  deriving (Functor, Applicative, Monad, MonadIO, MonadFresh, MonadContext (Core.Expr Void Var), MonadReport, MonadLog, MonadFetch Query)

runSLam :: SLam a -> VIX a
runSLam (SLam s)
  = withReaderT (\env -> SLamEnv { _context = mempty, _vixEnv = env }) s

whnf :: Core.Expr Void Var -> SLam (Core.Expr Void Var)
whnf e = Normalise.whnf' Normalise.voidArgs
  { Normalise._expandTypeReps = True
  } e mempty

typeOf :: Core.Expr Void Var -> SLam (Core.Expr Void Var)
typeOf = TypeOf.typeOf' TypeOf.voidArgs

slamAnno :: Core.Expr Void Var -> SLam (Anno SLambda.Expr Var)
slamAnno e = Anno <$> slam e <*> (slam =<< whnf =<< typeOf e)

typeArity :: Core.Type a b -> Int
typeArity = teleLength . fst . Core.pisView

slam :: Core.Expr Void Var -> SLam (SLambda.Expr Var)
slam expr = do
  logPretty "slam" "slam expr" $ traverse prettyVar expr
  res <- Log.indent $ case expr of
    Core.Var v -> return $ SLambda.Var v
    Core.Meta m _ -> absurd m
    Core.Global g -> return $ SLambda.Global g
    Core.Lit l -> return $ SLambda.Lit l
    Core.Pi {} -> do
      t <- whnf $ Core.Global $ gname Builtin.PiTypeName
      slam t
    Core.Lam h p t s -> do
      t' <- whnf t
      Context.freshExtend (binding h p t') $ \v -> do
        e <- slamAnno $ instantiate1 (pure v) s
        rep <- slam t'
        SLambda.lam v rep e
    (Core.appsView -> (Core.unSourceLoc -> Core.Con qc, es)) -> do
      (numParams, conType) <- fetchQConstructor qc
      let n = typeArity conType
      case compare (length es) n of
        GT -> panic $ "slam: too many args for constructor: " <> shower qc
        EQ -> do
          let es' = drop numParams es
          SLambda.Con qc <$> mapM slamAnno (Vector.fromList $ snd <$> es')
        LT -> do
          let Just appliedConType = Core.typeApps conType es
              tele = Core.piTelescope appliedConType
          slam
            $ quantify Core.Lam tele
            $ Scope
            $ Core.apps (Core.Con qc)
            $ Vector.fromList (fmap (pure . pure) <$> es)
            <> iforTele tele (\i _ a _ -> (a, pure $ B $ TeleVar i))
    Core.Con _qc -> panic "slam impossible"
    Core.App e1 _ e2 -> SLambda.App <$> slam e1 <*> slamAnno e2
    Core.Case e brs _retType -> SLambda.Case <$> slamAnno e <*> slamBranches brs
    Core.Let ds scope ->
      letExtendContext ds $ \vs -> do
        ds' <- forMLet ds $ \_ _ s t -> do
          e <- slam $ instantiateLet pure vs s
          t' <- slam t
          return $ Anno e t'
        body <- slam $ instantiateLet pure vs scope
        SLambda.letRec (Vector.zip vs ds') body
    Core.ExternCode c retType -> do
      retType' <- slam =<< whnf retType
      c' <- slamExtern c
      return $ SLambda.ExternCode c' retType'
    Core.SourceLoc _ e -> slam e
  logPretty "slam" "slam res" $ traverse prettyVar res
  return res

slamBranches
  :: Branches (Core.Expr Void) Var
  -> SLam (Branches SLambda.Expr Var)
slamBranches (ConBranches cbrs) = do
  cbrs' <- Log.indent $ forM cbrs $ \(ConBranch c tele brScope) ->
    teleExtendContext tele $ \vs -> do
      ctx <- getContext
      reps <- forM vs $ \v -> do
        t' <- whnf $ Context.lookupType v ctx
        slam t'

      brExpr <- slam $ instantiateTele pure vs brScope
      typedConBranch c (Vector.zip vs reps) brExpr
  return $ ConBranches cbrs'
slamBranches (LitBranches lbrs d)
  = LitBranches
    <$> sequence [LitBranch l <$> slam e | LitBranch l e <- lbrs]
    <*> slam d

slamExtern
  :: Extern (Core.Expr Void Var)
  -> SLam (Extern (Anno SLambda.Expr Var))
slamExtern (Extern lang parts)
  = fmap (Extern lang) $ forM parts $ \case
    ExternPart str -> return $ ExternPart str
    ExprMacroPart e -> ExprMacroPart <$> slamAnno e
    TypeMacroPart t -> TypeMacroPart <$> (slamAnno =<< whnf t)
    TargetMacroPart m -> return $ TargetMacroPart m

slamDef
  :: Definition (Core.Expr Void) Var
  -> SLam (Anno SLambda.Expr Var)
slamDef (ConstantDefinition _ e) = slamAnno e
slamDef (DataDefinition _ e) = slamAnno e
