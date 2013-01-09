{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}

module Data.Git.Tree where

import           Bindings.Libgit2
import           Control.Concurrent.ParallelIO
import           Data.Git.Blob
import           Data.Git.Common
import           Data.Git.Error
import           Data.Git.Internal
import qualified Data.Map as M
import qualified Data.Text as T
import qualified Filesystem.Path.CurrentOS as F
import qualified Prelude

data TreeEntry = BlobEntry { blobEntry      :: ObjRef Blob
                           , blobEntryIsExe :: Bool }
               | TreeEntry { treeEntry      :: ObjRef Tree }

blobRefWithMode :: Bool -> Blob -> TreeEntry
blobRefWithMode mode b = BlobEntry (ObjRef b) mode

blobRef :: Blob -> TreeEntry
blobRef = blobRefWithMode False

exeBlobRef :: Blob -> TreeEntry
exeBlobRef = blobRefWithMode True

blobIdRef :: Oid -> Bool -> TreeEntry
blobIdRef (Oid coid)      = BlobEntry (IdRef coid)
blobIdRef (PartialOid {}) = throw ObjectRefRequiresFullOid

treeRef :: Tree -> TreeEntry
treeRef t = TreeEntry (ObjRef t)

treeIdRef :: Oid -> TreeEntry
treeIdRef (Oid coid)      = TreeEntry (IdRef coid)
treeIdRef (PartialOid {}) = throw ObjectRefRequiresFullOid

-- instance Eq TreeEntry where
--   (BlobEntry x x2) == (BlobEntry y y2) = x == y && x2 == y2
--   (TreeEntry x) == (TreeEntry y) = x == y
--   _ == _ = False

type TreeMap = M.Map Text TreeEntry

data Tree = Tree { treeInfo     :: Base Tree
                 , treeContents :: TreeMap }

instance Show Tree where
  show x = case gitId (treeInfo x) of
             Pending _ -> "Tree..."
             Stored y  -> "Tree#" ++ show y

instance Show TreeEntry where
  show (BlobEntry blob _) = "BlobEntry (" ++ show blob ++ ")"
  show (TreeEntry tree)   = "TreeEntry (" ++ show tree ++ ")"

instance Updatable Tree where
  getId x        = gitId (treeInfo x)
  objectRepo x   = gitRepo (treeInfo x)
  objectPtr x    = gitObj (treeInfo x)
  update         = writeTree
  lookupFunction = lookupTree
#if defined(PROFILING)
  loadObject' x y =
    maybe (throwIO ObjectLookupFailed) return =<< loadObject x y
#endif

newTreeBase :: Tree -> Base Tree
newTreeBase t =
  newBase (gitRepo (treeInfo t))
          (Pending (doWriteTree >=> return . snd)) Nothing

-- | Create a new, empty tree.
--
--   Since empty trees cannot exist in Git, attempting to write out an empty
--   tree is a no-op.
createTree :: Repository -> Tree
createTree repo =
  Tree { treeInfo =
            newBase repo (Pending (doWriteTree >=> return . snd)) Nothing
       , treeContents = M.empty }

lookupTree :: Repository -> Oid -> IO (Maybe Tree)
lookupTree repo oid =
  lookupObject' repo oid c'git_tree_lookup c'git_tree_lookup_prefix $
    \coid obj _ -> do
      entriesAList <- withForeignPtr obj $ \treePtr -> do
        entryCount <- c'git_tree_entrycount (castPtr treePtr)
        foldM
          (\m idx -> do
              entry   <- c'git_tree_entry_byindex (castPtr treePtr)
                                                 (fromIntegral idx)
              when (entry == nullPtr) $ throwIO ObjectLookupFailed
              entryId <- c'git_tree_entry_id entry
              coid    <- mallocForeignPtr
              withForeignPtr coid $ \coid' ->
                c'git_oid_cpy coid' entryId

              entryName  <- c'git_tree_entry_name entry
                            >>= peekCString >>= return . T.pack
              entryAttrs <- c'git_tree_entry_attributes entry
              entryType  <- c'git_tree_entry_type entry

              let entryObj = if entryType == c'GIT_OBJ_BLOB
                             then BlobEntry (IdRef (COid coid)) False
                             else TreeEntry (IdRef (COid coid))

              return ((entryName,entryObj):m))
          [] [0..(entryCount-1)]
      return Tree { treeInfo     = newBase repo (Stored coid) (Just obj)
                  , treeContents = M.fromList entriesAList }

doLookupTreeEntry :: [Text] -> Tree -> IO (Maybe TreeEntry)
doLookupTreeEntry [] t = return (Just (TreeEntry (ObjRef t)))
doLookupTreeEntry (name:names) t = do
  -- Lookup the current name in this tree.  If it doesn't exist, and there are
  -- more names in the path and 'createIfNotExist' is True, create a new Tree
  -- and descend into it.  Otherwise, if it exists we'll have @Just (TreeEntry
  -- {})@, and if not we'll have Nothing.

  -- Prelude.putStrLn $ "Tree: " ++ show t
  -- Prelude.putStrLn $ "Tree Entries: " ++ show (treeContents t)
  -- Prelude.putStrLn $ "Lookup: " ++ toString name
  y <- case M.lookup name (treeContents t) of
    Nothing -> return Nothing
    Just j  -> case j of
      BlobEntry b mode -> do
        bl <- loadObject b t
        for bl $ \x -> return $ BlobEntry (ObjRef x) mode
      TreeEntry t' -> do
        tr <- loadObject t' t
        for tr $ \x -> return $ TreeEntry (ObjRef x)

  -- Prelude.putStrLn $ "Result: " ++ show y
  -- Prelude.putStrLn $ "Names: " ++ show names
  if null names
    then return y
    else
      case y of
        Just (BlobEntry {}) -> throw TreeCannotTraverseBlob
        Just (TreeEntry (ObjRef t')) -> doLookupTreeEntry names t'
        _ -> return Nothing

lookupTreeEntry :: FilePath -> Tree -> IO (Maybe TreeEntry)
lookupTreeEntry = doLookupTreeEntry . splitPath

withGitTree :: Updatable b
            => ObjRef Tree -> b -> (Ptr C'git_tree -> IO a) -> IO a
withGitTree tref obj f =
  withForeignPtr (repositoryPtr (objectRepo obj)) $ \repoPtr ->
    case tref of
      IdRef (COid oid) -> withGitTreeOid repoPtr oid

      ObjRef (Tree { treeInfo = Base { gitId = Stored (COid oid) } }) ->
        withGitTreeOid repoPtr oid

      ObjRef (Tree { treeInfo = Base { gitObj = Just t } }) ->
        withForeignPtr t (f . castPtr)

      ObjRef t -> do t' <- update t
                     withGitTree (ObjRef t') obj f

  where withGitTreeOid repoPtr oid =
          withForeignPtr oid $ \tree_id ->
            alloca $ \ptr -> do
              r <- c'git_tree_lookup ptr repoPtr tree_id
              when (r < 0) $ throwIO TreeLookupFailed
              f =<< peek ptr

-- | Write out a tree to its repository.  If it has already been written,
--   nothing will happen.
writeTree :: Tree -> IO Tree
writeTree t@(Tree { treeInfo = Base { gitId = Stored _ } }) = return t
writeTree t = fst <$> doWriteTree t

doWriteTree :: Tree -> IO (Tree, COid)
doWriteTree t = alloca $ \ptr ->
  withForeignPtr repo $ \repoPtr -> do
    r <- c'git_treebuilder_create ptr nullPtr
    when (r < 0) $ throwIO TreeBuilderCreateFailed
    builder <- peek ptr

    -- jww (2012-10-14): With the loose object backend, there should be no
    -- race conditions here as there will never be a request to access the
    -- same file by multiple threads.  If that ever does happen, or if this
    -- code is changed to write to the packed object backend, simply change
    -- the function 'parallel' to 'sequence' here.
    oids <- parallel $
           flip map (M.toList (treeContents t)) $ \(k, v) ->
             case v of
               BlobEntry bl exe ->
                 withObject bl t $ \bl' -> do
                   bl'' <- update bl'
                   (Oid coid) <- objectId bl''
                   return (k, BlobEntry (ObjRef bl'') exe, coid,
                           if exe then 0o100755 else 0o100644)
               TreeEntry tr ->
                 withObject tr t $ \tr' -> do
                   tr'' <- update tr'
                   (Oid coid) <- objectId tr''
                   return (k, TreeEntry (ObjRef tr''), coid, 0o040000)

    newList <- for oids $ \(k, entry, coid, flags) -> do
                insertObject builder k coid flags
                return (k, entry)

    coid <- mallocForeignPtr
    withForeignPtr coid $ \coid' -> do
      r3 <- c'git_treebuilder_write coid' repoPtr builder
      when (r3 < 0) $ throwIO TreeBuilderWriteFailed

    return (t { treeInfo     = (treeInfo t) { gitId = Stored (COid coid) }
              , treeContents = M.fromList newList }, COid coid)

  where
    repo = fromMaybe (error "Repository invalid")
                     (repoObj (gitRepo (treeInfo t)))

    insertObject :: (CStringable a)
                 => Ptr C'git_treebuilder -> a -> COid -> CUInt -> IO ()
    insertObject builder key (COid coid) attrs =
      withForeignPtr coid $ \coid' ->
        withCStringable key $ \name -> do
          r2 <- c'git_treebuilder_insert nullPtr builder name coid' attrs
          when (r2 < 0) $ throwIO TreeBuilderInsertFailed

doModifyTree
  :: [Text] -> (Maybe TreeEntry -> Either a (Maybe TreeEntry)) -> Bool
  -> Tree -> IO (Either a Tree)
doModifyTree [] _ _ _     = throw TreeLookupFailed
doModifyTree (name:names) f createIfNotExist t = do
  -- Lookup the current name in this tree.  If it doesn't exist, and there are
  -- more names in the path and 'createIfNotExist' is True, create a new Tree
  -- and descend into it.  Otherwise, if it exists we'll have @Just (TreeEntry
  -- {})@, and if not we'll have Nothing.
  y <- case M.lookup name (treeContents t) of
    Nothing ->
      return $
        if createIfNotExist && not (null names)
        then Just . TreeEntry . ObjRef . createTree
             $ gitRepo (treeInfo t)
        else Nothing
    Just j -> case j of
      BlobEntry b mode -> do
        bl <- loadObject b t
        for bl $ \x -> return $ BlobEntry (ObjRef x) mode
      TreeEntry t' -> do
        tr <- loadObject t' t
        for tr $ \x -> return $ TreeEntry (ObjRef x)

  if null names
    then do
      -- If there are no further names in the path, call the transformer
      -- function, f.  It receives a @Maybe TreeEntry@ to indicate if there
      -- was a previous entry at this path.  It should return a 'Left' value
      -- to propagate out a user-defined error, or a @Maybe TreeEntry@ to
      -- indicate whether the entry at this path should be deleted or
      -- replaced with something new.
      --
      -- NOTE: There is no provision for leaving the entry unchanged!  It is
      -- assumed to always be changed, as we have no reliable method of
      -- testing object equality that is not O(n).
    let ze = f y
    case ze of
      Left err -> return $ Left err
      Right z ->
        return $ Right $
          t { treeInfo     = newTreeBase t
            , treeContents =
              case z of
                Nothing -> M.delete name (treeContents t)
                Just z' -> M.insert name z' (treeContents t) }

    else
      -- If there are further names in the path, descend them now.  If
      -- 'createIfNotExist' was False and there is no 'Tree' under the
      -- current name, or if we encountered a 'Blob' when a 'Tree' was
      -- required, throw an exception to avoid colliding with user-defined
      -- 'Left' values.
      case y of
        Just (BlobEntry {}) -> throw TreeCannotTraverseBlob
        Just (TreeEntry (ObjRef t')) -> do
          st <- doModifyTree names f createIfNotExist t'
          case st of
            err@(Left _) -> return err
            Right st' ->
              return $ Right $
                t { treeInfo     = newTreeBase t
                  , treeContents =
                    if M.null (treeContents st')
                    then M.delete name (treeContents t)
                    else M.insert name (TreeEntry (ObjRef st'))
                                  (treeContents t) }
        _ -> throw TreeLookupFailed

modifyTree
  :: FilePath -> (Maybe TreeEntry -> Either a (Maybe TreeEntry)) -> Bool
  -> Tree -> IO (Either a Tree)
modifyTree = doModifyTree . splitPath

doUpdateTree :: [Text] -> TreeEntry -> Tree -> IO Tree
doUpdateTree xs item t = do
  t' <- doModifyTree xs (const (Right (Just item))) True t
  case t' of
    Right tr -> return tr
    _ -> undefined

updateTree :: FilePath -> TreeEntry -> Tree -> IO Tree
updateTree = doUpdateTree . splitPath

removeFromTree :: FilePath -> Tree -> IO Tree
removeFromTree p tr = do
  t' <- modifyTree p (const (Right Nothing)) False tr
  case t' of
    Right tr' -> return tr'
    _ -> undefined

splitPath :: FilePath -> [Text]
splitPath path = T.splitOn "/" text
  where text = case F.toText path of
                 Left x  -> error $ "Invalid path: " ++ T.unpack x
                 Right y -> y

-- Tree.hs
