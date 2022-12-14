{-# OPTIONS_GHC -Wno-orphans #-}

module Data.OpenApi.Compare.Orphans () where

import Control.Comonad.Env
import qualified Data.HashMap.Strict.InsOrd as IOHM
import Data.OpenApi

deriving newtype instance Ord Reference

deriving stock instance Ord a => Ord (Referenced a)

deriving stock instance Ord Schema

deriving stock instance Ord AdditionalProperties

deriving stock instance Ord Discriminator

deriving stock instance Ord Xml

deriving stock instance Ord OpenApiType

deriving stock instance Ord Style

deriving stock instance Ord OpenApiItems

deriving stock instance Ord ParamLocation

deriving stock instance Ord HttpSchemeType

deriving stock instance Ord ApiKeyParams

deriving stock instance Ord ApiKeyLocation

instance (Ord k, Ord v) => Ord (IOHM.InsOrdHashMap k v) where
  compare xs ys = compare (IOHM.toList xs) (IOHM.toList ys)

deriving stock instance (Eq e, Eq (w a)) => Eq (EnvT e w a)

deriving stock instance (Ord e, Ord (w a)) => Ord (EnvT e w a)

deriving stock instance (Show e, Show (w a)) => Show (EnvT e w a)
