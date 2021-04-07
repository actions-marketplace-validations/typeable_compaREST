module OpenAPI.Checker.Subtree
  ( APIStep (..)
  , Subtree (..)
  , CompatM (..)
  , CompatFormula
  , ProdCons (..)
  , HasUnsupportedFeature (..)
  , checkProdCons
  , SubtreeCheckIssue (..)
  , runCompatFormula
  , withTrace
  , localM
  , localTrace
  , localStep
  , localTrace'
  , anyOfM
  , anyOfAt
  , issueAtTrace
  , issueAt
  , memo
  )
where

import Control.Monad.Identity
import Control.Monad.Reader
import Control.Monad.State
import Data.Aeson
import Data.Functor.Compose
import Data.HList
import Data.Kind
import Data.Monoid
import Data.OpenApi
import Data.Text
import Data.Typeable
import OpenAPI.Checker.Formula
import OpenAPI.Checker.Memo
import OpenAPI.Checker.Trace
import qualified OpenAPI.Checker.TracePrefixTree as T

class
  (Subtree a, Subtree b, Steppable a b) =>
  APIStep (a :: Type) (b :: Type)
  where
  describeStep :: Step a b -> Text

data ProdCons a = ProdCons
  { producer :: a
  , consumer :: a
  }
  deriving (Eq, Ord, Show, Functor, Foldable, Traversable)

instance Applicative ProdCons where
  pure x = ProdCons x x
  ProdCons fp fc <*> ProdCons xp xc = ProdCons (fp xp) (fc xc)

newtype CompatM t a = CompatM
  { unCompatM
    :: ReaderT
           (ProdCons (Trace OpenApi t))
           (StateT (MemoState VarRef) Identity)
           a
  }
  deriving newtype
    ( Functor
    , Applicative
    , Monad
    , MonadReader (ProdCons (Trace OpenApi t))
    , MonadState (MemoState VarRef)
    )

type CompatFormula t = Compose (CompatM t) (FormulaF SubtreeCheckIssue OpenApi)

class (Typeable t, Ord (CheckIssue t), Show (CheckIssue t)) => Subtree (t :: Type) where
  type CheckEnv t :: [Type]
  data CheckIssue t :: Type

  issueIsUnsupported :: CheckIssue t -> Bool
  issueIsUnsupported = const False

  -- | If we ever followed a reference, reroute the path through "components"
  normalizeTrace :: Trace OpenApi t -> Trace OpenApi t

  checkCompatibility :: HasAll (CheckEnv t) xs => HList xs -> ProdCons t -> CompatFormula t ()

checkProdCons :: (Subtree t, HasAll (CheckEnv t) env) => HList env -> ProdCons (Traced r t) -> CompatFormula r ()
checkProdCons env (ProdCons (Traced p x) (Traced c y)) =
  localTrace (ProdCons p c) $ checkCompatibility env $ ProdCons x y

class HasUnsupportedFeature x where
  hasUnsupportedFeature :: x -> Bool

instance HasUnsupportedFeature () where
  hasUnsupportedFeature () = False

instance
  (HasUnsupportedFeature a, HasUnsupportedFeature b)
  => HasUnsupportedFeature (Either a b)
  where
  hasUnsupportedFeature (Left x) = hasUnsupportedFeature x
  hasUnsupportedFeature (Right x) = hasUnsupportedFeature x

instance Subtree t => HasUnsupportedFeature (CheckIssue t) where
  hasUnsupportedFeature = issueIsUnsupported

instance
  (forall x. HasUnsupportedFeature (f x))
  => HasUnsupportedFeature (T.TracePrefixTree f r)
  where
  hasUnsupportedFeature =
    getAny . T.foldWith (\_ fa -> Any $ hasUnsupportedFeature fa)

data SubtreeCheckIssue t where
  SubtreeCheckIssue :: Subtree t => CheckIssue t -> SubtreeCheckIssue t

deriving stock instance Eq (SubtreeCheckIssue t)

deriving stock instance Ord (SubtreeCheckIssue t)

instance Subtree t => ToJSON (CheckIssue t) where
  toJSON = toJSON . show

instance HasUnsupportedFeature (SubtreeCheckIssue t) where
  hasUnsupportedFeature (SubtreeCheckIssue i) = hasUnsupportedFeature i

instance ToJSON (SubtreeCheckIssue t) where
  toJSON (SubtreeCheckIssue i) = toJSON i

runCompatFormula
  :: ProdCons (Trace OpenApi t)
  -> Compose (CompatM t) (FormulaF f r) a
  -> Either (T.TracePrefixTree f r) a
runCompatFormula env (Compose f) =
  calculate . runIdentity . runMemo 0 . (`runReaderT` env) . unCompatM $ f

withTrace
  :: (ProdCons (Trace OpenApi a) -> Compose (CompatM a) (FormulaF f r) x)
  -> Compose (CompatM a) (FormulaF f r) x
withTrace k = Compose $ do
  xs <- ask
  getCompose $ k xs

localM
  :: ProdCons (Trace a b)
  -> CompatM b x
  -> CompatM a x
localM xs (CompatM k) =
  CompatM $ ReaderT $ \env -> runReaderT k ((>>>) <$> env <*> xs)

localTrace
  :: ProdCons (Trace a b)
  -> Compose (CompatM b) (FormulaF f r) x
  -> Compose (CompatM a) (FormulaF f r) x
localTrace xs (Compose h) = Compose (localM xs h)

localStep
  :: Steppable a b
  => Step a b
  -> Compose (CompatM b) (FormulaF f r) x
  -> Compose (CompatM a) (FormulaF f r) x
localStep xs (Compose h) = Compose (localM (pure $ step xs) h)

localTrace'
  :: ProdCons (Trace OpenApi b)
  -> Compose (CompatM b) (FormulaF f r) x
  -> Compose (CompatM a) (FormulaF f r) x
localTrace' xs (Compose (CompatM k)) = Compose $ CompatM$ ReaderT $ \_ -> runReaderT k xs

issueAtTrace
  :: Subtree t => Trace OpenApi t -> CheckIssue t -> CompatFormula s a
issueAtTrace xs issue = Compose $ pure $ anError $ AnItem xs $ SubtreeCheckIssue issue

issueAt
  :: Subtree t
  => (forall x. ProdCons x -> x)
  -> CheckIssue t
  -> CompatFormula t a
issueAt f issue = Compose $ do
  xs <- asks f
  pure $ anError $ AnItem xs $ SubtreeCheckIssue issue

anyOfM
  :: Ord (f t)
  => Trace r t
  -> f t
  -> [Compose (CompatM t) (FormulaF f r) a]
  -> Compose (CompatM t) (FormulaF f r) a
anyOfM xs issue fs =
  Compose $ (`eitherOf` AnItem xs issue) <$> sequenceA (getCompose <$> fs)

anyOfAt
  :: Subtree t
  => (forall x. ProdCons x -> x)
  -> CheckIssue t
  -> [CompatFormula t a]
  -> CompatFormula t a
anyOfAt f issue fs = Compose $ do
  xs <- asks f
  (`eitherOf` AnItem xs (SubtreeCheckIssue issue)) <$> sequenceA (getCompose <$> fs)

fixpointKnot
  :: MonadState (MemoState VarRef) m
  => KnotTier (FormulaF f r ()) VarRef m
fixpointKnot =
  KnotTier
    { onKnotFound = modifyMemoNonce succ
    , onKnotUsed = \i -> pure $ variable i
    , tieKnot = \i x -> pure $ maxFixpoint i x
    }

memo :: Subtree t => CompatFormula t () -> CompatFormula t ()
memo (Compose f) = Compose $ do
  pxs <- asks (fmap normalizeTrace)
  memoWithKnot fixpointKnot f pxs