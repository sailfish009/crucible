-----------------------------------------------------------------------
-- |
-- Module           : Lang.Crucible.Simulator.Operations
-- Description      : Basic operations on execution trees
-- Copyright        : (c) Galois, Inc 2014-2018
-- License          : BSD3
-- Maintainer       : Joe Hendrix <jhendrix@galois.com>
-- Stability        : provisional
--
-- Operations corresponding to basic control-flow events on
-- simulator execution trees.
------------------------------------------------------------------------

{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -fprint-explicit-kinds -Wall #-}
module Lang.Crucible.Simulator.Operations
  ( -- * Control-flow operations
    continue
  , jumpToBlock
  , conditionalBranch
  , variantCases
  , returnValue
  , returnAndMerge
  , runOverride
  , runAbortHandler
  , runErrorHandler
  , runGenericErrorHandler
  , performIntraFrameMerge
  , resumeFrame

    -- * Resolving calls
  , ResolvedCall(..)
  , UnresolvableFunction(..)
  , resolveCall

    -- * Abort handlers
  , abortExecAndLog
  , abortExec
  , defaultAbortHandler

    -- * Call tree manipulations
  , callFn
  , replaceTailFrame
  , isSingleCont
  , unwindContext
  , extractCurrentPath
  ) where

import qualified Control.Exception as Ex
import           Control.Lens
import           Control.Monad.Reader
import           Data.Monoid ((<>))
import qualified Data.Parameterized.Context as Ctx
import           Data.Parameterized.Some
import           Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import           Data.Type.Equality hiding (sym)
import           System.IO
import qualified Text.PrettyPrint.ANSI.Leijen as PP

import           What4.Config
import           What4.Interface
import           What4.ProgramLoc

import           Lang.Crucible.Backend
import           Lang.Crucible.CFG.Core
import           Lang.Crucible.CFG.Extension
import           Lang.Crucible.FunctionHandle
import           Lang.Crucible.Panic(panic)
import           Lang.Crucible.Simulator.CallFrame
import           Lang.Crucible.Simulator.ExecutionTree
import           Lang.Crucible.Simulator.Frame
import           Lang.Crucible.Simulator.GlobalState
import           Lang.Crucible.Simulator.Intrinsics
import           Lang.Crucible.Simulator.RegMap
import           Lang.Crucible.Simulator.SimError

---------------------------------------------------------------------
-- Intermediate state branching/merging

-- | Merge two globals together.
mergeGlobalPair ::
  MuxFn p v ->
  MuxFn p (SymGlobalState sym) ->
  MuxFn p (GlobalPair sym v)
mergeGlobalPair merge_fn global_fn c x y =
  GlobalPair <$> merge_fn  c (x^.gpValue) (y^.gpValue)
             <*> global_fn c (x^.gpGlobals) (y^.gpGlobals)

mergeAbortedResult ::
  Pred sym ->
  AbortedResult sym ext ->
  AbortedResult sym ext ->
  AbortedResult sym ext
mergeAbortedResult _ (AbortedExit ec) _ = AbortedExit ec
mergeAbortedResult _ _ (AbortedExit ec) = AbortedExit ec
mergeAbortedResult c q r = AbortedBranch c q r

mergePartialAndAbortedResult ::
  IsExprBuilder sym =>
  sym ->
  Pred sym {- ^ This needs to hold to avoid the aborted result -} ->
  PartialResult sym ext v ->
  AbortedResult sym ext ->
  IO (PartialResult sym ext v)
mergePartialAndAbortedResult sym c ar r =
  case ar of
    TotalRes gp -> return $! PartialRes c gp r
    PartialRes d gp q ->
      do e <- andPred sym c d
         return $! PartialRes e gp (mergeAbortedResult c q r)


mergeCrucibleFrame ::
  IsSymInterface sym =>
  sym ->
  IntrinsicTypes sym ->
  CrucibleBranchTarget blocks args {- ^ Target of branch -} ->
  MuxFn (Pred sym) (SimFrame sym ext (CrucibleLang blocks ret) args)
mergeCrucibleFrame sym muxFns tgt p x0 y0 =
  case tgt of
    BlockTarget _b_id -> do
      let x = fromCallFrame x0
      let y = fromCallFrame y0
      z <- mergeRegs sym muxFns p (x^.frameRegs) (y^.frameRegs)
      pure $! MF (x & frameRegs .~ z)
    ReturnTarget -> do
      let x = fromReturnFrame x0
      let y = fromReturnFrame y0
      RF <$> muxRegEntry sym muxFns p x y


mergePartialResult ::
  IsSymInterface sym =>
  SimState p sym ext f root args ->
  CrucibleBranchTarget blocks args ->
  MuxFn (Pred sym)
     (PartialResult sym ext (SimFrame sym ext (CrucibleLang blocks ret) args))
mergePartialResult s tgt pp x y =
  let sym       = s^.stateSymInterface
      iteFns    = s^.stateIntrinsicTypes
      merge_val = mergeCrucibleFrame sym iteFns tgt
      merge_fn  = mergeGlobalPair merge_val (globalMuxFn sym iteFns)
  in
  case x of
    TotalRes cx ->
      case y of
        TotalRes cy ->
          TotalRes <$> merge_fn pp cx cy

        PartialRes py cy fy ->
          PartialRes <$> orPred sym pp py
                     <*> merge_fn pp cx cy
                     <*> pure fy

    PartialRes px cx fx ->
      case y of
        TotalRes cy ->
          do pc <- notPred sym pp
             PartialRes <$> orPred sym pc px
                        <*> merge_fn pp cx cy
                        <*> pure fx

        PartialRes py cy fy ->
          PartialRes <$> itePred sym pp px py
                     <*> merge_fn pp cx cy
                     <*> pure (AbortedBranch pp fx fy)

{- | Merge the assumptions collected from the branches of a conditional.
The result is a bunch of qualified assumptions: if the branch condition
is @p@, then the true assumptions become @p => a@, while the false ones
beome @not p => a@.
-}
mergeAssumptions ::
  IsExprBuilder sym =>
  sym ->
  Pred sym ->
  Seq (Assumption sym) ->
  Seq (Assumption sym) ->
  IO (Seq (Assumption sym))
mergeAssumptions sym p thens elses =
  do pnot <- notPred sym p
     th' <- (traverse.labeledPred) (impliesPred sym p) thens
     el' <- (traverse.labeledPred) (impliesPred sym pnot) elses
     let xs = th' <> el'
     -- Filter out all the trivally true assumptions
     return (Seq.filter ((/= Just True) . asConstantPred . view labeledPred) xs)

pushCrucibleFrame ::
  IsSymInterface sym =>
  sym ->
  IntrinsicTypes sym ->
  SimFrame sym ext (CrucibleLang b r) a ->
  IO (SimFrame sym ext (CrucibleLang b r) a)
pushCrucibleFrame sym muxFns (MF x) = do
  r' <- pushBranchRegs sym muxFns (x^.frameRegs)
  return $! MF (x & frameRegs .~ r')
pushCrucibleFrame sym muxFns (RF x) = do
  x' <- pushBranchRegEntry sym muxFns x
  return $! RF x'


pushPausedFrame ::
  IsSymInterface sym =>
  PausedFrame p sym ext root b a args ->
  ReaderT (SimState p sym ext root (CrucibleLang b a) ma) IO (PausedFrame p sym ext root b a args)
pushPausedFrame pf =
  do sym <- view stateSymInterface
     iTypes <- view stateIntrinsicTypes
     lift $ traverseOf (pausedFrame.partialValue)
        (\(GlobalPair v gs) ->
           GlobalPair <$> pushCrucibleFrame sym iTypes v <*>
                          globalPushBranch sym iTypes gs)
        pf



abortCrucibleFrame ::
  IsSymInterface sym =>
  sym ->
  IntrinsicTypes sym ->
  SimFrame sym ext (CrucibleLang b r') a' ->
  IO (SimFrame sym ext (CrucibleLang b r') a')
abortCrucibleFrame sym intrinsicFns (MF x') =
  do r' <- abortBranchRegs sym intrinsicFns (x'^.frameRegs)
     return $! MF (x' & frameRegs .~ r')

abortCrucibleFrame sym intrinsicFns (RF x') =
  RF <$> abortBranchRegEntry sym intrinsicFns x'

abortPartialResult ::
  IsSymInterface sym =>
  SimState p sym ext r f args ->
  PartialResult sym ext (SimFrame sym ext (CrucibleLang b r') a') ->
  IO (PartialResult sym ext (SimFrame sym ext (CrucibleLang b r') a'))
abortPartialResult s pr =
  let sym                    = s^.stateSymInterface
      muxFns                 = s^.stateIntrinsicTypes
      abtGp (GlobalPair v g) = GlobalPair <$> abortCrucibleFrame sym muxFns v
                                          <*> globalAbortBranch sym muxFns g
  in partialValue abtGp pr


------------------------------------------------------------------------
-- resolveCallFrame

-- | The result of resolving a function call.
data ResolvedCall p sym ext ret where
  -- | A resolved function call to an override.
  OverrideCall ::
    !(Override p sym ext args ret) ->
    !(OverrideFrame sym ret args) ->
    ResolvedCall p sym ext ret

  -- | A resolved function call to a Crucible function.
  CrucibleCall ::
    !(CallFrame sym ext blocks ret args) ->
    ResolvedCall p sym ext ret

-- | This exception is thrown if a 'FnHandle' cannot be resolved to
--   a callable function.  This usually indicates a programming error,
--   but might also be used to allow on-demand function loading.
data UnresolvableFunction where
  UnresolvableFunction ::
    !(FnHandle args ret) ->
    UnresolvableFunction

instance Ex.Exception UnresolvableFunction
instance Show UnresolvableFunction where
  show (UnresolvableFunction h) = "Could not resolve function: " ++ show (handleName h)

-- | Given a set of function bindings, a function-
--   value (which is possibly a closure) and a
--   collection of arguments, resolve the identity
--   of the function to call, and set it up to be called.
--
--   Will throw an 'UnresolvableFunction' exception if
--   the underlying function handle is not found in the
--   'FunctionBindings' map.
resolveCall ::
  FunctionBindings p sym ext {- ^ Map from function handles to semantics -} ->
  FnVal sym args ret {- ^ Function handle and any closure variables -} ->
  RegMap sym args {- ^ Arguments to the function -} ->
  ResolvedCall p sym ext ret
resolveCall bindings c0 args =
  case c0 of
    ClosureFnVal c tp v -> do
      resolveCall bindings c (assignReg tp v args)

    HandleFnVal h -> do
      case lookupHandleMap h bindings of
        Nothing -> Ex.throw (UnresolvableFunction h)
        Just (UseOverride o) -> do
          let f = OverrideFrame { override = overrideName o
                                , overrideRegMap = args
                                }
           in OverrideCall o f
        Just (UseCFG g pdInfo) -> do
          CrucibleCall (mkCallFrame g pdInfo args)


---------------------------------------------------------------------
-- Control-flow operations

-- | Immediately transtition to an 'OverrideState'.  On the next
--   execution step, the simulator will execute the given override.
runOverride ::
  Override p sym ext args ret {- ^ Override to execute -} ->
  ExecCont p sym ext rtp (OverrideLang ret) ('Just args)
runOverride o = ReaderT (return . OverrideState o)

-- | Immediately transition to a 'RunningState'.  On the next
--   execution step, the simulator will interpret the next basic
--   block.
continue :: ExecCont p sym ext rtp (CrucibleLang blocks r) ('Just a)
continue = ReaderT (return . RunningState)

-- | Immediately transition to an 'AbortState'.  On the next
--   execution step, the simulator will unwind the 'SimState'
--   and resolve the abort.
runAbortHandler ::
  AbortExecReason {- ^ Description of the abort condition -} ->
  SimState p sym ext rtp f args {- ^ Simulator state prior to the abort -} ->
  IO (ExecState p sym ext rtp)
runAbortHandler rsn s = return (AbortState rsn s)

-- | Abort the current thread of execution with an error.
--   This adds a proof obligation that requires the current
--   execution path to be infeasible, and unwids to the
--   nearest branch point to resume.
runErrorHandler ::
  SimErrorReason {- ^ Description of the error -} ->
  SimState p sym ext rtp f args {- ^ Simulator state prior to the abort -} ->
  IO (ExecState p sym ext rtp)
runErrorHandler msg st =
  let ctx = st^.stateContext
      sym = ctx^.ctxSymInterface
   in ctxSolverProof ctx $
      do loc <- getCurrentProgramLoc sym
         let err = SimError loc msg
         let obl = LabeledPred (falsePred sym) err
         let rsn = AssumedFalse (AssumingNoError err)
         addProofObligation sym obl
         return (AbortState rsn st)

-- | Abort the current thread of execution with an error.
--   This adds a proof obligation that requires the current
--   execution path to be infeasible, and unwids to the
--   nearest branch point to resume.
runGenericErrorHandler ::
  String {- ^ Generic description of the error condition -} ->
  SimState p sym ext rtp f args {- ^ Simulator state prior to the abort -} ->
  IO (ExecState p sym ext rtp)
runGenericErrorHandler msg st = runErrorHandler (GenericSimError msg) st

-- | Transfer control to the given resolved jump, after first
--   checking for any pending symbolic merges at the destination
--   of the jump.
jumpToBlock ::
  IsSymInterface sym =>
  ResolvedJump sym blocks {- ^ Jump target and arguments -} ->
  ExecCont p sym ext rtp (CrucibleLang blocks r) ('Just a)
jumpToBlock (ResolvedJump block_id args) =
  withReaderT
    (stateCrucibleFrame %~ setFrameBlock block_id args)
    (checkForIntraFrameMerge (BlockTarget block_id))
{-# INLINE jumpToBlock #-}


-- | Perform a conditional branch on the given predicate.
--   If the predicate is symbolic, this will record a symbolic
--   branch state.
conditionalBranch ::
  (IsSymInterface sym, IsSyntaxExtension ext) =>
  Pred sym {- ^ Predicate to branch on -} ->
  ResolvedJump sym blocks {- ^ True branch -} ->
  ResolvedJump sym blocks {- ^ False branch -} ->
  ExecCont p sym ext rtp (CrucibleLang blocks ret) ('Just ctx)
conditionalBranch p (ResolvedJump x_id x_args) (ResolvedJump y_id y_args) = do
  top_frame <- view (stateTree.actFrame)
  Some pd <- return (top_frame^.crucibleTopFrame.framePostdom)

  let x_frame = cruciblePausedFrame x_id x_args top_frame pd
  let y_frame = cruciblePausedFrame y_id y_args top_frame pd

  x_loc <- getTgtLoc x_id
  y_loc <- getTgtLoc y_id

  intra_branch p (SomePausedFrame x_frame (Just x_loc))
                 (SomePausedFrame y_frame (Just y_loc))
                 pd

-- | Execute the next branch of a sequence of branch cases.
--   These arise from the implementation of the 'VariantElim'
--   construct.  The predicates are expected to be mutually
--   disjoint.  However, the construct still has well defined
--   semantics even in the case where they overlap; in this case,
--   the first branch with a true 'Pred' is taken.  In other words,
--   each branch assumes the negation of all the predicates of branches
--   appearing before it.
--
--   In the final default case (corresponding to an empty list of branches),
--   a 'VariantOptionsExhausted' abort will be executed.
variantCases ::
  IsSymInterface sym =>
  [(Pred sym, ResolvedJump sym blocks)] {- ^ Variant branches to execute -} ->
  ExecCont p sym ext rtp (CrucibleLang blocks r) ('Just ctx)

variantCases [] =
  do fm <- view stateCrucibleFrame
     let loc = frameProgramLoc fm
     let rsn = VariantOptionsExhaused loc
     abortExec rsn

variantCases ((p,ResolvedJump x_id x_args) : cs) =
  do top_frame <- view (stateTree.actFrame)
     Some pd <- return (top_frame^.crucibleTopFrame.framePostdom)

     let x_frame = cruciblePausedFrame x_id x_args top_frame pd
         y_frame = PausedFrame (TotalRes top_frame) (SwitchResumption cs)

     x_loc <- getTgtLoc x_id
     intra_branch p
                  (SomePausedFrame x_frame (Just x_loc))
                  (SomePausedFrame y_frame Nothing)
                  pd

-- | Return a value from current Crucible execution.
returnAndMerge :: forall p sym ext rtp blocks ret args.
  IsSymInterface sym =>
  RegEntry sym ret {- ^ return value -} ->
  ExecCont p sym ext rtp (CrucibleLang blocks ret) args
returnAndMerge arg =
  withReaderT
    (stateTree.actFrame.gpValue .~ RF arg)
    (checkForIntraFrameMerge ReturnTarget)


-- | Return a value from current override execution.
returnValue ::
  IsSymInterface sym =>
  RegEntry sym ret {- ^ return value -} ->
  ExecCont p sym ext rtp (OverrideLang ret) a
returnValue v =
  do ActiveTree ctx er <- view stateTree
     handleSimReturn
       (returnContext ctx)
       (er & partialValue.gpValue .~ v)


-- | Immediately transition to the 'ControlTransferState'.
--   On the next simulator step, this will checks for the
--   opportunity to merge within a frame.
--
--   This should be called everytime the current control flow location
--   changes to a potential merge point.
checkForIntraFrameMerge ::
  CrucibleBranchTarget b args
    {- ^ The location of the block we are transferring to -} ->
  ExecCont p sym ext root (CrucibleLang b r) args

checkForIntraFrameMerge tgt =
  ReaderT $ return . ControlTransferState tgt


-- | Perform a single instance of path merging at a join point.
--   This will resume an alternate branch, if it is pending,
--   or merge result values if a completed branch has alread reached
--   this point. If there are no pending merge points at this location,
--   continue executing by transfering control to the given target.
performIntraFrameMerge ::
  IsSymInterface sym =>
  CrucibleBranchTarget b args
    {- ^ The location of the block we are transferring to -} ->
  ExecCont p sym ext root (CrucibleLang b r) args

performIntraFrameMerge tgt = do
  ActiveTree ctx0 er <- view stateTree
  sym <- view stateSymInterface
  case ctx0 of
    VFFBranch ctx assume_frame loc p other_branch tgt'

      -- Did we get to our merge point (i.e., we are finished with this branch)
      | Just Refl <- testEquality tgt tgt' ->

        case other_branch of

          -- We still have some more work to do, reactivate the other, postponed branch
          VFFActivePath toTgt next ->
            do pathAssumes      <- liftIO $ popAssumptionFrame sym assume_frame
               new_assume_frame <- liftIO $ pushAssumptionFrame sym
               pnot             <- liftIO $ notPred sym p
               liftIO $ addAssumption sym (LabeledPred pnot (ExploringAPath loc toTgt))

               -- The current branch is done
               let new_other = VFFCompletePath pathAssumes er
               resumeFrame next (VFFBranch ctx new_assume_frame loc pnot new_other tgt)

          -- We are done with both branches, pop-off back to the outer context.
          VFFCompletePath otherAssumes other ->
            do ar <- ReaderT $ \s -> mergePartialResult s tgt p er other

               -- Merge the assumptions from each branch and add to the
               -- current assumption frame
               pathAssumes <- liftIO $ popAssumptionFrame sym assume_frame

               mergedAssumes <- liftIO $ mergeAssumptions sym p pathAssumes otherAssumes
               liftIO $ addAssumptions sym mergedAssumes

               -- Check for more potential merge targets.
               withReaderT
                 (stateTree .~ ActiveTree ctx ar)
                 (checkForIntraFrameMerge tgt)

    -- Since the other branch aborted before it got to the merge point,
    -- we merge-in the partiality on our current path and keep going.
    VFFPartial ctx p ar needsAborting ->
      do er'  <- case needsAborting of
                   NoNeedToAbort    -> return er
                   NeedsToBeAborted -> ReaderT $ \s -> abortPartialResult s er
         er'' <- liftIO $ mergePartialAndAbortedResult sym p er' ar
         withReaderT
           (stateTree .~ ActiveTree ctx er'')
           (checkForIntraFrameMerge tgt)

    -- There are no pending merges to deal with.  Instead, complete
    -- the transfer of control by either transitioning into an ordinary
    -- running state, or by returning a value to the calling context.
    _ -> case tgt of
           BlockTarget _ ->
             continue
           ReturnTarget ->
             handleSimReturn
               (returnContext ctx0)
               (er & over (partialValue.gpValue) fromReturnFrame)

---------------------------------------------------------------------
-- Abort handling

-- | The default abort handler calls `abortExecAndLog`.
defaultAbortHandler :: IsSymInterface sym => AbortHandler p sym ext rtp
defaultAbortHandler = AH abortExecAndLog

-- | Abort the current execution and roll back to the nearest
--   symbolic branch point.  When verbosity is non-0 a message
--   will be logged indicating the reason for the abort.
--
--   The default abort handler calls this function.
abortExecAndLog ::
  IsSymInterface sym =>
  AbortExecReason ->
  ExecCont p sym ext rtp f args
abortExecAndLog rsn = do
  t   <- view stateTree
  cfg <- view stateConfiguration
  ctx <- view stateContext
  v <- liftIO (getOpt =<< getOptionSetting verbosity cfg)
  when (v > 0) $ do
    let frames = activeFrames t
    let msg = ppAbortExecReason rsn PP.<$$>
              PP.indent 2 (ppExceptionContext frames)
    -- Print error message.
    liftIO (hPrint (printHandle ctx) msg)

  -- Switch to new frame.
  abortExec rsn


-- | Abort the current execution and roll back to the nearest
--   symbolic branch point.
abortExec ::
  IsSymInterface sym =>
  AbortExecReason ->
  ExecCont p sym ext rtp f args
abortExec rsn = do
  ActiveTree ctx ar0 <- view stateTree
  -- Get aborted result from active result.
  let ar = case ar0 of
             TotalRes e -> AbortedExec rsn e
             PartialRes c ex ar1 -> AbortedBranch c (AbortedExec rsn ex) ar1
  resumeValueFromFrameAbort ctx ar


------------------------------------------------------------------------
-- Internal operations

-- | Resolve the fact that the current branch aborted.
resumeValueFromFrameAbort ::
  IsSymInterface sym =>
  ValueFromFrame p sym ext r f ->
  AbortedResult sym ext {- ^ The execution that is being aborted. -} ->
  ExecCont p sym ext r g args
resumeValueFromFrameAbort ctx0 ar0 = do
  sym <- view stateSymInterface
  case ctx0 of

    -- This is the first abort.
    VFFBranch ctx assume_frame loc p other_branch tgt ->
      do pnot <- liftIO $ notPred sym p
         let nextCtx = VFFPartial ctx pnot ar0 NeedsToBeAborted

         -- Reset the backend path state
         _assumes <- liftIO $ popAssumptionFrame sym assume_frame

         case other_branch of

           -- We have some more work to do.
           VFFActivePath toLoc n ->
             do liftIO $ addAssumption sym (LabeledPred pnot (ExploringAPath loc toLoc))
                resumeFrame n nextCtx

           -- The other branch had finished successfully;
           -- Since this one aborted, then the other one is really the only
           -- viable option we have, and so we commit to it.
           VFFCompletePath otherAssumes er ->
             do -- We are committed to the other path,
                -- assume all of its suspended assumptions
                liftIO $ addAssumptions sym otherAssumes

                -- check for further merges, then continue onward.
                withReaderT
                  (stateTree .~ ActiveTree nextCtx er)
                  (checkForIntraFrameMerge tgt)

    -- Both branches aborted
    VFFPartial ctx p ay _ ->
      resumeValueFromFrameAbort ctx (AbortedBranch p ar0 ay)

    VFFEnd ctx ->
      resumeValueFromValueAbort ctx ar0

-- | Run rest of execution given a value from value context and an aborted
-- result.
resumeValueFromValueAbort ::
  IsSymInterface sym =>
  ValueFromValue p sym ext r ret' ->
  AbortedResult sym ext ->
  ExecCont p sym ext r f a
resumeValueFromValueAbort ctx0 ar0 =
  case ctx0 of
    VFVCall ctx _ _ -> do
      -- Pop out of call context.
      resumeValueFromFrameAbort ctx ar0
    VFVPartial ctx p ay -> do
      resumeValueFromValueAbort ctx (AbortedBranch p ar0 ay)
    VFVEnd ->
      do res <- view stateContext
         return $! ResultState $ AbortedResult res ar0

-- | Resume a paused frame.
resumeFrame ::
  IsSymInterface sym =>
  PausedFrame p sym ext rtp blocks r a ->
  ValueFromFrame p sym ext rtp (CrucibleLang blocks r) ->
  ExecCont p sym ext rtp g ba
resumeFrame (PausedFrame frm cont) ctx =
    withReaderT
       (stateTree .~ ActiveTree ctx frm)
       (case cont of
         ContinueResumption     -> continue
         SwitchResumption cs    -> variantCases cs
         CheckMergeResumption i -> checkForIntraFrameMerge (BlockTarget i))
{-# INLINABLE resumeFrame #-}


handleSimReturn ::
  IsSymInterface sym =>
  ValueFromValue p sym ext r ret {- ^ Context to return to. -} ->
  PartialResult sym ext ret {- ^ Value that is being returned. -} ->
  ExecCont p sym ext r f a
handleSimReturn ctx0 return_value = do
  case ctx0 of
    VFVCall ctx (MF f) (ReturnToCrucible tpr rest) ->
      do let v  = return_value^.partialValue.gpValue
             f' = extendFrame tpr (regValue v) rest f
         withReaderT
           (stateTree .~ ActiveTree ctx (return_value & partialValue . gpValue .~ MF f'))
           continue

    VFVCall ctx _ TailReturnToCrucible ->
      do let v  = return_value^.partialValue.gpValue
         withReaderT
           (stateTree .~ ActiveTree ctx (return_value & partialValue . gpValue .~ RF v))
           (returnAndMerge v)

    VFVCall ctx (OF f) (ReturnToOverride k) ->
      do let v = return_value^.partialValue.gpValue
         withReaderT
           (stateTree .~ ActiveTree ctx (return_value & partialValue . gpValue .~ OF f))
           (ReaderT (k v))

    VFVPartial ctx p r ->
      do sym <- view stateSymInterface
         new_ret_val <- liftIO (mergePartialAndAbortedResult sym p return_value r)
         handleSimReturn ctx new_ret_val

    VFVEnd ->
      do res <- view stateContext
         return $! ResultState $ FinishedResult res return_value


cruciblePausedFrame ::
  BlockID b new_args ->
  RegMap sym new_args ->
  GlobalPair sym (SimFrame sym ext (CrucibleLang b r) ('Just a)) ->
  CrucibleBranchTarget b pd_args {- ^ postdominator target -} ->
  PausedFrame p sym ext rtp b r new_args
cruciblePausedFrame x_id x_args top_frame pd =
  let cf = top_frame & crucibleTopFrame %~ setFrameBlock x_id x_args
      res = case testEquality pd (BlockTarget x_id) of
                Just Refl -> CheckMergeResumption x_id
                Nothing   -> ContinueResumption
   in PausedFrame (TotalRes cf) res

getTgtLoc ::
  BlockID b y ->
  ReaderT (SimState p sym ext r (CrucibleLang b a) ('Just dc_args)) IO ProgramLoc
getTgtLoc (BlockID i) =
   do blocks <- view (stateCrucibleFrame . to frameBlockMap)
      return $ blockLoc (blocks Ctx.! i)

-- | Return the context of the current top frame.
asContFrame ::
  (f ~ CrucibleLang b a) =>
  ActiveTree     p sym ext ret f args ->
  ValueFromFrame p sym ext ret f
asContFrame (ActiveTree ctx active_res) =
  case active_res of
    TotalRes{} -> ctx
    PartialRes p _ex ar -> VFFPartial ctx p ar NoNeedToAbort


-- | @swap_unless b (x,y)@ returns @(x,y)@ when @b@ is @True@ and
-- @(y,x)@ when @b@ if @False@.
swap_unless :: Bool -> (a, a) -> (a,a)
swap_unless True p = p
swap_unless False (x,y) = (y,x)
{-# INLINE swap_unless #-}

-- | Return assertion where predicate equals a constant
predEqConst :: IsExprBuilder sym => sym -> Pred sym -> Bool -> IO (Pred sym)
predEqConst _   p True  = return p
predEqConst sym p False = notPred sym p

-- | 'Some' frame, together with a location (if any) associated with
--   that frame
data SomePausedFrame p sym ext r b a =
  forall args.
  SomePausedFrame
     !(PausedFrame p sym ext r b a args)
     !(Maybe ProgramLoc)

-- | Branch with a merge point inside this frame.
intra_branch ::
  IsSymInterface sym =>
  Pred sym
  {- ^ Branch condition branch -} ->

  SomePausedFrame p sym ext r b a
  {- ^ true branch. -} ->

  SomePausedFrame p sym ext r b a
  {- ^ false branch. -} ->

  CrucibleBranchTarget b (args :: Maybe (Ctx CrucibleType))
  {- ^ Postdominator merge point, where both branches meet again. -} ->

  ExecCont p sym ext r (CrucibleLang b a) ('Just dc_args)

intra_branch p t_label f_label tgt = do
  ctx <- asContFrame <$> view stateTree
  sym <- view stateSymInterface
  r <- liftIO $ evalBranch sym p
  loc <- liftIO $ getCurrentProgramLoc sym

  case r of
    SymbolicBranch chosen_branch -> do
      -- Get correct predicate
      p' <- liftIO $ predEqConst sym p chosen_branch

      (SomePausedFrame a_frame a_loc, SomePausedFrame o_frame o_loc) <-
                      return (swap_unless chosen_branch (t_label, f_label))

      a_frame' <- pushPausedFrame a_frame
      o_frame' <- pushPausedFrame o_frame

      assume_frame <- liftIO $ pushAssumptionFrame sym
      liftIO $ addAssumption sym (LabeledPred p' (ExploringAPath loc a_loc))

      -- Create context for paused frame.
      let todo = VFFActivePath o_loc o_frame'
          ctx' = VFFBranch ctx assume_frame loc p' todo tgt

      -- Start a_state (where branch pred is p')
      resumeFrame a_frame' ctx'

    NoBranch chosen_branch ->
      do SomePausedFrame a_frame a_loc <-
                      return (if chosen_branch then t_label else f_label)

         liftIO $ addAssumption sym (LabeledPred (truePred sym) (ExploringAPath loc a_loc))

         resumeFrame a_frame ctx

{-# INLINABLE intra_branch #-}


------------------------------------------------------------------------
-- Context tree manipulations

-- | Returns true if tree contains a single non-aborted execution.
isSingleCont :: ValueFromFrame p sym ext root a -> Bool
isSingleCont c0 =
  case c0 of
    VFFBranch{} -> False
    VFFPartial c _ _ _ -> isSingleCont c
    VFFEnd vfv -> isSingleVFV vfv

isSingleVFV :: ValueFromValue p sym ext r a -> Bool
isSingleVFV c0 = do
  case c0 of
    VFVCall c _ _ -> isSingleCont c
    VFVPartial c _ _ -> isSingleVFV c
    VFVEnd -> True

-- | Attempt to unwind a frame context into a value context.
--   This succeeds only if there are no pending symbolic
--   merges.
unwindContext ::
  ValueFromFrame p sym ext root f ->
  Maybe (ValueFromValue p sym ext root (RegEntry sym (FrameRetType f)))
unwindContext c0 =
    case c0 of
      VFFBranch{} -> Nothing
      VFFPartial _ _ _ NeedsToBeAborted -> Nothing
      VFFPartial d p ar NoNeedToAbort ->
        (\d' -> VFVPartial d' p ar) <$> unwindContext d
      VFFEnd vfv -> return vfv

-- | Get the context for when returning (assumes no
-- intra-procedural merges are possible).
returnContext ::
  ValueFromFrame ctx sym ext root f ->
  ValueFromValue ctx sym ext root (RegEntry sym (FrameRetType f))
returnContext c0 =
    case unwindContext c0 of
      Just vfv -> vfv
      Nothing ->
        panic "ExecutionTree.returnContext"
          [ "Unexpected attempt to exit function before all intra-procedural merges are complete."
          , "The call stack was:"
          , show (PP.pretty c0)
          ]

-- | Replace the given frame with a new frame.  Succeeds
--   only if there are no pending symbolic merge points.
replaceTailFrame :: forall p sym ext a b c args args'.
  FrameRetType a ~ FrameRetType c =>
  ActiveTree p sym ext b a args ->
  SimFrame sym ext c args' ->
  Maybe (ActiveTree p sym ext b c args')
replaceTailFrame (ActiveTree c er) f = do
    vfv <- unwindContext c
    return $ ActiveTree (VFFEnd vfv) (er & partialValue . gpValue .~ f)


callFn ::
  ReturnHandler (RegEntry sym (FrameRetType a)) p sym ext r f old_args new_args
    {- ^ What to do with the result of the function -} ->

  SimFrame sym ext a args
    {- ^ The code to run -} ->

  ActiveTree p sym ext r f old_args ->
  ActiveTree p sym ext r a args
callFn rh f' (ActiveTree ctx er) =
    ActiveTree (VFFEnd (VFVCall ctx old_frame rh)) er'
  where
  old_frame = er ^. partialValue ^. gpValue
  er'       = er &  partialValue  . gpValue .~ f'


-- | Create a tree that contains just a single path with no branches.
--
-- All branch conditions are converted to assertions.
extractCurrentPath ::
  ActiveTree p sym ext ret f args ->
  ActiveTree p sym ext ret f args
extractCurrentPath t =
  ActiveTree (vffSingleContext (t^.actContext))
             (TotalRes (t^.actFrame))

vffSingleContext ::
  ValueFromFrame p sym ext ret f ->
  ValueFromFrame p sym ext ret f
vffSingleContext ctx0 =
  case ctx0 of
    VFFBranch ctx _ _ _ _ _ -> vffSingleContext ctx
    VFFPartial ctx _ _ _    -> vffSingleContext ctx
    VFFEnd ctx              -> VFFEnd (vfvSingleContext ctx)

vfvSingleContext ::
  ValueFromValue p sym ext root top_ret ->
  ValueFromValue p sym ext root top_ret
vfvSingleContext ctx0 =
  case ctx0 of
    VFVCall ctx f h         -> VFVCall (vffSingleContext ctx) f h
    VFVPartial ctx _ _      -> vfvSingleContext ctx
    VFVEnd                  -> VFVEnd


------------------------------------------------------------------------
-- branchConditions

-- -- | Return all branch conditions along path to this node.
-- branchConditions :: ActiveTree ctx sym ext ret f args -> [Pred sym]
-- branchConditions t =
--   case t^.actResult of
--     TotalRes _ -> vffBranchConditions (t^.actContext)
--     PartialRes p _ _ -> p : vffBranchConditions (t^.actContext)

-- vffBranchConditions :: ValueFromFrame p sym ext ret f
--                     -> [Pred sym]
-- vffBranchConditions ctx0 =
--   case ctx0 of
--     VFFBranch   ctx _ _ p _ _  -> p : vffBranchConditions ctx
--     VFFPartial  ctx p _ _      -> p : vffBranchConditions ctx
--     VFFEnd  ctx -> vfvBranchConditions ctx

-- vfvBranchConditions :: ValueFromValue p sym ext root top_ret
--                     -> [Pred sym]
-- vfvBranchConditions ctx0 =
--   case ctx0 of
--     VFVCall     ctx _ _      -> vffBranchConditions ctx
--     VFVPartial  ctx p _      -> p : vfvBranchConditions ctx
--     VFVEnd                   -> []
