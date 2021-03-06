-----------------------------------------------------------------------
-- |
-- Module           : Lang.Crucible.Simulator
-- Description      : Reexports of relevant parts of submodules
-- Copyright        : (c) Galois, Inc 2018
-- License          : BSD3
-- Maintainer       : Joe Hendrix <jhendrix@galois.com>
-- Stability        : provisional
--
-- This module reexports the parts of the symbolic simulator codebase
-- that are most relevant for users.  Additional types and operations
-- are exported from the relavant submodules if necessary.
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
module Lang.Crucible.Simulator
  ( -- * Register values
    RegValue
  , RegValue'(..)
    -- ** Variants
  , VariantBranch(..)
  , injectVariant
    -- ** Any Values
  , AnyValue(..)
    -- ** Function Values
  , FnVal(..)
  , fnValType
    -- ** Recursive Values
  , RolledType(..)

    -- * Register maps
  , RegEntry(..)
  , RegMap(..)
  , emptyRegMap
  , regVal
  , assignReg

    -- * SimError
  , SimErrorReason(..)
  , SimError(..)

    -- * SimGlobalState
  , GlobalVar(..)
  , SymGlobalState
  , emptyGlobals

    -- * GlobalPair
  , GlobalPair(..)
  , gpValue
  , gpGlobals

    -- * AbortedResult
  , AbortedResult(..)

    -- * Partial result
  , PartialResult(..)
  , partialValue

    -- * Execution states
  , ExecResult(..)
  , ExecState(..)
  , ExecCont

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
  , SimState
  , initSimState
  , defaultAbortHandler
  , AbortHandler(..)
  , CrucibleState

    -- * Intrinsic types
  , IntrinsicClass
  , IntrinsicMuxFn(..)
  , IntrinsicTypes

    -- * Evaluation
  , executeCrucible
  , singleStepCrucible
  , evalReg
  , evalArgs
  , stepStmt
  , stepTerm
  , stepBasicBlock

    -- * OverrideSim monad
  , module Lang.Crucible.Simulator.OverrideSim
  ) where

import Lang.Crucible.CFG.Common
import Lang.Crucible.Simulator.ExecutionTree
import Lang.Crucible.Simulator.EvalStmt
import Lang.Crucible.Simulator.GlobalState
import Lang.Crucible.Simulator.Intrinsics
import Lang.Crucible.Simulator.Operations
import Lang.Crucible.Simulator.OverrideSim
import Lang.Crucible.Simulator.RegMap
import Lang.Crucible.Simulator.SimError
