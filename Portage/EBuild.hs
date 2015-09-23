{-# LANGUAGE CPP #-}
module Portage.EBuild
        ( EBuild(..)
        , ebuildTemplate
        , showEBuild
        , src_uri
        ) where

import Portage.Dependency
import qualified Portage.PackageId as PI
import qualified Portage.Dependency.Normalize as PN

import Data.String.Utils
import qualified Data.Time.Clock as TC
import qualified Data.Time.Format as TC
import qualified Data.Function as F
import qualified Data.List as L
import Data.Version(Version(..))
import qualified Paths_hackport(version)

#if MIN_VERSION_time(1,5,0)
import qualified System.Locale as SL
#else
import qualified System.Locale as TC
#endif

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
    rdepend_extra :: [String],
    features :: [String],
    my_pn :: Maybe String -- ^ Just 'myOldName' if the package name contains upper characters
    , src_prepare :: [String] -- ^ raw block for src_prepare() contents
    , src_configure :: [String] -- ^ raw block for src_configure() contents
    , used_options :: [(String, String)] -- ^ hints to ebuild writers/readers
                                         --   on what hackport options were used to produce an ebuild
  }

getHackportVersion :: Version -> String
getHackportVersion Version {versionBranch=(x:s)} = foldl (\y z -> y ++ "." ++ (show z)) (show x) s
getHackportVersion Version {versionBranch=[]} = ""

ebuildTemplate :: EBuild
ebuildTemplate = EBuild {
    name = "foobar",
    category = "dev-haskell",
    hackage_name = "FooBar",
    version = "0.1",
    hackportVersion = getHackportVersion Paths_hackport.version,
    description = "",
    long_desc = "",
    homepage = "http://hackage.haskell.org/package/${HACKAGE_N}",
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
src_uri :: EBuild -> String
src_uri e =
  case my_pn e of
    -- use standard address given that the package name has no upper
    -- characters
    Nothing -> "http://hackage.haskell.org/packages/archive/${PN}/${PV}/${P}.tar.gz"
    -- use MY_X variables (defined in showEBuild) as we've renamed the
    -- package
    Just _  -> "http://hackage.haskell.org/packages/archive/${MY_PN}/${PV}/${MY_P}.tar.gz"

showEBuild :: TC.UTCTime -> EBuild -> String
showEBuild now ebuild =
  ss ("# Copyright 1999-" ++ this_year ++ " Gentoo Foundation"). nl.
  ss "# Distributed under the terms of the GNU General Public License v2". nl.
  ss "# $Id$". nl.
  nl.
  ss "EAPI=5". nl.
  nl.
  ss ("# ebuild generated by hackport " ++ hackportVersion ebuild). nl.
  sconcat (map (\(k, v) -> ss "#hackport: " . ss k . ss ": " . ss v . nl) $ used_options ebuild).
  nl.
  ss "CABAL_FEATURES=". quote' (sepBy " " $ features ebuild). nl.
  ss "inherit haskell-cabal". if_games (ss " games") . nl.
  nl.
  (case my_pn ebuild of
     Nothing -> id
     Just pn -> ss "MY_PN=". quote pn. nl.
                ss "MY_P=". quote "${MY_PN}-${PV}". nl. nl).
  ss "DESCRIPTION=". quote (drop_tdot $ description ebuild). nl.
  ss "HOMEPAGE=". quote (toHttps $ expandVars (homepage ebuild)). nl.
  ss "SRC_URI=". quote (toMirror $ src_uri ebuild). nl.
  nl.
  ss "LICENSE=". (either (\err -> quote "" . ss ("\t# FIXME: " ++ err))
                         quote
                         (license ebuild)). nl.
  ss "SLOT=". quote (slot ebuild). nl.
  ss "KEYWORDS=". quote' (sepBy " " $ keywords ebuild).nl.
  ss "IUSE=". quote' (sepBy " " . sort_iuse $ iuse ebuild). nl.
  nl.
  dep_str "RDEPEND" (rdepend_extra ebuild) (rdepend ebuild).
  dep_str "DEPEND"  ( depend_extra ebuild) ( depend ebuild).
  (case my_pn ebuild of
     Nothing -> id
     Just _ -> nl. ss "S=". quote ("${WORKDIR}/${MY_P}"). nl).

  if_games (nl . ss "pkg_setup() {" . nl.
            ss (tabify_line " games_pkg_setup") . nl.
            ss (tabify_line " haskell-cabal_pkg_setup") . nl.
            ss "}" . nl).

  verbatim (nl . ss "src_prepare() {" . nl)
               (src_prepare ebuild)
           (ss "}" . nl).

  verbatim (nl. ss "src_configure() {" . nl)
               (src_configure ebuild)
           (ss "}" . nl).

  if_games (nl . ss "src_compile() {" . nl.
            ss (tabify_line " haskell-cabal_src_compile") . nl.
            ss "}" . nl).

  if_games (nl . ss "src_install() {" . nl.
            ss (tabify_line " haskell-cabal_src_install") . nl.
            ss (tabify_line " prepgamesdirs") . nl.
            ss "}" . nl).

  if_games (nl . ss "pkg_postinst() {" . nl.
            ss (tabify_line " ghc-package_pkg_postinst") . nl.
            ss (tabify_line " games_pkg_postinst") . nl.
            ss "}" . nl).

  id $ []
  where
        expandVars = replaceMultiVars [ (        name ebuild, "${PN}")
                                      , (hackage_name ebuild, "${HACKAGE_N}")
                                      ]
        toMirror = replace "http://hackage.haskell.org/" "mirror://hackage/"
        -- TODO: this needs to be more generic
        toHttps  = replace "http://github.com/" "https://github.com/"
        this_year :: String
        this_year = TC.formatTime TC.defaultTimeLocale "%Y" now
        if_games :: DString -> DString
        if_games ds = if PI.is_games_cat (PI.Category (category ebuild))
                          then ds
                          else id

-- "+a" -> "a"
-- "b"  -> "b"
sort_iuse :: [String] -> [String]
sort_iuse = L.sortBy (compare `F.on` dropWhile ( `elem` "+"))

-- drops trailing dot
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

quote :: String -> DString
quote str = sc '"'. ss (esc str). sc '"'
  where
  esc = concatMap esc'
  esc' c =
      case c of
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

getRestIfPrefix ::
    String ->    -- ^ the prefix
    String ->    -- ^ the string
    Maybe String
getRestIfPrefix (p:ps) (x:xs) = if p==x then getRestIfPrefix ps xs else Nothing
getRestIfPrefix [] rest = Just rest
getRestIfPrefix _ [] = Nothing

subStr ::
    String ->    -- ^ the search string
    String ->    -- ^ the string to be searched
    Maybe (String,String)  -- ^ Just (pre,post) if string is found
subStr sstr str = case getRestIfPrefix sstr str of
    Nothing -> if null str then Nothing else case subStr sstr (tail str) of
        Nothing -> Nothing
        Just (pre,post) -> Just (head str:pre,post)
    Just rest -> Just ([],rest)

replaceMultiVars ::
    [(String,String)] ->    -- ^ pairs of variable name and content
    String ->        -- ^ string to be searched
    String             -- ^ the result
replaceMultiVars [] str = str
replaceMultiVars whole@((pname,cont):rest) str = case subStr cont str of
    Nothing -> replaceMultiVars rest str
    Just (pre,post) -> (replaceMultiVars rest pre)++pname++(replaceMultiVars whole post)
