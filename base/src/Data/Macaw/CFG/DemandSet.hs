{-|
Copyright  : (c) Galois, Inc 2017-2018
Maintainer : jhendrix@galois.com

This module provides a rewriter for simplifying values.
-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RankNTypes #-}
module Data.Macaw.CFG.DemandSet
  ( DemandComp
  , AssignIdSet
  , runDemandComp
  , addValueDemands
  , addStmtDemands
    -- * DemandContext
  , DemandContext(..)
  , hasSideEffects
    -- * Filtering after demand set is computed.
  , stmtNeeded
  ) where

import           Control.Monad.State.Strict
import           Data.Parameterized.Some
import           Data.Parameterized.TraversableF
import           Data.Parameterized.TraversableFC
import           Data.Parameterized.Map as MapF
import           Data.Set (Set)
import qualified Data.Set as Set

import           Data.Macaw.CFG

------------------------------------------------------------------------
-- Functions for computing demanded values

-- | Denotes a set of assignments
type AssignIdSet ids = Set (Some (AssignId ids))

-- | This provides the architecture specific functions needed to
-- resolve demand sets.
data DemandContext arch
   = DemandContext { archFnHasSideEffects :: !(forall v tp . ArchFn arch v tp -> Bool)
                     -- ^ This returns true if the architecture function has implicit
                     -- side effects (and thus can be safely removed).
                   , demandConstraints :: !(forall a
                                           . ((FoldableFC (ArchFn arch), FoldableF (ArchStmt arch))
                                               => a) -> a)
                   }

-- | Return true if assign rhs has side effects (and thus should always be demanded)
hasSideEffects :: DemandContext arch -> AssignRhs arch f tp -> Bool
hasSideEffects ctx rhs =
  case rhs of
    EvalApp{} -> False
    SetUndefined{} -> False
    ReadMem{} -> True
    CondReadMem{} -> True
    EvalArchFn fn _ -> archFnHasSideEffects ctx fn

data DemandState arch ids
   = DemandState { demandContext :: !(DemandContext arch)
                 , demandedAssignIds :: !(AssignIdSet ids)
                 }

-- | Monad used for computing demand sets.
newtype DemandComp arch ids a = DemandComp { unDemandComp :: State (DemandState arch ids) a }
  deriving (Functor, Applicative, Monad)

-- | Run demand computation and return the set of assignments that
-- were determined to be needed.
runDemandComp :: DemandContext arch -> DemandComp arch ids () -> AssignIdSet ids
runDemandComp ctx comp = demandedAssignIds $ execState (unDemandComp comp) s
  where s = DemandState { demandContext = ctx
                        , demandedAssignIds = Set.empty
                        }

-- | Add the ID of this assignment to demand set and also that of any
-- values needed to compute it.
addAssignmentDemands :: Assignment arch ids tp -> DemandComp arch ids ()
addAssignmentDemands a = do
  s <- DemandComp $ get
  let thisId = Some (assignId a)
  when (Set.notMember thisId (demandedAssignIds s)) $ do
    let s' = s { demandedAssignIds = Set.insert thisId (demandedAssignIds s) }
    seq s' $ DemandComp $ put s'
    demandConstraints (demandContext s) $
      traverseFC_ addValueDemands (assignRhs a)

-- | Add any subassignments needed to compute values to demand set.
addValueDemands :: Value arch ids tp -> DemandComp arch ids ()
addValueDemands v = do
  case v of
    BoolValue{} -> pure ()
    BVValue{} -> pure ()
    RelocatableValue{} -> pure ()
    SymbolValue{} -> pure ()
    AssignedValue a -> addAssignmentDemands a
    Initial{} ->  pure ()

-- | Parse statement, and if it has side effects, add assignments
-- needed to compute statement to demand set.
addStmtDemands :: Stmt arch ids -> DemandComp arch ids ()
addStmtDemands s =
  case s of
    AssignStmt a -> do
      ctx <- DemandComp $ gets demandContext
      when (hasSideEffects ctx (assignRhs a)) $ do
        addAssignmentDemands a
    WriteMem addr _repr val -> do
      addValueDemands addr
      addValueDemands val
    CondWriteMem cond addr _repr val -> do
      addValueDemands cond
      addValueDemands addr
      addValueDemands val
    InstructionStart{} ->
      pure ()
    Comment _ ->
      pure ()
    ExecArchStmt astmt -> do
      ctx <- DemandComp $ gets $ demandContext
      demandConstraints ctx $
        traverseF_ addValueDemands astmt
    ArchState _a updates ->
      MapF.traverseWithKey_ (const addValueDemands) updates

------------------------------------------------------------------------
-- Functions for computing demanded values

-- | This returns true if the statement should be kept given the demand set.
stmtNeeded :: AssignIdSet ids -> Stmt arch ids -> Bool
stmtNeeded demandSet stmt =
  case stmt of
    AssignStmt a -> Set.member (Some (assignId a)) demandSet
    CondWriteMem{} -> True
    WriteMem{} -> True
    InstructionStart{} -> True
    Comment{} -> True
    ExecArchStmt{} -> True
    ArchState{} -> True
