module Language.PureScript.Erl.Make where

import Prelude

import           Control.Monad hiding (sequence)
import           Control.Monad.Error.Class (MonadError(..))
import           Control.Monad.Trans.Class (MonadTrans(..))
import           Control.Monad.Writer.Class (MonadWriter(..))
import qualified Language.PureScript.CoreFn as CF
import           Language.PureScript.Erl.Make.Monad
import qualified Language.PureScript as P
import           Control.Monad.Supply
import qualified Data.Map as M
import qualified Data.List.NonEmpty as NEL
import           Language.PureScript.Erl.Parser (parseFile)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import           System.FilePath ((</>))
import           Data.Foldable (for_, minimum)
import           System.Directory (getCurrentDirectory)
import           Data.Version (showVersion)
import           Data.Time.Clock (UTCTime)

import qualified Paths_purerl as Paths

import           Language.PureScript.Erl.CodeGen.Common (erlModuleName, atomModuleName, atom, ModuleType(..))
import           Language.PureScript.Erl.CodeGen (moduleToErl)
import           Language.PureScript.Erl.CodeGen.Optimizer (optimize)
import           Language.PureScript.Erl.Pretty (prettyPrintErl)
import           Language.PureScript.Erl.Errors
import           Language.PureScript.Erl.Errors.Types



data MakeActions m = MakeActions
  { codegen :: CF.Module CF.Ann -> SupplyT m ()
  -- ^ Run the code generator for the module and write any required output files.
  , ffiCodegen :: CF.Module CF.Ann -> m ()
  , getOutputTimestamp :: P.ModuleName -> m (Maybe UTCTime)
  -- ^ Get the timestamp for the output files for a module. This should be the
  -- timestamp for the oldest modified file, or 'Nothing' if any of the required
  -- output files are missing.
  }

buildActions :: String -> P.Environment -> M.Map P.ModuleName FilePath -> Bool -> MakeActions Make
buildActions outputDir env foreigns usePrefix =
  MakeActions codegen ffiCodegen getOutputTimestamp
  where

  getOutputTimestamp :: P.ModuleName -> Make (Maybe UTCTime)
  getOutputTimestamp mn = do
    let outputPaths = [ outFile mn ]
    timestamps <- traverse getTimestampMaybe outputPaths
    pure $ fmap minimum . NEL.nonEmpty =<< sequence timestamps

  codegen :: CF.Module CF.Ann -> SupplyT Make ()
  codegen m = do
    let mn = CF.moduleName m
    foreignExports <- lift $ case mn `M.lookup` foreigns of
      Just path
        | not $ requiresForeign m ->
            return []
        | otherwise -> getForeigns path
      Nothing ->
        return []

    (exports, rawErl) <- moduleToErl env m foreignExports
    optimized <- traverse optimize rawErl 
    dir <- lift $ makeIO "get file info: ." getCurrentDirectory
    let makeAbsFile file = dir </> file
    let pretty = prettyPrintErl (makeAbsFile :: String -> String) optimized
    let 
        prefix :: [T.Text]
        prefix = ["Generated by purs version " <> T.pack (showVersion Paths.version) | usePrefix]
        directives :: [T.Text]
        directives = [
          "-module(" <> atom (atomModuleName mn PureScriptModule) <> ").",
          "-export([" <> T.intercalate ", " exports <> "]).",
          "-compile(nowarn_shadow_vars).",
          "-compile(nowarn_unused_vars).",
          "-compile(nowarn_unused_function).",
          "-compile(no_auto_import)."
          ]
    let erl :: T.Text = T.unlines $ map ("% " <>) prefix ++ directives ++ [ pretty ]
    lift $ writeTextFile (outFile mn) $ TE.encodeUtf8 erl

  ffiCodegen :: CF.Module CF.Ann -> Make ()
  ffiCodegen m = do
    let mn = CF.moduleName m
        foreignFile = moduleDir mn </> T.unpack (erlModuleName mn ForeignModule) ++ ".erl"
    case mn `M.lookup` foreigns of
      Just path
        | not $ requiresForeign m ->
            tell $ errorMessage $ UnnecessaryFFIModule mn path
        | otherwise -> pure ()
      Nothing ->
        when (requiresForeign m) $ throwError . errorMessage $ MissingFFIModule mn
    for_ (mn `M.lookup` foreigns) $ \path ->
      copyFile path foreignFile

  outFile mn = moduleDir mn </> T.unpack (erlModuleName mn PureScriptModule) ++ ".erl"
  moduleDir mn = outputDir </> T.unpack (P.runModuleName mn)
      

  requiresForeign :: CF.Module a -> Bool
  requiresForeign = not . null . CF.moduleForeign

  getForeigns :: String -> Make [(T.Text, Int)]
  getForeigns path = do
    text <- readTextFile path
    pure $ either (const []) id $ parseFile path text