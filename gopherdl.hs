import qualified Data.Set as Set
import qualified Text.Regex.PCRE as Regex
import qualified Text.Regex.PCRE.String as PCRE
import Data.List
import Data.Maybe
import Data.Strings
import Network.URI (URI, parseURI, uriAuthority, uriPath, uriRegName, uriPort)
import Network.Socket
import Control.Exception
import Control.Monad
import System.IO
import System.Directory (createDirectoryIfMissing, doesPathExist)
import Data.ByteString (hPut)
import System.FilePath.Posix
import qualified System.Environment as Env
import qualified Network.Socket.ByteString as BsNet
import qualified Data.ByteString.Char8 as C
import System.Console.GetOpt (OptDescr(Option),
                              ArgDescr(NoArg, ReqArg),
                              getOpt,
                              ArgOrder(RequireOrder),
                              usageInfo)

{- TODO
  - Implement -w
  - Find a smarter way of applying common filters to gophermaps and files
  - rename and move myReadFile to helpers
  - compile time debug switch from build tool (stack?)
  - Smarter way of passing in regex... Maybe a "recursive options" data struct?
  - Can regex be an empty string? That would declutter maybes and is probably fast...
    - Clean up regex handling/conversion in general!
-}

sendAll = BsNet.sendAll
type ByteString = C.ByteString

-- type text \t path \t host \t port \r\n
type MenuLine = (Char, ByteString, ByteString, ByteString, ByteString)

data UrlType = 
    File 
  | Menu 
    deriving (Show, Eq, Ord)

-- host path port
data GopherUrl = GopherUrl 
  { host :: String
  , path :: String
  , port :: String
  , urlT :: UrlType } deriving (Show, Eq, Ord)

data Flag = 
      Recursive
    | MaxDepth Int
    | SpanHosts
    | Help
    | Clobber
    | OnlyMenus
    | NoMenus
    | ConstrainPath
    | RejectRegex String
    | AcceptRegex String
    | Delay Float deriving (Eq, Show, Ord)

data Config = Config
 {  recursive :: Bool
  , maxDepth :: Int
  , spanHosts :: Bool
  , help :: Bool
  , clobber :: Bool
  , onlyMenus :: Bool
  , constrainPath :: Bool
  , rejectRegex :: String
  , acceptRegex :: String
  , delay :: Float } deriving Show

okByRegex :: Config -> GopherUrl -> IO Bool
okByRegex conf url = do
  compRejectRegex <- compileRegex (rejectRegex conf)
  compAcceptRegex <- compileRegex (acceptRegex conf)
  okByRegex' url compRejectRegex compAcceptRegex

{-- Given 2 regex's, an accept and a reject, figure out whether the URL passes or not --}
okByRegex' :: GopherUrl -> Maybe PCRE.Regex -> Maybe PCRE.Regex -> IO Bool
okByRegex' url Nothing Nothing = return True
okByRegex' url (Just reject) Nothing = fmap not $ urlMatchesRegex reject url
okByRegex' url Nothing (Just accept) = urlMatchesRegex accept url
okByRegex' url (Just reject) (Just accept) = do
  overrideReject <- urlMatchesRegex accept url
  rejectIt <- fmap not $ urlMatchesRegex reject url
  return $ overrideReject || rejectIt

okByExists :: Config -> GopherUrl -> IO Bool
okByExists conf url
  | (clobber conf)       = return True 
  | (not (clobber conf)) = doesPathExist (urlToFilePath url)

okByHost :: Config -> GopherUrl -> GopherUrl -> Bool
okByHost conf url1 url2
  | (spanHosts conf)       = True
  | (not (spanHosts conf)) = sameHost url1 url2

okByPath :: Config -> GopherUrl -> GopherUrl -> Bool
okByPath conf url1 url2
  | (constrainPath conf)       = commonPathBase url1 url2
  | (not (constrainPath conf)) = True

{- Accept vs reject behavior is as follows:
  . Just -A -> Only accept urls that match -A
  . Just -R -> Accept all but filter out those that match -R
  . -R and -A -> Download all, rejecting -R, but use -A for exceptions -}
okByType :: Config -> GopherUrl -> Bool
okByType conf url
  | (onlyMenus conf) = (urlT url) == Menu
  | True             = True


{---------------------}
{------ Helpers ------}
{---------------------}

_debug = False

debugLog :: Show a => a -> IO a
debugLog a =
  (if _debug
    then (hPutStrLn stderr ("DEBUG: " ++ show a) 
         >> hFlush stderr)
    else return ()) >> return a

recvAllToFile :: Socket -> FilePath -> IO ()
recvAllToFile sock path =
  withFile path WriteMode (recvAllToHandle sock)

recvAllToHandle :: Socket -> Handle -> IO ()
recvAllToHandle sock hndl =
  BsNet.recv sock 4096 
  >>= \bytes -> 
    hPut hndl bytes -- Write bytes to file
    >> recvMore bytes
  where 
   recvMore bytes =
     if (C.length bytes) == 0
       then close sock
       else recvAllToHandle sock hndl

recvAll :: Socket -> IO ByteString
recvAll sock = 
  BsNet.recv sock 4096
  >>= recvMore 
  >>= \bytes -> close sock >> return bytes
  where 
   recvMore bytes =
     if (C.length bytes) == 0
       then return bytes
       else recvAll sock >>= return . C.append bytes

appendCRLF :: String -> String
appendCRLF s = s ++ "\r\n"

addrInfoHints :: AddrInfo
addrInfoHints = defaultHints { addrSocketType = Stream }

isFileUrl url = (urlT url) == File

showUsage = 
  putStr $ usageInfo "gopherdl [options] [urls]" optionSpec

sameHost url1 url2 =
  (host url1) == (host url2)

fixProto s = 
  let noProto s = (snd (strSplit "://" s)) == "" in
  if (noProto s) then ("gopher://" ++ s) else s

commonPathBase prevUrl nextUrl = 
  strStartsWith (path nextUrl) (path prevUrl) 

implies cond fn =
  if cond then fn else True

sanitizePath path = 
  let nonEmptyString = (/=) 0 . sLen in
  filter nonEmptyString $ strSplitAll "/" path

parseGopherUrl :: String -> Maybe GopherUrl
parseGopherUrl =
  uriToGopherUrl . parseURI . fixProto

{--------------------------}
{------ Argv Parsing ------}
{--------------------------}

compileRegex :: String -> IO (Maybe Regex.Regex)
compileRegex "" = return Nothing
compileRegex reStr = 
  PCRE.compile PCRE.compBlank PCRE.execBlank reStr
  >>= extractRegex
  where 
    extractRegex (Left (offset, errs)) = putStrLn errs >> hFlush stdout >> (return Nothing)
    extractRegex (Right regex) = return (Just regex)

optionSpec = 
  let argMaxDepth depth = (MaxDepth (read depth::Int)) 
      argDelay delay = (Delay (read delay::Float)) 
      rejectRegex s = (RejectRegex s)
  in
  [ Option "r" [] (NoArg Recursive) "Enable recursive downloads"
  , Option "l" [] (ReqArg argMaxDepth "n") "Maximum depth in recursive downloads"
  , Option "s" [] (NoArg SpanHosts) "Span hosts on recursive downloads"
  , Option "h" [] (NoArg Help) "Show this help"
  , Option "c" [] (NoArg Clobber) "Enable file clobbering (overwrite existing)"
  , Option "m" [] (NoArg OnlyMenus) "Only download gopher menus"
  , Option "p" [] (NoArg ConstrainPath) "Only descend into child directories"
  , Option "w" [] (ReqArg argDelay "secs") "Delay between downloads"
  , Option "R" [] (ReqArg rejectRegex "pcre") "Reject URL based on pcre" ]

isMaxDepth (MaxDepth _) = True
isMaxDepth otherwise = False

isDelay (Delay _) = True
isDelay otherwise = False

isRejectRegex (RejectRegex _) = True
isRejectRegex otherwise = False

isAcceptRegex (AcceptRegex _) = True
isAcceptRegex otherwise = False

findMaxDepth def options =
  case (find isMaxDepth options) of
    Just (MaxDepth d) -> d
    _ -> def

findDelay def options =
  case (find isDelay options) of
    Just (Delay d) -> d
    _ -> def

findRejectRegex :: String -> [Flag] -> String
findRejectRegex def options =
  case (find isRejectRegex options) of
    Just (RejectRegex restr) -> restr
    _ -> def

findAcceptRegex :: String -> [Flag] -> String
findAcceptRegex def options =
  case (find isAcceptRegex options) of
    Just (AcceptRegex restr) -> restr
    _ -> def

configFromGetOpt :: ([Flag], [String], [String]) -> ([String], Config)
configFromGetOpt (options, arguments, errors) = 
  ( arguments, 
    Config { recursive = has Recursive
           , maxDepth = findMaxDepth 99 options
           , spanHosts = has SpanHosts
           , help = has Help
           , clobber = has Clobber
           , onlyMenus = has OnlyMenus
           , constrainPath = has ConstrainPath
           , delay = findDelay 0.0 options
           , rejectRegex = findRejectRegex "" options
           , acceptRegex = findAcceptRegex "" options })
  where 
    has opt = opt `elem` options 

parseWithGetOpt :: [String] -> ([Flag], [String], [String])
parseWithGetOpt argv = getOpt RequireOrder optionSpec argv

argvToConfig :: [String] -> ([String], Config)
argvToConfig = configFromGetOpt . parseWithGetOpt

uriToGopherUrl :: Maybe URI -> Maybe GopherUrl
uriToGopherUrl Nothing = Nothing
uriToGopherUrl (Just uri) =
  case (uriAuthority uri) of
    Just auth -> 
      Just $ GopherUrl
        { host = (getHost auth)
        , path = (getPath uri)
        , port = (getPort auth)
        , urlT = Menu }
    otherwise -> Nothing
  where 
    (?>>) a def = if a == "" then def else a
    getHost auth = (uriRegName auth)
    getPath uri = (uriPath uri) ?>> "/"
    getPort auth = (strDrop 1 (uriPort auth)) ?>> "70"

{------------------------}
{----- Menu Parsing -----}
{------------------------}

mlToUrl :: MenuLine -> GopherUrl
mlToUrl (t, _, _path, _host, _port) =
  GopherUrl { host = C.unpack _host 
            , path = C.unpack _path
            , port = C.unpack _port
            , urlT = (if t == '1' then Menu else File)}

urlToString :: GopherUrl -> String
urlToString url =
  (host url) ++ ":" ++ (port url) ++ (path url)

validLine :: MenuLine -> Bool
validLine line = 
  validPath line && validType line
  where 
    validPath (_, _, path, _, _) = 
      sStartsWith path (C.pack "/")
    validType (t, _, _, _, _) = 
      t `notElem` ['7', '2', '3', '8', 'T']

parseMenu :: ByteString -> [MenuLine]
parseMenu rawMenu = 
  let lines = map parseMenuLine $ C.lines rawMenu in
  filter validLine $ catMaybes $ lines

parseMenuLine :: ByteString -> Maybe MenuLine
parseMenuLine line = 
  case (strSplitAll "\t" line) of
    [t1, t2, t3, t4] -> Just $ parseToks t1 t2 t3 t4
    otherwise -> Nothing
  where
    parseToks front path host port =
      ( (strHead front)   -- Type
      , (strDrop 1 front) -- User Text
      , (strTrim path)
      , (strTrim host)
      , (strTrim port) )

{---------------}
{------ IO -----}
{---------------}

gopherGetRaw :: GopherUrl -> IO ByteString
gopherGetRaw url =
  getAddrInfo (Just addrInfoHints) (Just (host url)) (Just (port url))
  >>= return . addrAddress . head 
  >>= \addr -> socket AF_INET Stream 0 
    >>= \sock -> connect sock addr
      >> sendAll sock (C.pack $ appendCRLF (path url))
      >> recvAll sock

urlToFilePath :: GopherUrl -> FilePath
urlToFilePath url = 
  joinPath $
    ([(host url) ++ ":" ++ (port url)] ++
    (sanitizePath (path url)) ++
    [(if ((urlT url) == Menu) then "gophermap" else "")])

save :: ByteString -> GopherUrl -> IO ()
save bs url =
  let out = urlToFilePath url in
  createDirectoryIfMissing True (dropFileName out) >>
  withFile out WriteMode writeIt
  where
    writeIt handle = hPut handle bs >> hFlush handle

getAndSaveMenu :: GopherUrl -> IO [MenuLine]
getAndSaveMenu url = 
  gopherGetRaw url 
    >>= \bs -> save bs url
    >> return (parseMenu bs)

getAndSaveFile :: GopherUrl -> IO ByteString
getAndSaveFile url = 
  gopherGetRaw url 
    >>= \bs -> save bs url
    >> return bs

-- If file exists on disk, read it instead of accessing network
getAndSaveMenuCheckExists :: GopherUrl -> IO [MenuLine]
getAndSaveMenuCheckExists url = 
  let path = urlToFilePath url in
  doesPathExist path
  >>= \exists -> 
    if exists 
      then (myReadFile path >>= return . parseMenu . C.pack)
      else getAndSaveMenu url
  where 
    myReadFile path =
      openFile path ReadMode
      >>= \h -> hSetEncoding h char8
      >> hGetContents h

getRecursively :: GopherUrl -> Config -> IO (Maybe Regex.Regex) -> IO [GopherUrl]
getRecursively url conf iocre =
  iocre >>= \cr ->
    crawlMenu url conf (maxDepth conf) Set.empty cr

crawlMenu :: GopherUrl -> Config -> Int -> Set.Set GopherUrl -> Maybe (Regex.Regex) -> IO [GopherUrl]
crawlMenu url conf depth history cr =
  let depthLeft = ((maxDepth conf) - depth) 
      depthMsg = "[" ++ (show depthLeft) ++ "/" ++ (show (maxDepth conf)) ++ "] " 
  in
  putStrLn ("(menu) " ++ depthMsg ++ (urlToString url))
  >> getMenuMaybeFromDisk url
  >>= debugLog
  >>= filterM okUrl
  >>= return . map mlToUrl . filter okLine
  >>= \remotes ->
    let urlSet = Set.fromList remotes in
    mapM (getRemotes conf depth (Set.union urlSet history) cr) remotes
    >>= return . concat
  where
    getMenuMaybeFromDisk = 
      if (clobber conf) 
        then getAndSaveMenu
        else getAndSaveMenuCheckExists
    okLine ml = 
      notInHistory ml && okHost ml && okPath ml
    okUrl ml = 
      if (isJust cr) 
        then fmap not (urlMatchesRegex (fromJust cr) (mlToUrl ml))
        else return True
    notInHistory ml = 
      (mlToUrl ml) `Set.notMember` history
    okPath ml =
      (constrainPath conf) `implies` (commonPathBase url (mlToUrl ml))
    okHost ml =
      not (spanHosts conf) `implies` (sameHost url (mlToUrl ml))

getRemotes :: Config -> Int -> Set.Set GopherUrl -> Maybe (Regex.Regex) -> GopherUrl -> IO [GopherUrl]
getRemotes conf depth history cr url = 
  case (urlT url) of
    File -> return [url]
    Menu -> fmap ((:) url) nextRemotes
      where 
        nextRemotes = if atMaxDepth then return [] else getNextRemotes
        atMaxDepth = (depth - 1) == 0
        getNextRemotes = crawlMenu url conf (depth - 1) history cr

gopherGetMenu :: GopherUrl -> IO (ByteString, [MenuLine])
gopherGetMenu url = 
  debugLog ("gopherGetMenu: " ++ (urlToString url))
  >> gopherGetRaw url 
  >>= \bytes -> return $ (bytes, parseMenu bytes)

getAndSaveFilePrintStatus :: GopherUrl -> IO ()
getAndSaveFilePrintStatus url =
  putStr ("(file) " ++ (urlToString url) ++ " ") >>
  hFlush stdout >>
  getAndSaveFile url 
  >>= \bs -> putStrLn ("(" ++ (show ((C.length bs) `div` 1000)) ++ "k)") >>
  hFlush stdout

{-----------------}
{------ Main -----}
{-----------------}

-- Get Argv, turn it into a Config
main :: IO ()
main = Env.getArgs 
  >>= main' . argvToConfig

-- Check sanity of config and args
main' :: ([String], Config) -> IO ()
main' (args, conf)
  | helpFlag || noArg = showUsage 
  | failedParsingUrl = putStrLn "Cannot Parse URL(s)" >> showUsage
  | otherwise = mapM_ (main'' conf) parsedUrls >> putStrLn ":: Done"
  where 
    helpFlag = (help conf)
    noArg = (length args) == 0
    parsedUrls = catMaybes $ map parseGopherUrl args
    failedParsingUrl = (length args) /= (length parsedUrls)

-- Handle each gopher URL
main'' :: Config -> GopherUrl -> IO ()
main'' conf url
  | (recursive conf) = 
    let cre = (compileRegex (rejectRegex conf)) in
    cre >>
    putStrLn ":: Downloading menus" >>
    getRecursively url conf cre
    >>= return . filter isFileUrl
    >>= \allRemotes -> filterM (goodUrl conf cre) allRemotes
      >>= \remotes -> downloadSaveUrls ((length allRemotes) - (length remotes)) remotes
  | otherwise =
    putStrLn ":: Downloading single file" >>
    mapM_ getAndSaveFilePrintStatus [url]

-- TODO: Assumes it's a normal, make correct???
urlExistsLocally :: GopherUrl -> IO Bool
urlExistsLocally url = 
  doesPathExist (urlToFilePath url)
  >>= debugLog

urlMatchesRegex :: PCRE.Regex -> GopherUrl -> IO Bool
urlMatchesRegex cr url =
  stringMatchesRegex cr (urlToString url)

stringMatchesRegex :: PCRE.Regex -> String -> IO Bool
stringMatchesRegex re url =
  PCRE.execute re url
  >>= \result ->
    return $ 
      (case result of
        Left err -> False
        Right (Just _) -> True
        Right _ -> False)

goodUrl :: Config -> IO (Maybe Regex.Regex) -> GopherUrl -> IO Bool
goodUrl conf iore url = 
  iore >>= \re ->
    sequence [(fmap not (regexMatches re url)), (goodUrl' conf url)]
    >>= return . all (==True)

-- True = Remove it
goodUrl' :: Config -> GopherUrl -> IO Bool
goodUrl' conf url
  | (onlyMenus conf) = return False
  | (clobber conf) = return True
  | otherwise = fmap not (urlExistsLocally url)

regexMatches re url
  | isJust re = urlMatchesRegex (fromJust re) url
  | otherwise = return False

downloadSaveUrls :: Int -> [GopherUrl]-> IO ()
downloadSaveUrls skipping fileUrls = 
  let nFiles = (length fileUrls)
      skippingMsg = "(skipping " ++ (show skipping) ++ ")"
      msg = (":: Downloading " ++ (show nFiles) ++ " files ")
  in
  putStrLn (msg ++ skippingMsg) >>
  mapM_ getAndSaveFilePrintStatus fileUrls
