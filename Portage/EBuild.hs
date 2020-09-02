{-|
Module      : Portage.EBuild
License     : GPL-3+
Maintainer  : haskell@gentoo.org

Functions and types related to interpreting and manipulating an ebuild,
as understood by the Portage package manager.
-}
{-# LANGUAGE CPP #-}
module Portage.EBuild
        ( EBuild(..)
        , ebuildTemplate
        , showEBuild
        , src_uri
        -- hspec exports
        , sort_iuse
        , drop_tdot
        , quote
        ) where

import           Portage.Dependency
import           Portage.EBuild.CabalFeature
import           Portage.EBuild.Render
import qualified Portage.Dependency.Normalize as PN

import qualified Data.Time.Clock as TC
import qualified Data.Time.Format as TC
import qualified Data.Function as F
import qualified Data.List as L
import qualified Data.List.Split as LS
import           Data.Version(Version(..))

import           Network.URI
import qualified Paths_hackport(version)

#if ! MIN_VERSION_time(1,5,0)
import qualified System.Locale as TC
#endif

-- | Type representing the information contained in an @.ebuild@.
data EBuild = EBuild {
    name :: String,
    category :: String,
    hackage_name :: String, -- might differ a bit (we mangle case)
    version :: String,
    hackportVersion :: String,
    description :: String,
    long_desc :: String,
    homepage :: String,
    license :: Either String String,
    slot :: String,
    keywords :: [String],
    iuse :: [String],
    depend :: Dependency,
    depend_extra :: [String],
    rdepend :: Dependency,
    rdepend_extra :: [String]
    , features :: [CabalFeature]
    , my_pn :: Maybe String -- ^ Just 'myOldName' if the package name contains upper characters
    , src_prepare :: [String] -- ^ raw block for src_prepare() contents
    , src_configure :: [String] -- ^ raw block for src_configure() contents
    , used_options :: [(String, String)] -- ^ hints to ebuild writers/readers
                                         --   on what hackport options were used to produce an ebuild
  }

getHackportVersion :: Version -> String
getHackportVersion Version {versionBranch=(x:s)} = foldl (\y z -> y ++ "." ++ (show z)) (show x) s
getHackportVersion Version {versionBranch=[]} = ""

-- | Generate a minimal 'EBuild' template.
ebuildTemplate :: EBuild
ebuildTemplate = EBuild {
    name = "foobar",
    category = "dev-haskell",
    hackage_name = "FooBar",
    version = "0.1",
    hackportVersion = getHackportVersion Paths_hackport.version,
    description = "",
    long_desc = "",
    homepage = "https://hackage.haskell.org/package/${HACKAGE_N}",
    license = Left "unassigned license?",
    slot = "0",
    keywords = ["~amd64","~x86"],
    iuse = [],
    depend = empty_dependency,
    depend_extra = [],
    rdepend = empty_dependency,
    rdepend_extra = [],
    features = [],
    my_pn = Nothing
    , src_prepare = []
    , src_configure = []
    , used_options = []
  }

-- | Given an EBuild, give the URI to the tarball of the source code.
-- Assumes that the server is always hackage.haskell.org.
-- 
-- >>> src_uri ebuild_template
-- "https://hackage.haskell.org/package/${P}/${P}.tar.gz"
src_uri :: EBuild -> String
src_uri e =
  case my_pn e of
    -- use standard address given that the package name has no upper
    -- characters
    Nothing -> "https://hackage.haskell.org/package/${P}/${P}.tar.gz"
    -- use MY_X variables (defined in showEBuild) as we've renamed the
    -- package
    Just _  -> "https://hackage.haskell.org/package/${MY_P}/${MY_P}.tar.gz"

-- | Pretty-print an 'EBuild' as a 'String'.
showEBuild :: TC.UTCTime -> EBuild -> String
showEBuild now ebuild =
  ss ("# Copyright 1999-" ++ this_year ++ " Gentoo Authors"). nl.
  ss "# Distributed under the terms of the GNU General Public License v2". nl.
  nl.
  ss "EAPI=7". nl.
  nl.
  ss ("# ebuild generated by hackport " ++ hackportVersion ebuild). nl.
  sconcat (map (\(k, v) -> ss "#hackport: " . ss k . ss ": " . ss v . nl) $ used_options ebuild).
  nl.
  ss "CABAL_FEATURES=". quote' (sepBy " " $ map render (features ebuild)). nl.
  ss "inherit haskell-cabal". nl.
  nl.
  (case my_pn ebuild of
     Nothing -> id
     Just pn -> ss "MY_PN=". quote pn. nl.
                ss "MY_P=". quote "${MY_PN}-${PV}". nl. nl).
  ss "DESCRIPTION=". quote (drop_tdot $ description ebuild). nl.
  ss "HOMEPAGE=". quote (toHttps $ expandVars (homepage ebuild)). nl.
  ss "SRC_URI=". quote (src_uri ebuild). nl.
  nl.
  ss "LICENSE=". (either (\err -> quote "" . ss ("\t# FIXME: " ++ err))
                         quote
                         (license ebuild)). nl.
  ss "SLOT=". quote (slot ebuild). nl.
  ss "KEYWORDS=". quote' (sepBy " " $ keywords ebuild).nl.
  ss "IUSE=". quote' (sepBy " " . sort_iuse $ L.nub $ iuse ebuild). nl.
  nl.
  dep_str "RDEPEND" (rdepend_extra ebuild) (rdepend ebuild).
  dep_str "DEPEND"  ( depend_extra ebuild) ( depend ebuild).
  (case my_pn ebuild of
     Nothing -> id
     Just _ -> nl. ss "S=". quote ("${WORKDIR}/${MY_P}"). nl).

  verbatim (nl . ss "src_prepare() {" . nl)
               (src_prepare ebuild)
           (ss "}" . nl).

  verbatim (nl. ss "src_configure() {" . nl)
               (src_configure ebuild)
           (ss "}" . nl).

  id $ []
  where
        expandVars = replaceMultiVars [ (        name ebuild, "${PN}")
                                      , (hackage_name ebuild, "${HACKAGE_N}")
                                      ]

        replace old new = L.intercalate new . LS.splitOn old
        -- add to this list with any https-aware websites 
        httpsHomepages = Just <$> [ "github.com"
                                  , "hackage.haskell.org"
                                  , "www.haskell.org"
                                  ]
        toHttps :: String -> String
        toHttps x =
          case parseURI x of
            Just uri -> if uriScheme uri == "http:" &&
                           (uriRegName <$> uriAuthority uri)
                           `elem`
                           httpsHomepages
                        then replace "http" "https" x
                        else x
            Nothing -> x

        this_year :: String
        this_year = TC.formatTime TC.defaultTimeLocale "%Y" now

-- | Sort IUSE alphabetically
--
-- >>> sort_iuse ["+a","b"]
-- ["+a","b"]
sort_iuse :: [String] -> [String]
sort_iuse = L.sortBy (compare `F.on` dropWhile ( `elem` "+"))

-- | Drop trailing dot(s).
--
-- >>> drop_tdot "foo."
-- "foo"
-- >>> drop_tdot "foo..."
-- "foo"
drop_tdot :: String -> String
drop_tdot = reverse . dropWhile (== '.') . reverse

type DString = String -> String

ss :: String -> DString
ss = showString

sc :: Char -> DString
sc = showChar

nl :: DString
nl = sc '\n'

verbatim :: DString -> [String] -> DString -> DString
verbatim pre s post =
    if null s
        then id
        else pre .
            (foldl (\acc v -> acc . ss "\t" . ss v . nl) id s) .
            post

sconcat :: [DString] -> DString
sconcat = L.foldl' (.) id

-- takes string and substitutes tabs to spaces
-- ebuild's convention is 4 spaces for one tab,
-- BUT! nested USE flags get moved too much to
-- right. Thus 8 :]
tab_size :: Int
tab_size = 8

tabify_line :: String -> String
tabify_line l = replicate need_tabs '\t'  ++ nonsp
    where (sp, nonsp)       = break (/= ' ') l
          (full_tabs, t) = length sp `divMod` tab_size
          need_tabs = full_tabs + if t > 0 then 1 else 0

tabify :: String -> String
tabify = unlines . map tabify_line . lines

dep_str :: String -> [String] -> Dependency -> DString
dep_str var extra dep = ss var. sc '='. quote' (ss $ drop_leadings $ unlines extra ++ deps_s). nl
    where indent = 1 * tab_size
          deps_s = tabify (dep2str indent $ PN.normalize_depend dep)
          drop_leadings = dropWhile (== '\t')

-- | Place a 'String' between quotes, and correctly handle special characters.
quote :: String -> DString
quote str = sc '"'. ss (esc str). sc '"'
  where
  esc = concatMap esc'
  esc' c =
      case c of
          '\\' -> "\\\\"
          '"'  -> "\\\""
          '\n' -> " "
          '`'  -> "'"
          _    -> [c]

quote' :: DString -> DString
quote' str = sc '"'. str. sc '"'

sepBy :: String -> [String] -> ShowS
sepBy _ []     = id
sepBy _ [x]    = ss x
sepBy s (x:xs) = ss x. ss s. sepBy s xs

getRestIfPrefix :: String       -- ^ the prefix
                -> String       -- ^ the string
                -> Maybe String
getRestIfPrefix (p:ps) (x:xs) = if p==x then getRestIfPrefix ps xs else Nothing
getRestIfPrefix [] rest = Just rest
getRestIfPrefix _ [] = Nothing

subStr :: String                -- ^ the search string
       -> String                -- ^ the string to be searched
       -> Maybe (String,String) -- ^ Just (pre,post) if string is found
subStr sstr str = case getRestIfPrefix sstr str of
    Nothing -> if null str then Nothing else case subStr sstr (tail str) of
        Nothing -> Nothing
        Just (pre,post) -> Just (head str:pre,post)
    Just rest -> Just ([],rest)

replaceMultiVars ::
    [(String,String)] -- ^ pairs of variable name and content
    -> String         -- ^ string to be searched
    -> String         -- ^ the result
replaceMultiVars [] str = str
replaceMultiVars whole@((pname,cont):rest) str = case subStr cont str of
    Nothing -> replaceMultiVars rest str
    Just (pre,post) -> (replaceMultiVars rest pre)++pname++(replaceMultiVars whole post)
