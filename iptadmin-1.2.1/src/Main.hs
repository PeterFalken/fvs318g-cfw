
module Main where

import Control.Concurrent (forkIO, killThread)
import Control.Exception
import Control.Monad.Error
import Control.Monad.State
import Data.IORef
import Data.List hiding (insert)
import Data.Map hiding (map)
import Data.Monoid
import Data.Version
import Happstack.Server.Internal.Monads
import Happstack.Server.SimpleHTTP
import Happstack.State.Control
import IptAdmin.AccessControl
import IptAdmin.AddChainPage as AddChainPage
import IptAdmin.AddPage as AddPage
import IptAdmin.Config
import IptAdmin.DelChainPage as DelChainPage
import IptAdmin.DelPage as DelPage
import IptAdmin.EditChainPage as EditChainPage
import IptAdmin.EditPage as EditPage
import IptAdmin.EditPolicyPage as EditPolicyPage
import IptAdmin.InsertPage as InsertPage
import IptAdmin.ShowPage as ShowPage
import IptAdmin.System
import IptAdmin.Types
import IptAdmin.Utils
import Network.Socket
import Paths_iptadmin (version)
import Prelude hiding (catch)
import System.Exit
import System.Environment
import System.Posix.Daemonize
import System.Posix.User
import System.Posix.Syslog

main :: IO ()
main = do
    args <- getArgs
    case args of
        ("--version":_) -> do
            let ver = intercalate "." $ map show $ versionBranch version
            putStrLn $ "Iptadmin v" ++ ver ++ ", (C) Evgeny Tarasov 2011"
            exitSuccess
        ("--help":_) -> do
            putStrLn $ "usage: iptadmin (start|stop|restart)"
            exitSuccess
        _ -> return ()

    checkRunUnderRoot

    configE <- catch (runErrorT getConfig) $
        \ e -> return $ Left $ show (e :: SomeException)
    case configE of
        Left e -> do
            putStrLn e
            exitFailure
        Right config ->
            serviced $ simpleDaemon {program = startDaemon config, user = Just "root", syslogOptions = [PID, PERROR]}

startDaemon :: IptAdminConfig -> a -> IO ()
startDaemon config _ = do
    sessions <- newIORef empty
    let httpConf = Conf (cPort config) Nothing Nothing 60

    -- create socket manually because we must listen only on 127.0.0.1
    sock <- socket AF_INET Stream defaultProtocol
    setSocketOption sock ReuseAddr 1
    loopbackIp <- inet_addr "127.0.0.1"
    bindSocket sock $
        SockAddrInet (fromInteger $ toInteger $ cPort config) loopbackIp
    listen sock (max 1024 maxListenQueue)

    httpTid <- forkIO $ simpleHTTPWithSocket' unpackErrorT
                                              sock
                                              httpConf
                                              $ decodeBody (defaultBodyPolicy "/tmp/" 4096 20000 40000 )
                                              >> authorize sessions config control
    waitForTermination
    syslog Notice "Shutting down..."
    killThread httpTid
    syslog Notice "Shutdown complete"

unpackErrorT :: (Monad m) => UnWebT (ErrorT String m) a -> UnWebT m a
unpackErrorT handler = do
    resE <- runErrorT handler
    case resE of
        Left err -> return $ Just (Left $ toResponse err, Set mempty)
        Right x -> return x

control :: IptAdmin Response
control = msum [ commitChange
               , nullDir >> redir "/show"
               , dir "logout" logout
               , dir "show" ShowPage.pageHandlers
               , dir "add" AddPage.pageHandlers
               , dir "insert" InsertPage.pageHandlers
               , dir "edit" EditPage.pageHandlers
               , dir "del" DelPage.pageHandlers
               , dir "addchain" AddChainPage.pageHandlers
               , dir "editchain" EditChainPage.pageHandlers
               , dir "delchain" DelChainPage.pageHandlers
               , dir "editpolicy" EditPolicyPage.pageHandlers
               ]

{- | Save changes if user have changed something
     He can access the program, so let's assume we haven't broken anything
-}
commitChange :: IptAdmin Response
commitChange = do
    (sessionId, sessionsIORef, _) <- lift get
    change <- liftIO $ atomicModifyIORef sessionsIORef $ \ m ->
        let session = m ! sessionId
        in
            case backup session of
                Nothing -> (m, False)
                Just _ ->
                    let session' = session {backup = Nothing}
                        m' = insert sessionId session' m
                    in
                        (m', True)
    when change saveIptables
    mzero

checkRunUnderRoot :: IO ()
checkRunUnderRoot = do
    userID_ <- getEffectiveUserID
    when (userID_ /= 0) $ do
        putStrLn "the program have to be run under root privileges"
        exitFailure
