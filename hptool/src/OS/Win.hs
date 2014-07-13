{-# LANGUAGE RecordWildCards, OverloadedStrings #-}

module OS.Win
    ( winOsFromConfig
    )
  where

import Control.Monad ( void, when )
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import Development.Shake
import Development.Shake.FilePath
import qualified Distribution.InstalledPackageInfo as C
import qualified Distribution.Package as C
import qualified System.Directory ( doesDirectoryExist )

import Dirs
import LocalCommand
import OS.Internal
import OS.Win.WinPaths
import OS.Win.WinRules
import OS.Win.WinUtils
import Paths
import Types
import Utils

winOsFromConfig :: BuildConfig -> OS
winOsFromConfig BuildConfig{..} = os
  where
    os = OS{..}
    HpVersion{..} = bcHpVersion
    GhcVersion{..} = bcGhcVersion

    osHpPrefix  = winHpPrefix
    osGhcPrefix = winGhcPrefix

    osGhcLocalInstall =
        GhcInstallCustom $ winGhcInstall ghcLocalDir
    osGhcTargetInstall =
        -- Windows installs HP and GHC in a single directory, so creating
        -- dependencies on the contents of winGhcTargetDir won't account
        -- for the HP pieces.  Also, for Windows, the ghc-bindist/local and
        -- the GHC installed into the targetDir should be identical.
        -- osTargetAction is the right place to do the targetDir snapshot.
        GhcInstallCustom $ \bc distDir -> do
            void $ winGhcInstall winGhcTargetDir bc distDir
            return ghcLocalDir

    -- Cabal on Windows requires an absolute, native-format prefix.
    toCabalPrefix = toNative . ("C:/" ++)
    osToCabalPrefix = toCabalPrefix

    osPackageTargetDir p = winHpPrefix </> packagePattern p

    -- The ghc-7.8.2 build for Windows does not have pre-built .dyn_hi files
    osDoShared = False

    osPackagePostRegister p = do
        let confFile = packageTargetConf p
        whenM (doesFileExist confFile) $ pkgrootConfFixup os confFile

    osPackageInstallAction p = do
        putLoud $ "osPackageInstallAction: " ++ show p

        -- First, "install" the packages into winTargetDir.
        -- 
        -- This is not "installing"; this is simply "copying"; later on, we
        -- check consistency to be sure.  Furthermore, the Shake actions
        -- are run in parallel, so registering via ghc-pkg at this point
        -- can result in failures, as the conf files need to be installed
        -- in dependency order, which cannot be expected due
        -- to the parallel builds coupled with laziness in Shake actions.
        -- These could possibly be resolved by creating a Rule for the
        -- ghc-pkg register, but this might hurt the parallel builds.
        let confFile = packageTargetConf p
        whenM (doesFileExist confFile) $ do
            confStr <- liftIO . B.readFile $ confFile
            pkgInfo <- parseConfFile confFile (B8.unpack confStr)
            let (C.InstalledPackageId pkgid) = C.installedPackageId pkgInfo
                -- need the long name of the package
                pkgDbConf = winGhcTargetPackageDbDir </> pkgid <.> "conf"
            command_ [] "cp" ["-p", confFile, pkgDbConf]

        -- Second, for this package, move the contents of the doc and bin
        -- directories to $winTargetDir/lib/extralibs/{doc,bin}
        let pkgDir = targetDir </+> osPackageTargetDir p
            pkgDocS = pkgDir </> "doc"
            pkgBinS = pkgDir </> "bin"

        copyDirContents pkgDocS (winHpTargetDir </> "doc" </> show p)
        copyDirContents pkgBinS (winHpTargetDir </> "bin")


    -- We arrived in osPackageInstallAction due to a "cabal copy" and we
    -- must complete that step before noting any files as dependencies.
    -- Thus, since we will be moving some of these files right here,
    -- use System.Directory to probe files and directories, to avoid
    -- creating Shake dependencies on those moved locations
    copyDirContents srcDir dstDir = do
        let relDstDir = dstDir ® srcDir
        putLoud $ "copyDirContents: " ++ show srcDir ++ " to " ++ relDstDir
        whenM (liftIO $ System.Directory.doesDirectoryExist srcDir) $ do
            makeDirectory dstDir
            command_ [Cwd srcDir] "cp" ["-pR", "./", relDstDir]
            removeDirectoryRecursive srcDir

    whenM :: (Monad m) => m Bool -> m () -> m ()
    whenM mp m = mp >>= \p -> when p m

    osTargetAction = do
        copyWinTargetExtras
        -- Now, targetDir is actually ready to snapshot (we skipped doing
        -- this in osGhcTargetInstall).
        void $ getDirectoryFiles "" [targetDir ++ "//*"]

    osGhcDbDir = winGhcPackageDbDir
    osDocAction = return ()

    osProduct = winProductFile hpVersion bcArch

    osRules _rel _bc = do
        winRules

        osProduct *> \_ -> do
            need $ [dir ghcLocalDir, targetDir, vdir ghcVirtualTarget]
                   ++ winNeeds

            -- Now, it is time to make sure there are no problems with the
            -- conf files copied to 
            localCommand' [] "ghc-pkg"
                [ "recache"
                , "--package-db=" ++ winGhcTargetPackageDbDir ]
            localCommand' [] "ghc-pkg"
                [ "check"
                , "--package-db=" ++ winGhcTargetPackageDbDir ]

          -- Build installer now; makensis must be run in installerPartsDir
            command_ [Cwd installerPartsDir] "makensis" [nsisFileName]