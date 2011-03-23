{-# LANGUAGE StandaloneDeriving, TemplateHaskell, ScopedTypeVariables,
    FlexibleInstances, MultiParamTypeClasses, FlexibleContexts,
    UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Language.Trellys.GenericBind
  (Fresh(..),LFresh(..),Alpha(..)
  ,FreshM, runFreshM, FreshMT(..), runFreshMT
  {-- ,AlphaCtx --}
  ,Name,AnyName(..),rName,name1,name2,name3,name4,name5
  ,translate
  ,name2Integer,name2String,integer2Name,string2Name,makeName
  ,binders,patfv,fv,fvAny,swaps
  ,aeq, acompare
  ,Bind,rBind,bind,unbind,unbind2,unbind3
  ,Rebind,rRebind,rebind -- ,reopen
  ,Annot(..),rAnnot
  ,Subst(..),SubstName(..) {--,  matchR1 --}
  ,unsafeUnbind
  ,lunbind, lfreshen

--  ,subst,substs -- only for Nominal
  ,rSourcePos
)  where

-- To switch between LocallyNameless and Nominal versions of the binding library:
-- (1) change the import statement below from LocallyNameless to Nominal
-- (2) adjust the exports above
-- (3) change the Alpha and Subst instances for SourcePos below

import Data.Set (Set)

import Generics.RepLib.Bind.LocallyNameless hiding (fv)
import qualified Generics.RepLib.Bind.LocallyNameless as LN

import Generics.RepLib hiding (Arrow)
import Text.ParserCombinators.Parsec.Pos

-- Defining SourcePos abstractly means that they get ignored when comparing terms.
$(derive_abstract [''SourcePos])
instance Alpha SourcePos
instance Subst b SourcePos

-- Restrict the type of fv to avoid mistakes where we try to check for
-- Terms free in ETerms.  See r108 for context.
fv :: (Rep a, Alpha a) => a -> Set (Name a)
fv = LN.fv
