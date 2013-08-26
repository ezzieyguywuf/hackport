module Portage.Dependency.Types
  (
    SlotDepend(..)
  , LBound(..)
  , UBound(..)
  , DRange(..)
  , DAttr(..)
  , Dependency(..)
  ) where

import Portage.PackageId
import Portage.Use

data SlotDepend = AnySlot          -- nothing special
                | AnyBuildTimeSlot -- ':='
                | GivenSlot String -- ':slotno'
    deriving (Eq, Show)

data LBound = StrictLB    Version
            | NonstrictLB Version
            | ZeroB
    deriving (Eq, Show)

instance Ord LBound where
    compare ZeroB ZeroB = EQ
    compare ZeroB _     = LT
    compare _     ZeroB = GT
    compare (StrictLB lv)    (StrictLB rv)    = compare lv rv
    compare (NonstrictLB lv) (NonstrictLB rv) = compare lv rv
    compare l r = error $ unlines ["i am too lazy to implement LBound: compare"
                                  , show l
                                  , show r]

data UBound = StrictUB Version   -- <
            | NonstrictUB Version -- <=
            | InfinityB
    deriving (Eq, Show)

instance Ord UBound where
    compare InfinityB InfinityB = EQ
    compare InfinityB _     = GT
    compare _         InfinityB = LT
    compare (NonstrictUB lv) (NonstrictUB rv) = compare lv rv
    compare (StrictUB lv)    (StrictUB rv)    = compare lv rv
    compare l r = error $ unlines ["i am too lazy to implement UBound: compare"
                                  , show l
                                  , show r]

data DRange = DRange LBound UBound
            | DExact Version
    deriving (Eq, Show)

data DAttr = DAttr SlotDepend [UseFlag]
    deriving (Eq, Show)

data Dependency = Atom PackageName DRange DAttr
                | DependIfUse UseFlag Dependency
                | DependAnyOf         [Dependency]
                | DependAllOf         [Dependency]
    deriving (Eq, Show)