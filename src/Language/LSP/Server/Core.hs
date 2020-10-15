{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilyDependencies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE LambdaCase           #-}
{-# LANGUAGE GADTs                #-}
{-# LANGUAGE MultiWayIf           #-}
{-# LANGUAGE BinaryLiterals       #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE RankNTypes           #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE ViewPatterns         #-}
{-# LANGUAGE TypeInType           #-}
{-# LANGUAGE TypeApplications     #-}
{-# LANGUAGE RecordWildCards      #-}
{-# LANGUAGE NamedFieldPuns       #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE RecursiveDo #-}
{-# OPTIONS_GHC -Wno-unticked-promoted-constructors #-}
{-# OPTIONS_GHC -fprint-explicit-kinds #-}


module Language.LSP.Server.Core where

import           Control.Concurrent.Async
import           Control.Concurrent.STM
import qualified Control.Exception as E
import           Control.Monad
import           Control.Monad.Fix
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Reader
import           Control.Monad.Trans.Class
import           Control.Monad.IO.Unlift
import           Control.Lens ( (^.), (^?), _Just )
import qualified Data.Aeson as J
import           Data.Default
import           Data.Functor.Product
import           Data.IxMap
import qualified Data.Dependent.Map as DMap
import           Data.Dependent.Map (DMap)
import qualified Data.HashMap.Strict as HM
import           Data.Kind
import qualified Data.List as L
import           Data.List.NonEmpty (NonEmpty(..))
import qualified Data.Map as Map
import           Data.Maybe
import qualified Data.Text as T
import           Data.Text ( Text )
import qualified Data.UUID as UUID
import qualified Language.LSP.Types.Capabilities    as J
import Language.LSP.Types as J
import qualified Language.LSP.Types.Lens as J
import           Language.LSP.VFS
import           Language.LSP.Diagnostics
import           System.IO
import qualified System.Log.Formatter as L
import qualified System.Log.Handler as LH
import qualified System.Log.Handler.Simple as LHS
import           System.Log.Logger
import qualified System.Log.Logger as L
import           System.Random
import           Control.Monad.Trans.Identity

-- ---------------------------------------------------------------------
{-# ANN module ("HLint: ignore Eta reduce"         :: String) #-}
{-# ANN module ("HLint: ignore Redundant do"       :: String) #-}
{-# ANN module ("HLint: ignore Reduce duplication" :: String) #-}
-- ---------------------------------------------------------------------

newtype LspT config m a = LspT { unLspT :: ReaderT (LanguageContextEnv config) m a }
  deriving (Functor, Applicative, Monad, MonadIO, MonadTrans, MonadUnliftIO, MonadFix)

runLspT :: LanguageContextEnv config -> LspT config m a -> m a
runLspT env = flip runReaderT env . unLspT

type LspM config = LspT config IO

class MonadUnliftIO m => MonadLsp config m | m -> config where
  getLspEnv :: m (LanguageContextEnv config)

instance MonadUnliftIO m => MonadLsp config (LspT config m) where
  getLspEnv = LspT ask

instance MonadLsp c m => MonadLsp c (ReaderT r m) where
  getLspEnv = lift getLspEnv
instance MonadLsp c m => MonadLsp c (IdentityT m) where
  getLspEnv = lift getLspEnv

data LanguageContextEnv config =
  LanguageContextEnv
  { resHandlers            :: !(Handlers IO)
  , resParseConfig         :: !(J.Value -> IO (Either T.Text config))
  , resSendMessage         :: !(FromServerMessage -> IO ())
  -- We keep the state in a TVar to be thread safe
  , resState               :: !(TVar (LanguageContextState config))
  , resClientCapabilities  :: !J.ClientCapabilities
  , resRootPath            :: !(Maybe FilePath)
  }

-- ---------------------------------------------------------------------
-- Handlers
-- ---------------------------------------------------------------------

-- | A mapping from methods to the static 'Handler's that should be used to
-- handle responses when they come in from the client. To build up a 'Handlers',
-- you should 'mconcat' a list of 'notificationHandler' and 'requestHandler's:
--
-- @
-- mconcat [
--   notificationHandler SInitialized $ \notif -> pure ()
-- , requestHandler STextDocumentHover $ \req responder -> pure ()
-- ]
-- @ 
data Handlers m
  = Handlers
  { reqHandlers :: DMap SMethod (ClientMessageHandler m Request)
  , notHandlers :: DMap SMethod (ClientMessageHandler m Notification)
  }
instance Semigroup (Handlers config) where
  Handlers r1 n1 <> Handlers r2 n2 = Handlers (r1 <> r2) (n1 <> n2)
instance Monoid (Handlers config) where
  mempty = Handlers mempty mempty

notificationHandler :: forall (m :: Method FromClient Notification) f. SMethod m -> Handler f m -> Handlers f
notificationHandler m h = Handlers mempty (DMap.singleton m (ClientMessageHandler h))

requestHandler :: forall (m :: Method FromClient Request) f. SMethod m -> Handler f m -> Handlers f
requestHandler m h = Handlers (DMap.singleton m (ClientMessageHandler h)) mempty

-- | Wrapper to restrict 'Handler's to 'FromClient' 'Method's
newtype ClientMessageHandler f (t :: MethodType) (m :: Method FromClient t) = ClientMessageHandler (Handler f m)

-- | The type of a handler that handles requests and notifications coming in
-- from the server or client
type family Handler (f :: Type -> Type) (m :: Method from t) = (result :: Type) | result -> f t m where
  Handler f (m :: Method _from Request)      = RequestMessage m -> (Either ResponseError (ResponseResult m) -> f ()) -> f ()
  Handler f (m :: Method _from Notification) = NotificationMessage m -> f ()

-- | How to convert two isomorphic data structures between each other.
data m <~> n
  = Iso
  { forward :: forall a. m a -> n a
  , backward :: forall a. n a -> m a
  }

transmuteHandlers :: (m <~> n) -> Handlers m -> Handlers n
transmuteHandlers nat = mapHandlers (\i m k -> forward nat (i m (backward nat . k))) (\i m -> forward nat (i m))

mapHandlers
  :: (forall (a :: Method FromClient Request). Handler m a -> Handler n a)
  -> (forall (a :: Method FromClient Notification). Handler m a -> Handler n a)
  -> Handlers m -> Handlers n
mapHandlers mapReq mapNot (Handlers reqs nots) = Handlers reqs' nots'
  where
    reqs' = DMap.map (\(ClientMessageHandler i) -> ClientMessageHandler $ mapReq i) reqs
    nots' = DMap.map (\(ClientMessageHandler i) -> ClientMessageHandler $ mapNot i) nots

-- | state used by the LSP dispatcher to manage the message loop
data LanguageContextState config =
  LanguageContextState
  { resVFS                 :: !VFSData
  , resDiagnostics         :: !DiagnosticStore
  , resConfig              :: !(Maybe config)
  , resWorkspaceFolders    :: ![WorkspaceFolder]
  , resProgressData        :: !ProgressData
  , resPendingResponses    :: !ResponseMap
  , resRegistrationsNot    :: !(RegistrationMap Notification)
  , resRegistrationsReq    :: !(RegistrationMap Request)
  , resLspId               :: !Int
  }

type ResponseMap = IxMap LspId (Product SMethod ServerResponseCallback)

type RegistrationMap (t :: MethodType) = DMap SMethod (Product RegistrationId (ClientMessageHandler IO t))

data RegistrationToken (m :: Method FromClient t) = RegistrationToken (SMethod m) (RegistrationId m)
newtype RegistrationId (m :: Method FromClient t) = RegistrationId Text
  deriving Eq

data ProgressData = ProgressData { progressNextId :: !Int
                                 , progressCancel :: !(Map.Map ProgressToken (IO ())) }

data VFSData =
  VFSData
    { vfsData :: !VFS
    , reverseMap :: !(Map.Map FilePath FilePath)
    }

modifyState :: MonadLsp config m => (LanguageContextState config -> LanguageContextState config) -> m ()
modifyState f = do
  tvarDat <- resState <$> getLspEnv
  liftIO $ atomically $ modifyTVar' tvarDat f

stateState :: MonadLsp config m => (LanguageContextState config -> (a,LanguageContextState config)) -> m a
stateState f = do
  tvarDat <- resState <$> getLspEnv
  liftIO $ atomically $ stateTVar tvarDat f

getsState :: MonadLsp config m => (LanguageContextState config -> a) -> m a
getsState f = do
  tvarDat <- resState <$> getLspEnv
  liftIO $ f <$> readTVarIO tvarDat

-- ---------------------------------------------------------------------

-- | Language Server Protocol options that the server may configure.
-- If you set handlers for some requests, you may need to set some of these options.
data Options =
  Options
    { textDocumentSync                 :: Maybe J.TextDocumentSyncOptions
    -- |  The characters that trigger completion automatically.
    , completionTriggerCharacters      :: Maybe [Char]
    -- | The list of all possible characters that commit a completion. This field can be used
    -- if clients don't support individual commmit characters per completion item. See
    -- `_commitCharactersSupport`.
    , completionAllCommitCharacters    :: Maybe [Char]
    -- | The characters that trigger signature help automatically.
    , signatureHelpTriggerCharacters   :: Maybe [Char]
    -- | List of characters that re-trigger signature help.
    -- These trigger characters are only active when signature help is already showing. All trigger characters
    -- are also counted as re-trigger characters.
    , signatureHelpRetriggerCharacters :: Maybe [Char]
    -- | CodeActionKinds that this server may return.
    -- The list of kinds may be generic, such as `CodeActionKind.Refactor`, or the server
    -- may list out every specific kind they provide.
    , codeActionKinds                  :: Maybe [CodeActionKind]
    -- | The list of characters that triggers on type formatting.
    -- If you set `documentOnTypeFormattingHandler`, you **must** set this.
    -- The first character is mandatory, so a 'NonEmpty' should be passed.
    , documentOnTypeFormattingTriggerCharacters :: Maybe (NonEmpty Char)
    -- | The commands to be executed on the server.
    -- If you set `executeCommandHandler`, you **must** set this.
    , executeCommandCommands           :: Maybe [Text]
    -- | Information about the server that can be advertised to the client.
    , serverInfo                       :: Maybe J.ServerInfo
    }

instance Default Options where
  def = Options Nothing Nothing Nothing Nothing Nothing
                Nothing Nothing Nothing Nothing

defaultOptions :: Options
defaultOptions = def

-- | A package indicating the perecentage of progress complete and a
-- an optional message to go with it during a 'withProgress'
--
-- @since 0.10.0.0
data ProgressAmount = ProgressAmount (Maybe Double) (Maybe Text)

-- | Thrown if the user cancels a 'Cancellable' 'withProgress'/'withIndefiniteProgress'/ session
--
-- @since 0.11.0.0
data ProgressCancelledException = ProgressCancelledException
  deriving Show
instance E.Exception ProgressCancelledException

-- | Whether or not the user should be able to cancel a 'withProgress'/'withIndefiniteProgress'
-- session
--
-- @since 0.11.0.0
data ProgressCancellable = Cancellable | NotCancellable

-- | Contains all the callbacks to use for initialized the language server.
-- it is parameterized over a config type variable representing the type for the
-- specific configuration data the language server needs to use.
data ServerDefinition config = forall m a.
  ServerDefinition
    { onConfigurationChange :: J.Value -> m (Either T.Text config)
      -- ^ @onConfigurationChange newConfig@ is called whenever the
      -- clients sends a message with a changed client configuration. This
      -- callback should return either the parsed configuration data or an error
      -- indicating what went wrong. The parsed configuration object will be
      -- stored internally and can be accessed via 'config'.
    , doInitialize :: LanguageContextEnv config -> Message Initialize -> IO (Either ResponseError a)
      -- ^ Called *after* receiving the @initialize@ request and *before*
      -- returning the response. This callback will be invoked to offer the
      -- language server implementation the chance to create any processes or
      -- start new threads that may be necesary for the server lifecycle. It can
      -- also return an error in the initialization if necessary.
    , staticHandlers :: Handlers m
      -- ^ Handlers for any methods you want to statically support.
      -- The handlers here cannot be unregistered during the server's lifetime
      -- and will be regsitered statically in the initialize request.
    , interpretHandler :: a -> (m <~> IO)
      -- ^ How to run the handlers in your own monad of choice, @m@. 
      -- It is passed the result of 'doInitialize', so typically you will want
      -- to thread along the 'LanguageContextEnv' as well as any other state you
      -- need to run your monad. @m@ should most likely be built on top of
      -- 'LspT'.
      --
      -- @
      --  ServerDefinition { ...
      --  , doInitialize = \env _req -> pure $ Right env
      --  , interpretHandler = \env -> Iso 
      --     (runLspT env) -- how to convert from IO ~> m
      --     liftIO        -- how to convert from m ~> IO
      --  }
      -- @
    , options :: Options
      -- ^ Configurable options for the server's capabilities.
    }

-- | A function that a 'Handler' is passed that can be used to respond to a
-- request with either an error, or the response params.
newtype ServerResponseCallback (m :: Method FromServer Request)
  = ServerResponseCallback (Either ResponseError (ResponseResult m) -> IO ())

-- | Return value signals if response handler was inserted succesfully
-- Might fail if the id was already in the map
addResponseHandler :: MonadLsp config f => LspId m -> (Product SMethod ServerResponseCallback) m -> f Bool
addResponseHandler lid h = do
  stateState $ \ctx@LanguageContextState{resPendingResponses} ->
    case insertIxMap lid h resPendingResponses of
      Just m -> (True, ctx { resPendingResponses = m})
      Nothing -> (False, ctx)

sendNotification
  :: forall (m :: Method FromServer Notification) f config. MonadLsp config f
  => SServerMethod m
  -> MessageParams m
  -> f ()
sendNotification m params =
  let msg = NotificationMessage "2.0" m params
  in case splitServerMethod m of
        IsServerNot -> sendToClient $ fromServerNot msg
        IsServerEither -> sendToClient $ FromServerMess m $ NotMess msg

sendRequest :: forall (m :: Method FromServer Request) f config. MonadLsp config f
            => SServerMethod m
            -> MessageParams m
            -> (Either ResponseError (ResponseResult m) -> f ())
            -> f (LspId m)
sendRequest m params resHandler = do
  reqId <- IdInt <$> freshLspId
  rio <- askRunInIO
  success <- addResponseHandler reqId (Pair m (ServerResponseCallback (rio . resHandler)))
  unless success $ error "haskell-lsp: could not send FromServer request as id is reused"

  let msg = RequestMessage "2.0" reqId m params
  ~() <- case splitServerMethod m of
    IsServerReq -> sendToClient $ fromServerReq msg
    IsServerEither -> sendToClient $ FromServerMess m $ ReqMess msg
  return reqId

-- ---------------------------------------------------------------------

-- | Return the 'VirtualFile' associated with a given 'NormalizedUri', if there is one.
getVirtualFile :: MonadLsp config m => NormalizedUri -> m (Maybe VirtualFile)
getVirtualFile uri = getsState $ Map.lookup uri . vfsMap . vfsData . resVFS

getVirtualFiles :: MonadLsp config m => m VFS
getVirtualFiles = getsState $ vfsData . resVFS

-- | Dump the current text for a given VFS file to a temporary file,
-- and return the path to the file.
persistVirtualFile :: MonadLsp config m => NormalizedUri -> m (Maybe FilePath)
persistVirtualFile uri = do
  join $ stateState $ \ctx@LanguageContextState{resVFS = vfs} ->
    case persistFileVFS (vfsData vfs) uri of
      Nothing -> (return Nothing, ctx)
      Just (fn, write) ->
        let revMap = case uriToFilePath (fromNormalizedUri uri) of
              Just uri_fp -> Map.insert fn uri_fp $ reverseMap vfs
              -- TODO: Does the VFS make sense for URIs which are not files?
              -- The reverse map should perhaps be (FilePath -> URI)
              Nothing -> reverseMap vfs
            act = do
              liftIO write
              pure (Just fn)
        in (act, ctx{resVFS = vfs {reverseMap = revMap} })

-- | Given a text document identifier, annotate it with the latest version.
getVersionedTextDoc :: MonadLsp config m => TextDocumentIdentifier -> m VersionedTextDocumentIdentifier
getVersionedTextDoc doc = do
  let uri = doc ^. J.uri
  mvf <- getVirtualFile (toNormalizedUri uri)
  let ver = case mvf of
        Just (VirtualFile lspver _ _) -> Just lspver
        Nothing -> Nothing
  return (VersionedTextDocumentIdentifier uri ver)

-- TODO: should this function return a URI?
-- | If the contents of a VFS has been dumped to a temporary file, map
-- the temporary file name back to the original one.
reverseFileMap :: MonadLsp config m => m (FilePath -> FilePath)
reverseFileMap = do
  vfs <- getsState resVFS
  let f fp = fromMaybe fp . Map.lookup fp . reverseMap $ vfs
  return f

-- ---------------------------------------------------------------------

defaultProgressData :: ProgressData
defaultProgressData = ProgressData 0 Map.empty

-- ---------------------------------------------------------------------

sendToClient :: MonadLsp config m => FromServerMessage -> m ()
sendToClient msg = do
  f <- resSendMessage <$> getLspEnv
  liftIO $ f msg

-- ---------------------------------------------------------------------

sendErrorLog :: MonadLsp config m => Text -> m ()
sendErrorLog msg =
  sendToClient $ fromServerNot $
    NotificationMessage "2.0" SWindowLogMessage (LogMessageParams MtError msg)

-- ---------------------------------------------------------------------

freshLspId :: MonadLsp config m => m Int
freshLspId = do
  stateState $ \c ->
    (resLspId c, c{resLspId = resLspId c+1})

-- ---------------------------------------------------------------------

-- | The current configuration from the client as set via the @initialize@ and
-- @workspace/didChangeConfiguration@ requests.
getConfig :: MonadLsp config m => m (Maybe config)
getConfig = getsState resConfig

getClientCapabilities :: MonadLsp config m => m J.ClientCapabilities
getClientCapabilities = resClientCapabilities <$> getLspEnv

getRootPath :: MonadLsp config m => m (Maybe FilePath)
getRootPath = resRootPath <$> getLspEnv

-- | The current workspace folders, if the client supports workspace folders.
getWorkspaceFolders :: MonadLsp config m => m (Maybe [WorkspaceFolder])
getWorkspaceFolders = do
  clientCaps <- getClientCapabilities
  let clientSupportsWfs = fromMaybe False $ do
        let (J.ClientCapabilities mw _ _ _) = clientCaps
        (J.WorkspaceClientCapabilities _ _ _ _ _ _ mwf _) <- mw
        mwf
  if clientSupportsWfs
    then Just <$> getsState resWorkspaceFolders
    else pure Nothing

-- | Sends a @client/registerCapability@ request and dynamically registers
-- a 'Method' with a 'Handler'. Returns 'Nothing' if the client does not
-- support dynamic registration for the specified method, otherwise a
-- 'RegistrationToken' which can be used to unregister it later.
registerCapability :: forall f t (m :: Method FromClient t) config.
                      MonadLsp config f
                   => SClientMethod m
                   -> RegistrationOptions m
                   -> Handler f m
                   -> f (Maybe (RegistrationToken m))
registerCapability method regOpts f = do
  clientCaps <- resClientCapabilities <$> getLspEnv
  handlers <- resHandlers <$> getLspEnv
  let alreadyStaticallyRegistered = case splitClientMethod method of
        IsClientNot -> DMap.member method $ notHandlers handlers
        IsClientReq -> DMap.member method $ reqHandlers handlers
        IsClientEither -> error "Cannot register capability for custom methods"
  go clientCaps alreadyStaticallyRegistered
  where
    -- If the server has already registered statically, don't dynamically register
    -- as per the spec
    go _clientCaps True = pure Nothing
    go clientCaps  False
      -- First, check to see if the client supports dynamic registration on this method
      | dynamicSupported clientCaps = do
          uuid <- liftIO $ UUID.toText <$> getStdRandom random
          let registration = J.Registration uuid method regOpts
              params = J.RegistrationParams (J.List [J.SomeRegistration registration])
              regId = RegistrationId uuid
          rio <- askUnliftIO
          ~() <- case splitClientMethod method of
            IsClientNot -> modifyState $ \ctx ->
              let newRegs = DMap.insert method pair (resRegistrationsNot ctx)
                  pair = Pair regId (ClientMessageHandler (unliftIO rio . f))
                in ctx { resRegistrationsNot = newRegs }
            IsClientReq -> modifyState $ \ctx ->
              let newRegs = DMap.insert method pair (resRegistrationsReq ctx)
                  pair = Pair regId (ClientMessageHandler (\msg k -> unliftIO rio $ f msg (liftIO . k)))
                in ctx { resRegistrationsReq = newRegs }
            IsClientEither -> error "Cannot register capability for custom methods"

          -- TODO: handle the scenario where this returns an error
          _ <- sendRequest SClientRegisterCapability params $ \_res -> pure ()

          pure (Just (RegistrationToken method regId))
      | otherwise        = pure Nothing

    -- Also I'm thinking we should move this function to somewhere in messages.hs so
    -- we don't forget to update it when adding new methods...
    capDyn :: J.HasDynamicRegistration a (Maybe Bool) => Maybe a -> Bool
    capDyn (Just x) = fromMaybe False $ x ^. J.dynamicRegistration
    capDyn Nothing  = False

    -- | Checks if client capabilities declares that the method supports dynamic registration
    dynamicSupported clientCaps = case method of
      SWorkspaceDidChangeConfiguration -> capDyn $ clientCaps ^? J.workspace . _Just . J.didChangeConfiguration . _Just
      SWorkspaceDidChangeWatchedFiles  -> capDyn $ clientCaps ^? J.workspace . _Just . J.didChangeWatchedFiles . _Just
      SWorkspaceSymbol                 -> capDyn $ clientCaps ^? J.workspace . _Just . J.symbol . _Just
      SWorkspaceExecuteCommand         -> capDyn $ clientCaps ^? J.workspace . _Just . J.executeCommand . _Just
      STextDocumentDidOpen             -> capDyn $ clientCaps ^? J.textDocument . _Just . J.synchronization . _Just
      STextDocumentDidChange           -> capDyn $ clientCaps ^? J.textDocument . _Just . J.synchronization . _Just
      STextDocumentDidClose            -> capDyn $ clientCaps ^? J.textDocument . _Just . J.synchronization . _Just
      STextDocumentCompletion          -> capDyn $ clientCaps ^? J.textDocument . _Just . J.completion . _Just
      STextDocumentHover               -> capDyn $ clientCaps ^? J.textDocument . _Just . J.hover . _Just
      STextDocumentSignatureHelp       -> capDyn $ clientCaps ^? J.textDocument . _Just . J.signatureHelp . _Just
      STextDocumentDeclaration         -> capDyn $ clientCaps ^? J.textDocument . _Just . J.declaration . _Just
      STextDocumentDefinition          -> capDyn $ clientCaps ^? J.textDocument . _Just . J.definition . _Just
      STextDocumentTypeDefinition      -> capDyn $ clientCaps ^? J.textDocument . _Just . J.typeDefinition . _Just
      STextDocumentImplementation      -> capDyn $ clientCaps ^? J.textDocument . _Just . J.implementation . _Just
      STextDocumentReferences          -> capDyn $ clientCaps ^? J.textDocument . _Just . J.references . _Just
      STextDocumentDocumentHighlight   -> capDyn $ clientCaps ^? J.textDocument . _Just . J.documentHighlight . _Just
      STextDocumentDocumentSymbol      -> capDyn $ clientCaps ^? J.textDocument . _Just . J.documentSymbol . _Just
      STextDocumentCodeAction          -> capDyn $ clientCaps ^? J.textDocument . _Just . J.codeAction . _Just
      STextDocumentCodeLens            -> capDyn $ clientCaps ^? J.textDocument . _Just . J.codeLens . _Just
      STextDocumentDocumentLink        -> capDyn $ clientCaps ^? J.textDocument . _Just . J.documentLink . _Just
      STextDocumentDocumentColor       -> capDyn $ clientCaps ^? J.textDocument . _Just . J.colorProvider . _Just
      STextDocumentColorPresentation   -> capDyn $ clientCaps ^? J.textDocument . _Just . J.colorProvider . _Just
      STextDocumentFormatting          -> capDyn $ clientCaps ^? J.textDocument . _Just . J.formatting . _Just
      STextDocumentRangeFormatting     -> capDyn $ clientCaps ^? J.textDocument . _Just . J.rangeFormatting . _Just
      STextDocumentOnTypeFormatting    -> capDyn $ clientCaps ^? J.textDocument . _Just . J.onTypeFormatting . _Just
      STextDocumentRename              -> capDyn $ clientCaps ^? J.textDocument . _Just . J.rename . _Just
      STextDocumentFoldingRange        -> capDyn $ clientCaps ^? J.textDocument . _Just . J.foldingRange . _Just
      STextDocumentSelectionRange      -> capDyn $ clientCaps ^? J.textDocument . _Just . J.selectionRange . _Just
      _                                -> False

-- | Sends a @client/unregisterCapability@ request and removes the handler
-- for that associated registration.
unregisterCapability :: MonadLsp config f => RegistrationToken m -> f ()
unregisterCapability (RegistrationToken m (RegistrationId uuid)) = do
  ~() <- case splitClientMethod m of
    IsClientReq -> do
      reqRegs <- getsState resRegistrationsReq
      let newMap = DMap.delete m reqRegs
      modifyState (\ctx -> ctx { resRegistrationsReq = newMap })
    IsClientNot -> do
      notRegs <- getsState resRegistrationsNot
      let newMap = DMap.delete m notRegs
      modifyState (\ctx -> ctx { resRegistrationsNot = newMap })
    IsClientEither -> error "Cannot unregister capability for custom methods"

  let unregistration = J.Unregistration uuid (J.SomeClientMethod m)
      params = J.UnregistrationParams (J.List [unregistration])
  void $ sendRequest SClientUnregisterCapability params $ \_res -> pure ()

--------------------------------------------------------------------------------
-- PROGRESS
--------------------------------------------------------------------------------

storeProgress :: MonadLsp config m => ProgressToken -> Async a -> m ()
storeProgress n a = do
  let f = Map.insert n (cancelWith a ProgressCancelledException) . progressCancel
  modifyState $ \ctx -> ctx { resProgressData = (resProgressData ctx) { progressCancel = f (resProgressData ctx)}}

deleteProgress :: MonadLsp config m => ProgressToken -> m ()
deleteProgress n = do
  let f = Map.delete n . progressCancel
  modifyState $ \ctx -> ctx { resProgressData = (resProgressData ctx) { progressCancel = f (resProgressData ctx)}}

-- Get a new id for the progress session and make a new one
getNewProgressId :: MonadLsp config m => m ProgressToken
getNewProgressId = do
  stateState $ \ctx@LanguageContextState{resProgressData} ->
    let x = progressNextId resProgressData
        ctx' = ctx { resProgressData = resProgressData { progressNextId = x + 1 }}
    in (ProgressNumericToken x, ctx')

withProgressBase :: MonadLsp c m => Bool -> Text -> ProgressCancellable -> ((ProgressAmount -> m ()) -> m a) -> m a
withProgressBase indefinite title cancellable f = do

  progId <- getNewProgressId

  let initialPercentage
        | indefinite = Nothing
        | otherwise = Just 0
      cancellable' = case cancellable of
                      Cancellable -> True
                      NotCancellable -> False

  -- Create progress token
  -- FIXME  : This needs to wait until the request returns before
  -- continuing!!!
  _ <- sendRequest SWindowWorkDoneProgressCreate
        (WorkDoneProgressCreateParams progId) $ \res -> do
          case res of
            -- An error ocurred when the client was setting it up
            -- No need to do anything then, as per the spec
            Left _err -> pure ()
            Right () -> pure ()

  -- Send initial notification
  sendNotification SProgress $
    fmap Begin $ ProgressParams progId $
      WorkDoneProgressBeginParams title (Just cancellable') Nothing initialPercentage

  -- Send the begin and done notifications via 'bracket_' so that they are always fired
  res <- withRunInIO $ \runInBase ->
    E.bracket_
      -- Send begin notification
      (runInBase $ sendNotification SProgress $
        fmap Begin $ ProgressParams progId $
          WorkDoneProgressBeginParams title (Just cancellable') Nothing initialPercentage)

      -- Send end notification
      (runInBase $ sendNotification SProgress $
        End <$> ProgressParams progId (WorkDoneProgressEndParams Nothing)) $ do

      -- Run f asynchronously
      aid <- async $ runInBase $ f (updater progId)
      runInBase $ storeProgress progId aid
      wait aid

  -- Delete the progress cancellation from the map
  -- If we don't do this then it's easy to leak things as the map contains any IO action.
  deleteProgress progId

  return res
  where updater progId (ProgressAmount percentage msg) = do
          liftIO $ putStrLn "asdf"
          sendNotification SProgress $ fmap Report $ ProgressParams progId $
              WorkDoneProgressReportParams Nothing msg percentage

clientSupportsProgress :: J.ClientCapabilities -> Bool
clientSupportsProgress (J.ClientCapabilities _ _ wc _) = fromMaybe False $ do
  (J.WindowClientCapabilities mProgress) <- wc
  mProgress

-- | Wrapper for reporting progress to the client during a long running
-- task.
-- 'withProgress' @title cancellable f@ starts a new progress reporting
-- session, and finishes it once f is completed.
-- f is provided with an update function that allows it to report on
-- the progress during the session.
-- If @cancellable@ is 'Cancellable', @f@ will be thrown a
-- 'ProgressCancelledException' if the user cancels the action in
-- progress.
withProgress :: MonadLsp c m => Text -> ProgressCancellable -> ((ProgressAmount -> m ()) -> m a) -> m a
withProgress title cancellable f = do
  clientCaps <- getClientCapabilities
  if clientSupportsProgress clientCaps
    then withProgressBase False title cancellable f
    else f (const $ return ())

-- | Same as 'withProgress', but for processes that do not report the
-- precentage complete.
--
-- @since 0.10.0.0
withIndefiniteProgress :: MonadLsp c m => Text -> ProgressCancellable -> m a -> m a
withIndefiniteProgress title cancellable f = do
  clientCaps <- getClientCapabilities
  if clientSupportsProgress clientCaps
    then withProgressBase True title cancellable (const f)
    else f
    
-- ---------------------------------------------------------------------

-- | Aggregate all diagnostics pertaining to a particular version of a document,
-- by source, and sends a @textDocument/publishDiagnostics@ notification with
-- the total (limited by the first parameter) whenever it is updated.
publishDiagnostics :: MonadLsp config m => Int -> NormalizedUri -> TextDocumentVersion -> DiagnosticsBySource -> m ()
publishDiagnostics maxDiagnosticCount uri version diags = join $ stateState $ \ctx ->
  let ds = updateDiagnostics (resDiagnostics ctx) uri version diags
      ctx' = ctx{resDiagnostics = ds}
      mdp = getDiagnosticParamsFor maxDiagnosticCount ds uri
      act = case mdp of
        Nothing -> return ()
        Just params ->
          sendToClient $ J.fromServerNot $ J.NotificationMessage "2.0" J.STextDocumentPublishDiagnostics params
      in (act,ctx')

-- ---------------------------------------------------------------------

-- | Remove all diagnostics from a particular source, and send the updates to
-- the client.
flushDiagnosticsBySource :: MonadLsp config m => Int -- ^ Max number of diagnostics to send
                         -> Maybe DiagnosticSource -> m ()
flushDiagnosticsBySource maxDiagnosticCount msource = join $ stateState $ \ctx ->
  let ds = flushBySource (resDiagnostics ctx) msource
      ctx' = ctx {resDiagnostics = ds}
      -- Send the updated diagnostics to the client
      act = forM_ (HM.keys ds) $ \uri -> do
        let mdp = getDiagnosticParamsFor maxDiagnosticCount ds uri
        case mdp of
          Nothing -> return ()
          Just params -> do
            sendToClient $ J.fromServerNot $ J.NotificationMessage "2.0" J.STextDocumentPublishDiagnostics params
      in (act,ctx')

-- =====================================================================
--
--  utility


--
--  Logger
--
setupLogger :: Maybe FilePath -> [String] -> Priority -> IO ()
setupLogger mLogFile extraLogNames level = do

  logStream <- case mLogFile of
    Just logFile -> openFile logFile AppendMode `E.catch` handleIOException logFile
    Nothing      -> return stderr
  hSetEncoding logStream utf8

  logH <- LHS.streamHandler logStream level

  let logHandle  = logH {LHS.closeFunc = hClose}
      logFormatter  = L.tfLogFormatter logDateFormat logFormat
      logHandler = LH.setFormatter logHandle logFormatter

  L.updateGlobalLogger L.rootLoggerName $ L.setHandlers ([] :: [LHS.GenericHandler Handle])
  L.updateGlobalLogger "haskell-lsp" $ L.setHandlers [logHandler]
  L.updateGlobalLogger "haskell-lsp" $ L.setLevel level

  -- Also route the additional log names to the same log
  forM_ extraLogNames $ \logName -> do
    L.updateGlobalLogger logName $ L.setHandlers [logHandler]
    L.updateGlobalLogger logName $ L.setLevel level
  where
    logFormat = "$time [$tid] $prio $loggername:\t$msg"
    logDateFormat = "%Y-%m-%d %H:%M:%S%Q"

handleIOException :: FilePath -> E.IOException ->  IO Handle
handleIOException logFile _ = do
  hPutStr stderr $ "Couldn't open log file " ++ logFile ++ "; falling back to stderr logging"
  return stderr

-- ---------------------------------------------------------------------

-- | The changes in a workspace edit should be applied from the end of the file
-- toward the start. Sort them into this order.
reverseSortEdit :: J.WorkspaceEdit -> J.WorkspaceEdit
reverseSortEdit (J.WorkspaceEdit cs dcs) = J.WorkspaceEdit cs' dcs'
  where
    cs' :: Maybe J.WorkspaceEditMap
    cs' = (fmap . fmap ) sortTextEdits cs

    dcs' :: Maybe (J.List J.TextDocumentEdit)
    dcs' = (fmap . fmap ) sortTextDocumentEdits dcs

    sortTextEdits :: J.List J.TextEdit -> J.List J.TextEdit
    sortTextEdits (J.List edits) = J.List (L.sortBy down edits)

    sortTextDocumentEdits :: J.TextDocumentEdit -> J.TextDocumentEdit
    sortTextDocumentEdits (J.TextDocumentEdit td (J.List edits)) = J.TextDocumentEdit td (J.List edits')
      where
        edits' = L.sortBy down edits

    down (J.TextEdit r1 _) (J.TextEdit r2 _) = r2 `compare` r1
