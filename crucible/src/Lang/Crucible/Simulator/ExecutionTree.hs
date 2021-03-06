-----------------------------------------------------------------------
-- |
-- Module           : Lang.Crucible.Simulator.ExecutionTree
-- Description      : Data structure the execution state of the simulator
-- Copyright        : (c) Galois, Inc 2014-2018
-- License          : BSD3
-- Maintainer       : Joe Hendrix <jhendrix@galois.com>
-- Stability        : provisional
--
-- Execution trees record the state of the simulator as it explores
-- execution paths through a program.  This module defines the
-- collection of datatypes that record the state of a running simulator
-- and basic lenses and accessors for these types. See
-- "Lang.Crucible.Simulator.Operations" for the definitions of operations
-- that manipulate these datastructures to drive them through the simulator
-- state machine.
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
module Lang.Crucible.Simulator.ExecutionTree
  ( -- * GlobalPair
    GlobalPair(..)
  , gpValue
  , gpGlobals

    -- * TopFrame
  , TopFrame
  , crucibleTopFrame

    -- * CrucibleBranchTarget
  , CrucibleBranchTarget(..)
  , ppBranchTarget

    -- * AbortedResult
  , AbortedResult(..)
  , SomeFrame(..)
  , filterCrucibleFrames
  , arFrames
  , ppExceptionContext

    -- * Partial result
  , PartialResult(..)
  , partialValue

    -- * Execution states
  , ExecResult(..)
  , ExecState(..)
  , ExecCont

    -- * Simulator context trees
    -- ** Main context data structures
  , ValueFromValue(..)
  , ValueFromFrame(..)
  , PendingPartialMerges(..)

    -- ** Paused Frames
  , ResolvedJump(..)
  , ControlResumption(..)
  , PausedFrame(..)
  , pausedFrame
  , resume

    -- ** Sibling paths
  , VFFOtherPath(..)
  , FrameRetType

    -- ** ReturnHandler
  , ReturnHandler(..)

    -- * ActiveTree
  , ActiveTree(..)
  , singletonTree
  , activeFrames
  , actContext
  , actFrame

    -- * Simulator context
    -- ** Function bindings
  , Override(..)
  , FnState(..)
  , FunctionBindings

    -- ** Extensions
  , ExtensionImpl(..)
  , EvalStmtFunc

    -- ** SimContext record
  , IsSymInterfaceProof
  , SimContext(..)
  , initSimContext
  , ctxSymInterface
  , functionBindings
  , cruciblePersonality

    -- * SimState
  , SimState(..)
  , initSimState

  , AbortHandler(..)
  , CrucibleState

    -- ** Lenses and accessors
  , stateTree
  , abortHandler
  , stateContext
  , stateCrucibleFrame
  , stateSymInterface
  , stateSolverProof
  , stateIntrinsicTypes
  , stateOverrideFrame
  , stateConfiguration
  ) where

import           Control.Lens
import           Control.Monad.Reader
import           Control.Monad.ST (RealWorld)
import           Data.Parameterized.Ctx
import qualified Data.Parameterized.Context as Ctx
import           Data.Sequence (Seq)
import           System.Exit (ExitCode)
import           System.IO
import qualified Text.PrettyPrint.ANSI.Leijen as PP

import           What4.Config (Config)
import           What4.Interface (Pred, getConfiguration)
import           What4.FunctionName (FunctionName, startFunctionName)
import           What4.ProgramLoc (ProgramLoc, plSourceLoc)

import           Lang.Crucible.Backend (IsSymInterface, AbortExecReason, FrameIdentifier, Assumption)
import           Lang.Crucible.CFG.Core (BlockID, CFG, CFGPostdom, StmtSeq)
import           Lang.Crucible.CFG.Extension (StmtExtension, ExprExtension)
import           Lang.Crucible.FunctionHandle (FnHandleMap, HandleAllocator)
import           Lang.Crucible.Simulator.CallFrame
import           Lang.Crucible.Simulator.Evaluation (EvalAppFunc)
import           Lang.Crucible.Simulator.Frame
import           Lang.Crucible.Simulator.GlobalState (SymGlobalState)
import           Lang.Crucible.Simulator.Intrinsics (IntrinsicTypes)
import           Lang.Crucible.Simulator.RegMap (RegMap, emptyRegMap, RegValue, RegEntry)
import           Lang.Crucible.Types

------------------------------------------------------------------------
-- GlobalPair

-- | A value of some type 'v' together with a global state.
data GlobalPair sym (v :: *) =
   GlobalPair
   { _gpValue :: !v
   , _gpGlobals :: !(SymGlobalState sym)
   }

-- | Access the value stored in the global pair.
gpValue :: Lens (GlobalPair sym u) (GlobalPair sym v) u v
gpValue = lens _gpValue (\s v -> s { _gpValue = v })

-- | Access the globals stored in the global pair.
gpGlobals :: Simple Lens (GlobalPair sym u) (SymGlobalState sym)
gpGlobals = lens _gpGlobals (\s v -> s { _gpGlobals = v })


------------------------------------------------------------------------
-- TopFrame

-- | The currently-exeucting frame plus the global state associated with it.
type TopFrame sym ext f a = GlobalPair sym (SimFrame sym ext f a)

-- | Access the Crucible call frame inside a 'TopFrame'.
crucibleTopFrame ::
  Lens (TopFrame sym ext (CrucibleLang blocks r) ('Just args))
       (TopFrame sym ext (CrucibleLang blocks r) ('Just args'))
       (CallFrame sym ext blocks r args)
       (CallFrame sym ext blocks r args')
crucibleTopFrame = gpValue . crucibleSimFrame
{-# INLINE crucibleTopFrame #-}



------------------------------------------------------------------------
-- AbortedResult

-- | An execution path that was prematurely aborted.  Note, an abort
--   does not necessarily inidicate an error condition.  An execution
--   path might abort because it became infeasible (inconsistent path
--   conditions), because the program called an exit primitive, or
--   because of a true error condition (e.g., a failed assertion).
data AbortedResult sym ext where
  -- | A single aborted execution with the execution state at time of the abort and the reason.
  AbortedExec ::
    !AbortExecReason ->
    !(GlobalPair sym (SimFrame sym ext l args)) ->
    AbortedResult sym ext

  -- | An aborted execution that was ended by a call to 'exit'.
  AbortedExit ::
    !ExitCode ->
    AbortedResult sym ext

  -- | Two separate threads of execution aborted after a symbolic branch,
  --   possibly for different reasons.
  AbortedBranch ::
    !(Pred sym)              {- The symbolic condition -} ->
    !(AbortedResult sym ext) {- The abort that occurred along the 'true' branch -} ->
    !(AbortedResult sym ext) {- The abort that occurred along the 'false' branch -} ->
    AbortedResult sym ext

------------------------------------------------------------------------
-- SomeFrame

-- | This represents an execution frame where its frame type
--   and arguments have been hidden.
data SomeFrame (f :: fk -> argk -> *) = forall l a . SomeFrame !(f l a)

-- | Return the program locations of all the Crucible frames.
filterCrucibleFrames :: SomeFrame (SimFrame sym ext) -> Maybe ProgramLoc
filterCrucibleFrames (SomeFrame (MF f)) = Just (frameProgramLoc f)
filterCrucibleFrames _ = Nothing

-- | Iterate over frames in the result.
arFrames :: Simple Traversal (AbortedResult sym ext) (SomeFrame (SimFrame sym ext))
arFrames h (AbortedExec e p) =
  (\(SomeFrame f') -> AbortedExec e (p & gpValue .~ f'))
     <$> h (SomeFrame (p^.gpValue))
arFrames _ (AbortedExit ec) = pure (AbortedExit ec)
arFrames h (AbortedBranch p r s) =
  AbortedBranch p <$> arFrames h r
                  <*> arFrames h s

-- | Print an exception context
ppExceptionContext :: [SomeFrame (SimFrame sym ext)] -> PP.Doc
ppExceptionContext [] = PP.empty
ppExceptionContext frames = PP.vcat (map pp (init frames))
 where
   pp :: SomeFrame (SimFrame sym ext) -> PP.Doc
   pp (SomeFrame (OF f)) =
      PP.text ("When calling " ++ show (override f))
   pp (SomeFrame (MF f)) =
      PP.text "In" PP.<+> PP.text (show (frameHandle f)) PP.<+>
      PP.text "at" PP.<+> PP.pretty (plSourceLoc (frameProgramLoc f))
   pp (SomeFrame (RF _v)) =
      PP.text ("While returning value")


------------------------------------------------------------------------
-- PartialResult

-- | A 'PartialResult' represents the result of a computation that
--   might be only partially defined.  If the result is a 'TotalResult',
--   the the result is fully defined; however if it is a
--   'PartialResult', then some of the computation paths that led to
--   this result aborted for some reason, and the resulting value is
--   only defined if the associated condition is true.
data PartialResult sym ext (v :: *)

     {- | A 'TotalRes' indicates that the the global pair is always defined. -}
   = TotalRes !(GlobalPair sym v)

    {- | 'PartialRes' indicates that the global pair may be undefined
        under some circusmstances.  The predicate specifies under what
        conditions the 'GlobalPair' is defined.
        The 'AbortedResult' describes the circumstances under which
        the result would be partial.
     -}
   | PartialRes !(Pred sym)               -- if true, global pair is defined
                !(GlobalPair sym v)       -- the value
                !(AbortedResult sym ext)  -- failure cases (when pred. is false)



-- | Access the value stored in the partial result.
partialValue ::
  Lens (PartialResult sym ext u)
       (PartialResult sym ext v)
       (GlobalPair sym u)
       (GlobalPair sym v)
partialValue f (TotalRes x) = TotalRes <$> f x
partialValue f (PartialRes p x r) = (\y -> PartialRes p y r) <$> f x
{-# INLINE partialValue #-}


------------------------------------------------------------------------
-- ExecResult

-- | Executions that have completed either due to (partial or total)
--   successful completion or by some abort condition.
data ExecResult p sym ext (r :: *)
   = -- | At least one exeuction path resulted in some return result.
     FinishedResult !(SimContext p sym ext) !(PartialResult sym ext r)
     -- | All execution paths resulted in an abort condition, and there is
     --   no result to return.
   | AbortedResult  !(SimContext p sym ext) !(AbortedResult sym ext)

-----------------------------------------------------------------------
-- ExecState

-- | An 'ExecState' represents an intermediate state of executing a
--   Crucible program.  The Crucible simulator executes by transistioning
--   between these different states until it results in a 'ResultState',
--   indicating the program has completed.
data ExecState p sym ext (rtp :: *)
   {- | The 'ResultState' is used to indicate that the program has completed. -}
   = ResultState
       !(ExecResult p sym ext rtp)

   {- | An abort state indicates that the included 'SimState' encountered
        an abort event while executing its next step.  The state needs to
        be unwound to its nearest enclosing branch point and resumed. -}
   | forall f a.
       AbortState
         !AbortExecReason
           {- Description of what abort condition occurred -}
         !(SimState p sym ext rtp f a)
           {- State of the simulator prior to causing the abort condition -}

   {- | A running state indicates the included 'SimState' is ready to enter
        and execute a Crucible basic block, or to resume a basic block
        from a call site. -}
   |  forall blocks r args.
       RunningState
         !(SimState p sym ext rtp (CrucibleLang blocks r) ('Just args))

   {- | An override state indicates the included 'SimState' is prepared to
        execute a code override. -}
   | forall args ret.
       OverrideState
         !(Override p sym ext args ret)
           {- The override code to execute -}
         !(SimState p sym ext rtp (OverrideLang ret) ('Just args))
           {- State of the simulator prior to activating the override -}

   {- | A control transfer state occurs when the included 'SimState' is
        in the process of transfering control to the included 'CrucibleBranchTarget'.
        During this process, paths may have to be merged.  If several branches
        must merge at the same control point, this state may be entered several
        times in succession before returning to a 'RunningState'. -}
   | forall blocks r args.
       ControlTransferState
         !(CrucibleBranchTarget blocks args)
           {- Target of the control-flow transfer -}
         !(SimState p sym ext rtp (CrucibleLang blocks r) args)
           {- State of the simulator prior to the control-flow transfer -}

-- | An action which will construct an 'ExecState' given a current
--   'SimState'. Such continuations correspond to a single transition
--   of the simulator transition system.
type ExecCont p sym ext r f a =
  ReaderT (SimState p sym ext r f a) IO (ExecState p sym ext r)

-- | A 'ResolvedJump' is a block label together with a collection of
--   actual arguments that are expected by that block.  These data
--   are sufficent to actually transfer control to the named label.
data ResolvedJump sym blocks
  = forall args.
      ResolvedJump
        !(BlockID blocks args)
        !(RegMap sym args)

-- | When a path of execution is paused by the symbolic simulator
--   (while it first explores other paths), a 'ControlResumption'
--   indicates what actions must later be taken in order to resume
--   execution of that path.
data ControlResumption p sym ext rtp blocks r args where
  {- | When resuming a paused frame with a 'ContinueResumption',
       no special work needs to be done, simply begin executing
       statements of the basic block. -}
  ContinueResumption ::
    ControlResumption p sym ext rtp blocks r args

  {- | When resuming with a 'CheckMergeResumption', we must check
       for the presence of pending merge points before resuming. -}
  CheckMergeResumption ::
    BlockID blocks args {- Block ID we are transferring to -} ->
    ControlResumption p sym ext root blocks r args

  {- | When resuming a paused frame with a 'SwitchResumption', we must
       continue branching to possible alternatives in a variant elmination
       statement.  In other words, we are still in the process of
       transfering control away from the current basic block (which is now
       at a final 'VariantElim' terminal statement). -}
  SwitchResumption ::
    [(Pred sym, ResolvedJump sym blocks)] {- remaining branches -} ->
    ControlResumption p sym ext root blocks r args

------------------------------------------------------------------------
-- Paused Frame

-- | A 'PausedFrame' represents a path of execution that has been postponed
--   while other paths are explored.  It consists of a (potentially partial)
--   'SimFrame' togeter with some information about how to resume execution
--   of that frame.
data PausedFrame p sym ext root b r args
   = PausedFrame
     { _pausedFrame  :: !(PartialResult sym ext (SimFrame sym ext (CrucibleLang b r) ('Just args)))
     , _resume       :: !(ControlResumption p sym ext root b r args)
     }

-- | Access the partial frame inside a 'PausedFrame'
pausedFrame ::
  Simple Lens
    (PausedFrame p sym ext root b r args)
    (PartialResult sym ext (SimFrame sym ext (CrucibleLang b r) ('Just args)))
pausedFrame = lens _pausedFrame (\ppf v -> ppf{ _pausedFrame = v })

-- | Access the 'ControlResumption' inside a 'PausedFrame'
resume ::
  Simple Lens
    (PausedFrame p sym ext root b r args)
    (ControlResumption p sym ext root b r args)
resume = lens _resume (\ppf r -> ppf{ _resume = r })


-- | This describes the state of the sibling path at a symbolic branch point.
--   A symbolic branch point starts with the sibling in the 'VFFActivePath'
--   state, which indicates that the sibling path still needs to be executed.
--   After the first path to be explored has reached the merge point, the
--   places of the two paths are exchanged, and the completed path is
--   stored in the 'VFFCompletePath' state until the second path also
--   reaches its merge point.  The two paths will then be merged,
--   and execution will continue beyond the merge point.
data VFFOtherPath p sym ext ret blocks r args

     {- | This corresponds the a path that still needs to be analyzed. -}
   = forall o_args.
      VFFActivePath
        !(Maybe ProgramLoc)
          {- Location of branch target -}
        !(PausedFrame p sym ext ret blocks r o_args)
          {- Other branch we still need to run -}

     {- | This is a completed execution path. -}
   | VFFCompletePath
        !(Seq (Assumption sym))
          {- Assumptions that we collected while analyzing the branch -}
        !(PartialResult sym ext (SimFrame sym ext (CrucibleLang blocks r) args))
          {- Result of running the other branch -}


type family FrameRetType (f :: *) :: CrucibleType where
  FrameRetType (CrucibleLang b r) = r
  FrameRetType (OverrideLang r) = r


{- | This type contains information about the current state of the exploration
of the branching structure of a program.  The 'ValueFromFrame' states correspond
to the structure of symbolic branching that occurs within a single function call.

The type parameters have the following meanings:

  * @p@ is the personality of the simulator (i.e., custom user state).

  * @sym@ is the simulator backend being used.

  * @ext@ specifies what extensions to the Crusible language are enabled

  * @ret@ is the global return type of the entire execution.

  * @f@ is the type of the top frame.
-}

data ValueFromFrame p sym ext (ret :: *) (f :: *)

  {- | We are working on a branch;  this could be the first or the second
       of both branches (see the 'VFFOtherPath' field). -}
  = forall blocks args r. (f ~ CrucibleLang blocks r) =>
    VFFBranch

      !(ValueFromFrame p sym ext ret f)
      {- The outer context---what to do once we are done with both branches -}

      !FrameIdentifier
      {- This is the frame identifier in the solver before this branch,
         so that when we are done we can pop-off the assumptions we accumulated
         while processing the branch -}

      !ProgramLoc
      {- Program location of the branch point -}

      !(Pred sym)
      {- Assertion of currently-active branch -}

      !(VFFOtherPath p sym ext ret blocks r args)
      {- Info about the state of the other branch.
         If the other branch is "VFFActivePath", then we still
         need to process it;  if it is "VFFCompletePath", then
         it is finsihed, and so once we are done then we go back to the
         outer context. -}

      !(CrucibleBranchTarget blocks args)
      {- Identifies the postdominator where the two branches merge back together -}



  {- | We are on a branch where the other branch was aborted before getting
     to the merge point.  -}
  | forall blocks a.  (f ~ CrucibleLang blocks a) =>
    VFFPartial

      !(ValueFromFrame p sym ext ret f)
      {- The other context--what to do once we are done with this bracnh -}

      !(Pred sym)
      {- Assertion of current branch -}

      !(AbortedResult sym ext)
      {- What happened on the other branch -}

      !PendingPartialMerges
      {- should we abort the (outer) sibling branch when it merges with us? -}


  {- | When we are finished with this branch we should return from the function. -}
  | VFFEnd

      !(ValueFromValue p sym ext ret (RegEntry sym (FrameRetType f)))


-- | Data about wether the surrounding context is expecting a merge to
--   occur or not.  If the context sill expects a merge, we need to
--   take some actions to indicate that the merge will not occur;
--   otherwise there is no special work to be done.
data PendingPartialMerges =
    {- | Don't indicate an abort condition in the context -}
    NoNeedToAbort

    {- | Indicate an abort condition in the context when we
         get there again. -}
  | NeedsToBeAborted


{- | This type contains information about the current state of the exploration
of the branching structure of a program.  The 'ValueFromValue' states correspond
to stack call frames in a more traditional simulator environment.

The type parameters have the following meanings:

  * @p@ is the personality of the simulator (i.e., custom user state).

  * @sym@ is the simulator backend being used.

  * @ext@ specifies what extensions to the Crusible language are enabled

  * @ret@ is the global return type of the entire computation

  * @top_return@ is the return type of the top-most call on the stack.
-}
data ValueFromValue p sym ext (ret :: *) (top_return :: *)

  {- | 'VFVCall' denotes a call site in the outer context, and represents
       the point to which a function higher on the stack will eventually return. -}
  = forall args caller new_args.
    VFVCall

    !(ValueFromFrame p sym ext ret caller)
    -- The context in which the call happened.

    !(SimFrame sym ext caller args)
    -- The frame of the caller.

    !(ReturnHandler top_return p sym ext ret caller args new_args)
    -- How to modify the current sim frame and resume execution
    -- when we obtain the return value

  {- | A partial value.
    The predicate indicates what needs to hold to avoid the partiality.
    The "AbortedResult" describes what could go wrong if the predicate
    does not hold. -}
  | VFVPartial
      !(ValueFromValue p sym ext ret top_return)
      !(Pred sym)
      !(AbortedResult sym ext)

  {- | The top return value, indicating the program termination point. -}
  | (ret ~ top_return) => VFVEnd



instance PP.Pretty (ValueFromValue p ext sym root rp) where
  pretty = ppValueFromValue

instance PP.Pretty (ValueFromFrame p ext sym ret f) where
  pretty = ppValueFromFrame

instance PP.Pretty (VFFOtherPath ctx sym ext r blocks r' a) where
  pretty (VFFActivePath _ _)   = PP.text "active_path"
  pretty (VFFCompletePath _ _) = PP.text "complete_path"

ppValueFromFrame :: ValueFromFrame p sym ext ret f -> PP.Doc
ppValueFromFrame vff =
  case vff of
    VFFBranch ctx _ _ _ other mp ->
      PP.text "intra_branch" PP.<$$>
      PP.indent 2 (PP.pretty other) PP.<$$>
      PP.indent 2 (PP.text (ppBranchTarget mp)) PP.<$$>
      PP.pretty ctx
    VFFPartial ctx _ _ _ ->
      PP.text "intra_partial" PP.<$$>
      PP.pretty ctx
    VFFEnd ctx ->
      PP.pretty ctx

ppValueFromValue :: ValueFromValue p sym ext root tp -> PP.Doc
ppValueFromValue vfv =
  case vfv of
    VFVCall ctx _ _ ->
      PP.text "call" PP.<$$>
      PP.pretty ctx
    VFVPartial ctx _ _ ->
      PP.text "inter_partial" PP.<$$>
      PP.pretty ctx
    VFVEnd -> PP.text "root"


-----------------------------------------------------------------------
-- parentFrames

-- | Return parents frames in reverse order.
parentFrames :: ValueFromFrame p sym ext r a -> [SomeFrame (SimFrame sym ext)]
parentFrames c0 =
  case c0 of
    VFFBranch c _ _ _ _ _ -> parentFrames c
    VFFPartial c _ _ _ -> parentFrames c
    VFFEnd vfv -> vfvParents vfv

-- | Return parents frames in reverse order.
vfvParents :: ValueFromValue p sym ext r a -> [SomeFrame (SimFrame sym ext)]
vfvParents c0 =
  case c0 of
    VFVCall c f _ -> SomeFrame f : parentFrames c
    VFVPartial c _ _ -> vfvParents c
    VFVEnd -> []

------------------------------------------------------------------------
-- ReturnHandler

{- | A 'ReturnHandler' indicates what actions to take to resume
executing in a caller's context once a function call has completed and
the return value is avaliable.

The type parameters have the following meanings:

  * @top_return@ is the type of the return value that is expected.

  * @p@ is the personality of the simulator (i.e., custom user state).

  * @sym@ is the simulator backend being used.

  * @ext@ specifies what extensions to the Crucible language are enabled

  * @roor@ is the global return type of the entire computation

  * @f@ is the stack type of the caller

  * @args@ is the type of the local variables in scope prior to the call

  * @new_args@ is the type of the local variables in scope after the call completes
-}
data ReturnHandler top_return p sym ext root f args new_args where
  {- | The 'ReturnToOverride' constructor indicates that the calling
       context is primitive code written directly in Haskell.
   -}
  ReturnToOverride ::
    (top_return -> SimState p sym ext root (OverrideLang r) ('Just args) -> IO (ExecState p sym ext root))
      {- Remaining override code to run when the return value becomse available -} ->
    ReturnHandler top_return p sym ext root (OverrideLang r) ('Just args) ('Just args)

  {- | The 'ReturnToCrucible' constructor indicates that the calling context is an
       ordinary function call position from within a Crucible basic block.
       The included 'StmtSeq' is the remaining statements in the basic block to be
       executed following the return.
  -}
  ReturnToCrucible ::
    TypeRepr ret                       {- Type of the return value -} ->
    StmtSeq ext blocks r (ctx ::> ret) {- Remaining statements to execute -} ->
    ReturnHandler (RegEntry sym ret)
      p sym ext root (CrucibleLang blocks r) ('Just ctx) ('Just (ctx ::> ret))

  {- | The 'TailReturnToCrucible' constructor indicates that the calling context is a
       tail call position from the end of a Crucible basic block.  Upon receiving
       the return value, that value should be immediately returned in the caller's
       context as well.
  -}
  TailReturnToCrucible ::
    ReturnHandler (RegEntry sym r)
      p sym ext root (CrucibleLang blocks r) ctx 'Nothing


------------------------------------------------------------------------
-- ActiveTree

{- | An active execution tree contains at least one active execution.
     The data structure is organized so that the current execution
     can be accessed rapidly. -}
data ActiveTree p sym ext root (f :: *) args
   = ActiveTree
      { _actContext :: !(ValueFromFrame p sym ext root f)
      , _actResult  :: !(PartialResult sym ext (SimFrame sym ext f args))
      }

-- | Create a tree with a single top frame.
singletonTree ::
  TopFrame sym ext f args ->
  ActiveTree p sym ext (RegEntry sym (FrameRetType f)) f args
singletonTree f = ActiveTree { _actContext = VFFEnd VFVEnd
                             , _actResult = TotalRes f
                             }

-- | Access the calling context of the currently-active frame
actContext ::
  Lens (ActiveTree p sym ext root f args)
       (ActiveTree p sym ext root f args)
       (ValueFromFrame p sym ext root f)
       (ValueFromFrame p sym ext root f)
actContext = lens _actContext (\s v -> s { _actContext = v })

actResult ::
  Lens (ActiveTree p sym ext root f args0)
       (ActiveTree p sym ext root f args1)
       (PartialResult sym ext (SimFrame sym ext f args0))
       (PartialResult sym ext (SimFrame sym ext f args1))
actResult = lens _actResult setter
  where setter s v = ActiveTree { _actContext = _actContext s
                                , _actResult = v
                                }
{-# INLINE actResult #-}

-- | Access the currently-active frame
actFrame ::
  Lens (ActiveTree p sym ext root f args)
       (ActiveTree p sym ext root f args')
       (TopFrame sym ext f args)
       (TopFrame sym ext f args')
actFrame = actResult . partialValue
{-# INLINE actFrame #-}

-- | Return the call stack of all active frames, in
--   reverse activation order (i.e., with callees
--   appearing before callers).
activeFrames :: ActiveTree ctx sym ext root a args ->
                [SomeFrame (SimFrame sym ext)]
activeFrames (ActiveTree ctx ar) =
  SomeFrame (ar^.partialValue^.gpValue) : parentFrames ctx


------------------------------------------------------------------------
-- SimContext

-- | A definition of a function's semantics, given as a Haskell action.
data Override p sym ext (args :: Ctx CrucibleType) ret
   = Override { overrideName    :: FunctionName
              , overrideHandler :: forall r. ExecCont p sym ext r (OverrideLang ret) ('Just args)
              }

-- | State used to indicate what to do when function is called.  A function
--   may either be defined by writing a Haskell 'Override' or by giving
--   a Crucible control-flow graph representation.
data FnState p sym ext (args :: Ctx CrucibleType) (ret :: CrucibleType)
   = UseOverride !(Override p sym ext args ret)
   | forall blocks . UseCFG !(CFG ext blocks args ret) !(CFGPostdom blocks)

-- | A map from function handles to their semantics.
type FunctionBindings p sym ext = FnHandleMap (FnState p sym ext)

-- | The type of functions that interpret extension statements.  These
--   have access to the main simulator state, and can make fairly arbitrary
--   changes to it.
type EvalStmtFunc p sym ext =
  forall rtp blocks r ctx tp'.
    StmtExtension ext (RegEntry sym) tp' ->
    CrucibleState p sym ext rtp blocks r ctx ->
    IO (RegValue sym tp', CrucibleState p sym ext rtp blocks r ctx)

-- | In order to start executing a simulator, one must provide an implementation
--   of the extension syntax.  This includes an evaluator for the added
--   expression forms, and an evaluator for the added statement forms.
data ExtensionImpl p sym ext
  = ExtensionImpl
    { extensionEval ::
        IsSymInterface sym =>
        sym ->
        IntrinsicTypes sym ->
        (Int -> String -> IO ()) ->
        EvalAppFunc sym (ExprExtension ext)

    , extensionExec :: EvalStmtFunc p sym ext
    }

type IsSymInterfaceProof sym a = (IsSymInterface sym => a) -> a

-- | Top-level state record for the simulator.  The state contained in this record
--   remains persistent across all symbolic simulator actions.  In particular, it
--   is not rolled back when the simulator returns previous program points to
--   explore additional paths, etc.
data SimContext (personality :: *) (sym :: *) (ext :: *)
   = SimContext { _ctxSymInterface       :: !sym
                  -- | Class dictionary for @'IsSymInterface' sym@
                , ctxSolverProof         :: !(forall a . IsSymInterfaceProof sym a)
                , ctxIntrinsicTypes      :: !(IntrinsicTypes sym)
                  -- | Allocator for function handles
                , simHandleAllocator     :: !(HandleAllocator RealWorld)
                  -- | Handle to write messages to.
                , printHandle            :: !Handle
                , extensionImpl          :: ExtensionImpl personality sym ext
                , _functionBindings      :: !(FunctionBindings personality sym ext)
                , _cruciblePersonality   :: !personality
                }

-- | Create a new 'SimContext' with the given bindings.
initSimContext ::
  IsSymInterface sym =>
  sym {- ^ Symbolic backend -} ->
  IntrinsicTypes sym {- ^ Implementations of intrinsic types -} ->
  HandleAllocator RealWorld {- ^ Handle allocator for creating new function handles -} ->
  Handle {- ^ Handle to write output to -} ->
  FunctionBindings personality sym ext {- ^ Initial bindings for function handles -} ->
  ExtensionImpl personality sym ext {- ^ Semantics for extension syntax -} ->
  personality {- ^ Initial value for custom user state -} ->
  SimContext personality sym ext
initSimContext sym muxFns halloc h bindings extImpl personality =
  SimContext { _ctxSymInterface     = sym
             , ctxSolverProof       = \a -> a
             , ctxIntrinsicTypes    = muxFns
             , simHandleAllocator   = halloc
             , printHandle          = h
             , extensionImpl        = extImpl
             , _functionBindings    = bindings
             , _cruciblePersonality = personality
             }

-- | Access the symbolic backend inside a 'SimContext'.
ctxSymInterface :: Simple Lens (SimContext p sym ext) sym
ctxSymInterface = lens _ctxSymInterface (\s v -> s { _ctxSymInterface = v })

-- | A map from function handles to their semantics.
functionBindings :: Simple Lens (SimContext p sym ext) (FunctionBindings p sym ext)
functionBindings = lens _functionBindings (\s v -> s { _functionBindings = v })

-- | Access the custom user-state inside the 'SimContext'.
cruciblePersonality :: Simple Lens (SimContext p sym ext) p
cruciblePersonality = lens _cruciblePersonality (\s v -> s{ _cruciblePersonality = v })

------------------------------------------------------------------------
-- SimState


-- | An abort handler indicates to the simulator what actions to take
--   when an abort occurs.  Usually, one should simply use the
--   'defaultAbortHandler' from "Lang.Crucible.Simulator", which
--   unwinds the tree context to the nearest branch point and
--   correctly resumes simulation.  However, for some use cases, it
--   may be desirable to take additional or alternate actions on abort
--   events; in which case, the libary user may replace the default
--   abort handler with their own.
newtype AbortHandler p sym ext rtp
      = AH { runAH :: forall (l :: *) args.
                 AbortExecReason ->
                 ExecCont p sym ext rtp l args
           }

-- | A SimState contains the execution context, an error handler, and
--   the current execution tree.  It captures the entire state
--   of the symbolic simulator.
data SimState p sym ext rtp f (args :: Maybe (Ctx.Ctx CrucibleType))
   = SimState { _stateContext      :: !(SimContext p sym ext)
              , _abortHandler      :: !(AbortHandler p sym ext rtp)
              , _stateTree         :: !(ActiveTree p sym ext rtp f args)
              }

-- | A simulator state that is currently executing Crucible instructions.
type CrucibleState p sym ext rtp blocks ret args
   = SimState p sym ext rtp (CrucibleLang blocks ret) ('Just args)

-- | Create an initial 'SimState'
initSimState ::
  SimContext p sym ext {- ^ initial 'SimContext' state -} ->
  SymGlobalState sym  {- ^ state of Crucible global variables -} ->
  AbortHandler p sym ext (RegEntry sym ret) {- ^ initial abort handler -} ->
  SimState p sym ext (RegEntry sym ret) (OverrideLang ret) ('Just EmptyCtx)
initSimState ctx globals ah =
  let startFrame = OverrideFrame { override = startFunctionName
                                 , overrideRegMap = emptyRegMap
                                 }
      startGP = GlobalPair (OF startFrame) globals
   in SimState
      { _stateContext = ctx
      , _abortHandler = ah
      , _stateTree    = singletonTree startGP
      }

-- | Access the 'SimContext' inside a 'SimState'
stateContext :: Simple Lens (SimState p sym ext r f a) (SimContext p sym ext)
stateContext = lens _stateContext (\s v -> s { _stateContext = v })
{-# INLINE stateContext #-}

-- | Access the current abort handler of a state.
abortHandler :: Simple Lens (SimState p sym ext r f a) (AbortHandler p sym ext r)
abortHandler = lens _abortHandler (\s v -> s { _abortHandler = v })

-- | Access the active tree associated with a state.
stateTree ::
  Lens (SimState p sym ext rtp f a)
       (SimState p sym ext rtp g b)
       (ActiveTree p sym ext rtp f a)
       (ActiveTree p sym ext rtp g b)
stateTree = lens _stateTree (\s v -> s { _stateTree = v })
{-# INLINE stateTree #-}

-- | Access the Crucible call frame inside a 'SimState'
stateCrucibleFrame ::
  Lens (SimState p sym ext rtp (CrucibleLang blocks r) ('Just a))
       (SimState p sym ext rtp (CrucibleLang blocks r) ('Just a'))
       (CallFrame sym ext blocks r a)
       (CallFrame sym ext blocks r a')
stateCrucibleFrame = stateTree . actFrame . crucibleTopFrame
{-# INLINE stateCrucibleFrame #-}

-- | Access the override frame inside a 'SimState'
stateOverrideFrame ::
  Simple Lens
     (SimState p sym ext q (OverrideLang r) ('Just a))
     (OverrideFrame sym r a)
stateOverrideFrame = stateTree . actFrame . gpValue . overrideSimFrame

-- | Get the symbolic interface out of a 'SimState'
stateSymInterface :: Getter (SimState p sym ext r f a) sym
stateSymInterface = stateContext . ctxSymInterface

-- | Get the intrinsic type map out of a 'SimState'
stateIntrinsicTypes :: Getter (SimState p sym ext r f args) (IntrinsicTypes sym)
stateIntrinsicTypes = stateContext . to ctxIntrinsicTypes

-- | Get the configuration object out of a 'SimState'
stateConfiguration :: Getter (SimState p sym ext r f args) Config
stateConfiguration = to (\s -> stateSolverProof s (getConfiguration (s^.stateSymInterface)))

-- | Provide the 'IsSymInterface' typeclass dictionary from a 'SimState'
stateSolverProof :: SimState p sym ext r f args -> (forall a . IsSymInterfaceProof sym a)
stateSolverProof s = ctxSolverProof (s^.stateContext)
