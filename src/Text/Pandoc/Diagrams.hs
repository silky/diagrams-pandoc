{-# LANGUAGE CPP               #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Convert appropriately annotated Code blocks to an image, with or
-- without display of the code.  Interpret the Code blocks as Haskell
-- code using the Diagrams libraries.

module Text.Pandoc.Diagrams where

import           Data.List                       (delete)
import           Diagrams.Backend.Cairo
import           Diagrams.Backend.Cairo.Internal
import qualified Diagrams.Builder                as DB
import           Diagrams.Prelude                (centerXY, pad, (&), (.~))
import           Diagrams.Size                   (dims)
import           Linear                          (V2 (..), zero)
import           System.Directory                (createDirectoryIfMissing)
import           System.FilePath                 ((<.>), (</>), pathSeparator)
import           System.IO                       (stderr, stdout, hFlush)
import           Text.Pandoc.Definition
import           Data.Text                       (Text, pack, unpack, toLower)
import           Data.Text.IO

#if __GLASGOW_HASKELL__ < 710
import Control.Applicative
#endif

backendExt "beamer" = "pdf"
backendExt "latex" = "pdf"
backendExt _ = "png"

-- Return output type for a string
findOutputType "beamer" = PDF
findOutputType "latex" = PDF
findOutputType _ = PNG

data Opts = Opts {
    _outFormat    :: String,
    _outDir       :: FilePath,
    _expression   :: String,
    _absolutePath :: Bool
    }

data Echo = Above | Below

insertDiagrams :: Opts -> Block -> IO Block
insertDiagrams opts@(Opts _ _ _ absolutePath) (CodeBlock (ident, classes, attrs) code)
    | "diagram-haskell" `elem` classes = do
      i <- img
      return $ Div nullAttr $ case echo of
        Above -> [bl', i]
        Below -> [i, bl']
    | "diagram" `elem` classes = img
  where
    img = do
        d <- compileDiagram opts attrs code
        return $ case d of
            Left _err     -> Null  -- TODO log an error here
            Right imgName -> Plain [Image ("",[],[]) [] (if absolutePath then pack (pathSeparator : imgName) else pack imgName,"")] -- no alt text, no title
    bl' = CodeBlock (ident, "haskell":delete "diagram-haskell" classes, attrs) code
    echo = readEcho attrs
insertDiagrams _ block = return block

-- Copied from https://github.com/diagrams/diagrams-doc/blob/master/doc/Xml2Html.hs
-- With the CPP removed, thereby requiring Cairo
-- TODO clean this up, move it into -builder somehow
-- | Compile the literate source code of a diagram to a .png/.pdf file with
--   a file name given by a hash of the source code contents
compileDiagram :: Opts -> [(Text,Text)] -> Text -> IO (Either Text String)
compileDiagram opts attrs src = do
  ensureDir $ _outDir opts

  let
      bopts :: DB.BuildOpts Cairo V2 Double
      bopts = DB.mkBuildOpts

                Cairo

                zero

                ( CairoOptions "default.png"
                  (dims $ V2 (widthAttribute attrs) (heightAttribute attrs))
                  (findOutputType $ _outFormat opts)
                  False
                )

                & DB.snippets .~ [unpack src]
                & DB.imports  .~
                  [ "Diagrams.Backend.Cairo"
                  , "Data.Typeable"
                  ]
                & DB.pragmas .~ [ "DeriveDataTypeable"
                                , "DeriveGeneric"
                                , "GADTs"
                                , "FlexibleContexts"
                                , "StandaloneDeriving"
                                , "MultiParamTypeClasses"
                                ]
                & DB.diaExpr .~ (_expression opts)
                & DB.postProcess .~ (pad 1.1 . centerXY)
                & DB.decideRegen .~
                  (DB.hashedRegenerate
                    (\hash opts' -> opts' { _cairoFileName = mkFile hash })
                    (_outDir opts)
                  )

  res <- DB.buildDiagram bopts

  case res of
    DB.ParseErr err    -> do
      hPutStrLn stderr ("\nError while parsing\n" <> src)
      hPutStrLn stderr (pack err)
      return $ Left "Error while parsing"

    DB.InterpErr ierr  -> do
      hPutStrLn stderr ("\nError while interpreting\n" <> src)
      hPutStrLn stderr (pack (DB.ppInterpError ierr))
      return $ Left "Error while interpreting"

    DB.Skipped hash    -> do
      hPutStr stderr "."
      hFlush stderr
      return $ Right (mkFile (DB.hashToHexStr hash))

    DB.OK hash out -> do
      hPutStr stderr "O"
      hFlush stderr
      fst out
      return $ Right (mkFile (DB.hashToHexStr hash))

 where
  mkFile base = _outDir opts </> base <.> (backendExt $ _outFormat opts)
  ensureDir dir = do
    createDirectoryIfMissing True dir

widthAttribute :: [(Text,Text)] -> Double
widthAttribute attrs =
    case lookup "width" attrs of
        Nothing -> 500
        Just v  -> read (unpack v) :: Double

heightAttribute :: [(Text,Text)] -> Double
heightAttribute attrs =
    case lookup "height" attrs of
        Nothing -> 200
        Just v  -> read (unpack v) :: Double

readEcho :: [(Text, Text)] -> Echo
readEcho attrs = case lookup "echo" attrs of
  Nothing -> Below
  Just v -> case toLower v of
    "above" -> Above
    _ -> Below
