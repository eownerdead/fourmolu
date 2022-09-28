{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}

-- | Tests for Fourmolu configuration options. Similar to PrinterSpec.hs
--
-- Writing as a separate file to avoid merge conflicts in PrinterSpec.hs. This
-- way, Fourmolu can implement its tests independently of how Ormolu does its
-- testing.
module Ormolu.Config.PrinterOptsSpec (spec) where

import Control.Exception (catch)
import Control.Monad (forM_, when)
import Data.Algorithm.DiffContext (getContextDiff, prettyContextDiff)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Stack (withFrozenCallStack)
import Ormolu
  ( Config (..),
    PrinterOpts (..),
    PrinterOptsTotal,
    defaultConfig,
    defaultPrinterOpts,
    detectSourceType,
    ormolu,
  )
import Ormolu.Exception (OrmoluException, printOrmoluException)
import Ormolu.Terminal (ColorMode (..), runTerm)
import Ormolu.Utils.IO (readFileUtf8, writeFileUtf8)
import Path
  ( File,
    Path,
    fromRelFile,
    parseRelDir,
    parseRelFile,
    toFilePath,
    (</>),
  )
import Path.IO (doesFileExist)
import System.Environment (lookupEnv)
import System.IO (hClose)
import System.IO.Temp (withSystemTempFile)
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec
import qualified Text.PrettyPrint as Doc
import Text.Printf (printf)

data TestGroup = forall a.
  TestGroup
  { label :: String,
    testCases :: [a],
    updateConfig :: a -> PrinterOptsTotal -> PrinterOptsTotal,
    showTestCase :: a -> String,
    testCaseSuffix :: a -> String
  }

spec :: Spec
spec =
  mapM_
    runTestGroup
    [ TestGroup
        { label = "indentation",
          testCases = (,) <$> [2, 3, 4] <*> allOptions,
          updateConfig = \(indent, indentWheres) opts ->
            opts
              { poIndentation = pure indent,
                poIndentWheres = pure indentWheres
              },
          showTestCase = \(indent, indentWheres) ->
            show indent ++ if indentWheres then " + indent wheres" else "",
          testCaseSuffix = \(indent, indentWheres) ->
            suffixWith [show indent, if indentWheres then "indent_wheres" else ""]
        },
      TestGroup
        { label = "function-arrows",
          testCases = allOptions,
          updateConfig = \functionArrows opts ->
            opts {poFunctionArrows = pure functionArrows},
          showTestCase = show,
          testCaseSuffix = suffix1
        },
      TestGroup
        { label = "comma-style",
          testCases = allOptions,
          updateConfig = \commaStyle opts -> opts {poCommaStyle = pure commaStyle},
          showTestCase = show,
          testCaseSuffix = suffix1
        },
      TestGroup
        { label = "import-export",
          testCases = allOptions,
          updateConfig = \commaStyle opts ->
            opts {poImportExportStyle = pure commaStyle},
          showTestCase = show,
          testCaseSuffix = suffix1
        },
      TestGroup
        { label = "let-style",
          testCases = (,,) <$> allOptions <*> allOptions <*> [2, 4],
          updateConfig = \(letStyle, inStyle, indent) opts ->
            opts
              { poIndentation = pure indent,
                poLetStyle = pure letStyle,
                poInStyle = pure inStyle
              },
          showTestCase = \(letStyle, inStyle, indent) ->
            printf "%s + %s (indent=%d)" (show letStyle) (show inStyle) indent,
          testCaseSuffix = \(letStyle, inStyle, indent) ->
            suffixWith [show letStyle, show inStyle, "indent=" ++ show indent]
        },
      TestGroup
        { label = "record-brace-space",
          testCases = allOptions,
          updateConfig = \recordBraceSpace opts -> opts {poRecordBraceSpace = pure recordBraceSpace},
          showTestCase = show,
          testCaseSuffix = suffix1
        },
      TestGroup
        { label = "newlines-between-decls",
          testCases = (,) <$> [0, 1, 2] <*> allOptions,
          updateConfig = \(newlines, respectful) opts ->
            opts
              { poNewlinesBetweenDecls = pure newlines,
                poRespectful = pure respectful
              },
          showTestCase = \(newlines, respectful) ->
            show newlines ++ if respectful then " (respectful)" else "",
          testCaseSuffix = \(newlines, respectful) ->
            suffixWith [show newlines, if respectful then "respectful" else ""]
        },
      TestGroup
        { label = "haddock-style",
          testCases = allOptions,
          updateConfig = \haddockStyle opts -> opts {poHaddockStyle = pure haddockStyle},
          showTestCase = show,
          testCaseSuffix = suffix1
        },
      TestGroup
        { label = "respectful",
          testCases = allOptions,
          updateConfig = \respectful opts -> opts {poRespectful = pure respectful},
          showTestCase = show,
          testCaseSuffix = suffix1
        }
    ]
  where
    allOptions :: (Enum a, Bounded a) => [a]
    allOptions = [minBound .. maxBound]

    suffixWith xs = concatMap ('-' :) . filter (not . null) $ xs
    suffix1 a1 = suffixWith [show a1]

runTestGroup :: TestGroup -> Spec
runTestGroup TestGroup {..} =
  describe label $
    forM_ testCases $ \testCase ->
      it ("generates the correct output for: " ++ showTestCase testCase) $ do
        let inputFile = testDir </> toRelFile "input.hs"
            inputPath = fromRelFile inputFile
            outputFile = testDir </> toRelFile ("output" ++ testCaseSuffix testCase ++ ".hs")
            outputPath = fromRelFile outputFile
            config =
              defaultConfig
                { cfgPrinterOpts = updateConfig testCase defaultPrinterOpts,
                  cfgSourceType = detectSourceType inputPath,
                  cfgCheckIdempotence = True
                }

        input <- readFileUtf8 inputPath
        actual <-
          ormolu config inputPath (T.unpack input) `catch` \e -> do
            msg <- renderOrmoluException e
            expectationFailure' $ unlines ["Got ormolu exception:", "", msg]
        getFileContents outputFile >>= \case
          _ | shouldRegenerateOutput -> writeFileUtf8 outputPath actual
          Nothing ->
            expectationFailure "Output does not exist. Try running with ORMOLU_REGENERATE_EXAMPLES=1"
          Just expected ->
            when (actual /= expected) $
              expectationFailure . T.unpack $
                getDiff ("actual", actual) ("expected", expected)
  where
    testDir = toRelDir $ "data/fourmolu/" ++ label
    toRelDir name =
      case parseRelDir name of
        Just path -> path
        Nothing -> error $ "Not a valid directory name: " ++ show name
    toRelFile name =
      case parseRelFile name of
        Just path -> path
        Nothing -> error $ "Not a valid file name: " ++ show name

{--- Helpers ---}

getFileContents :: Path b File -> IO (Maybe Text)
getFileContents path = do
  fileExists <- doesFileExist path
  if fileExists
    then Just <$> readFileUtf8 (toFilePath path)
    else pure Nothing

getDiff :: (String, Text) -> (String, Text) -> Text
getDiff (s1Name, s1) (s2Name, s2) =
  T.pack . Doc.render $
    prettyContextDiff (Doc.text s1Name) (Doc.text s2Name) (Doc.text . T.unpack) $
      getContextDiff 2 (T.lines s1) (T.lines s2)

renderOrmoluException :: OrmoluException -> IO String
renderOrmoluException e =
  withSystemTempFile "PrinterOptsSpec" $ \fp handle -> do
    runTerm (printOrmoluException e) Never handle
    hClose handle
    readFile fp

expectationFailure' :: HasCallStack => String -> IO a
expectationFailure' msg = do
  withFrozenCallStack $ expectationFailure msg
  -- satisfy type-checker, since hspec's expectationFailure is IO ()
  error "unreachable"

shouldRegenerateOutput :: Bool
shouldRegenerateOutput =
  -- Use same env var as PrinterSpec.hs, to make it easy to regenerate everything at once
  unsafePerformIO $ isJust <$> lookupEnv "ORMOLU_REGENERATE_EXAMPLES"
{-# NOINLINE shouldRegenerateOutput #-}
