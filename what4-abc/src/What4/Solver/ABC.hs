{-
Module           : What4.Solver.ABC
Copyright        : (c) Galois, Inc 2014-2016
Maintainer       : Joe Hendrix <jhendrix@galois.com>
License          : BSD3

Solver adapter and associcated operations for connecting the
Crucible simple builder backend to the ABC And-Inverter Graph (AIG)
representation.
-}

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -Werror #-}
module What4.Solver.ABC
  ( Network
  , newNetwork
  , withNetwork
  , checkSat
  , writeDimacsFile
  , runExternalDimacsSolver
  , GIA.SomeGraph(..)
  , writeAig
  , abcQbfIterations
  , abcOptions
  , abcAdapter
  , satCommand
  , genericSatOptions
  , genericSatAdapter
  ) where

import           Control.Concurrent
import           Control.Exception hiding (evaluate)
import           Control.Lens
import           Control.Monad.ST
import           Control.Monad.State.Strict
import           Data.Bits
import qualified Data.ABC as GIA
import qualified Data.ABC.GIA as GIA
import qualified Data.AIG.Operations as AIG
import qualified Data.AIG.Interface as AIG

import qualified Data.ByteString.UTF8 as UTF8
import qualified Data.Foldable as Fold
import qualified Data.HashSet as HSet
import           Data.IORef
import           Data.List (zipWith4)
import qualified Data.Map.Strict as Map
import           Data.Parameterized.HashTable (HashTable)
import qualified Data.Parameterized.HashTable as H
import           Data.Parameterized.Nonce (Nonce)
import           Data.Parameterized.Some
import           Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Text as T
import           Foreign.C.Types
import           Numeric.Natural
import           System.Directory
import           System.IO
import qualified System.IO.Streams as Streams
import           System.Process
import           Text.PrettyPrint.ANSI.Leijen hiding ((<$>))

import           What4.BaseTypes
import           What4.Concrete
import           What4.Config
import           What4.Interface (getConfiguration)
import           What4.Expr.Builder
import           What4.Expr.GroundEval
import qualified What4.Expr.UnaryBV as UnaryBV
import           What4.Expr.VarIdentification
import           What4.ProgramLoc
import           What4.Solver.Adapter
import           What4.SatResult
import           What4.Utils.Complex
import qualified What4.Utils.Environment as Env
import           What4.Utils.MonadST
import           What4.Utils.Streams

abcQbfIterations :: ConfigOption BaseIntegerType
abcQbfIterations = configOption BaseIntegerRepr "abc.qbf_max_iterations"

abcOptions :: [ConfigDesc]
abcOptions =
  [ opt abcQbfIterations (ConcreteInteger (toInteger (maxBound :: CInt)))
    (text "Max number of iterations to run ABC's QBF solver")
  ]

abcAdapter :: SolverAdapter st
abcAdapter =
   SolverAdapter
   { solver_adapter_name = "abc"
   , solver_adapter_config_options = abcOptions
   , solver_adapter_check_sat = \sym logLn p cont -> do
           res <- checkSat (getConfiguration sym) logLn p
           cont (fmap (\x -> (x,Nothing)) res)
   , solver_adapter_write_smt2 = \_ _ _ -> do
       fail "ABC backend does not support writing SMTLIB2 files."
   }


-- | Command to run sat solver.
satCommand :: ConfigOption BaseStringType
satCommand = configOption BaseStringRepr "sat_command"

genericSatOptions :: [ConfigDesc]
genericSatOptions =
  [ opt satCommand (ConcreteString "glucose $1")
    (text "Generic SAT solving command to run")
  ]

genericSatAdapter :: SolverAdapter st
genericSatAdapter =
   SolverAdapter
   { solver_adapter_name = "sat"
   , solver_adapter_config_options = genericSatOptions
   , solver_adapter_check_sat = \sym logLn p cont -> do
       let cfg = getConfiguration sym
       cmd <- T.unpack <$> (getOpt =<< getOptionSetting satCommand cfg)
       let mkCommand path = do
             let var_map = Map.fromList [("1",path)]
             Env.expandEnvironmentPath var_map cmd
       mmdl <- runExternalDimacsSolver logLn mkCommand p
       cont (fmap (\x -> (x, Nothing)) mmdl)
   , solver_adapter_write_smt2 = \_ _ _ -> do
       fail "SAT backend does not support writing SMTLIB2 files."
   }

-- | Maps expression types to the representation used in the ABC backend.
-- The ABC backend only supports Bools and bitvectors, so only constants
-- are supported for the other types.
type family LitValue s (tp :: BaseType) where
  LitValue s BaseBoolType     = GIA.Lit s
  LitValue s (BaseBVType n)   = AIG.BV (GIA.Lit s)
  LitValue s BaseNatType      = Natural
  LitValue s BaseIntegerType  = Integer
  LitValue s BaseRealType     = Rational
  LitValue s BaseStringType   = T.Text
  LitValue s BaseComplexType  = Complex Rational

-- | Newtype wrapper around names.
data NameType s (tp :: BaseType) where
  B  :: GIA.Lit s -> NameType s BaseBoolType
  BV :: AIG.BV (GIA.Lit s) -> NameType s (BaseBVType n)
  GroundNat :: Natural -> NameType s BaseNatType
  GroundInt :: Integer -> NameType s BaseIntegerType
  GroundRat :: Rational -> NameType s BaseRealType
  GroundString :: T.Text -> NameType s BaseStringType
  GroundComplex :: Complex Rational -> NameType s BaseComplexType

-- | A variable binding in ABC.
data VarBinding t s where
  BoolBinding :: Nonce t BaseBoolType
              -> GIA.Lit s
              -> VarBinding t s
  BVBinding  :: (1 <= w)
             => Nonce t (BaseBVType w)
             -> AIG.BV (GIA.Lit s)
             -> VarBinding t s

-- | Handle to the ABC interface.
data Network t s = Network { gia :: GIA.GIA s
                           , nameCache :: !(HashTable RealWorld (Nonce t) (NameType s))
                             -- | Holds outputs in reverse order when used to write
                              -- AIGs
                           , revOutputs :: !(IORef [GIA.Lit s])
                           }

memoExprNonce :: Network t s
              -> Nonce t tp
              -> IO (NameType s tp)
              -> IO (NameType s tp)
memoExprNonce ntk n ev = do
  let c = nameCache ntk
  mnm <- liftST $ H.lookup c n
  case mnm of
    Just nm -> return nm
    Nothing -> do
      r <- ev
      liftST $ H.insert c n r
      return r

eval :: Network t s -> Expr t tp -> IO (NameType s tp)
eval _ (SemiRingLiteral SemiRingNat n _) = return (GroundNat n)
eval _ (SemiRingLiteral SemiRingInt n _) = return (GroundInt n)
eval _ (SemiRingLiteral SemiRingReal r _) = return (GroundRat r)
eval ntk (BVExpr w v _) = return $ BV $ AIG.bvFromInteger (gia ntk) (widthVal w) v
eval _ (StringExpr s _) = return (GroundString s)

eval ntk (NonceAppExpr e) = do
  memoExprNonce ntk (nonceExprId e) $ do
    bitblastPred ntk e
eval ntk (AppExpr a) = do
  memoExprNonce ntk (appExprId a) $ do
    bitblastExpr ntk a
eval ntk (BoundVarExpr info) = do
  memoExprNonce ntk (bvarId info) $ do
    case bvarKind info of
      QuantifierVarKind ->
        error $ "Bound variable is not defined."
      LatchVarKind ->
        error $ "Latches that are not defined."
      UninterpVarKind ->
        error $ "Uninterpreted variable that was not defined."

eval' :: Network t s -> Expr t tp -> IO (LitValue s tp)
eval' ntk e = do
  r <- eval ntk e
  case r of
    B l -> return l
    BV v -> return v
    GroundNat c -> return c
    GroundInt c -> return c
    GroundRat c -> return c
    GroundComplex c -> return c
    GroundString c -> return c

failAt :: ProgramLoc -> String -> IO a
failAt l msg = fail $ show $
   text msg <$$>
   text "From term created at" <+> pretty (plSourceLoc l)

failTerm :: Expr t tp -> String -> IO a
failTerm e nm = do
  fail $ show $
    text "The" <+> text nm <+> text "created at"
         <+> pretty (plSourceLoc (exprLoc e))
         <+> text "is not supported by ABC:" <$$>
    indent 2 (ppExpr e)

bitblastPred :: Network t s -> NonceAppExpr t tp -> IO (NameType s tp)
bitblastPred h e = do
  case nonceExprApp e of
    Forall _ x -> eval h x
    Exists _ x -> eval h x
    ArrayFromFn{} -> fail "ABC does not support uninterpreted functions"
    MapOverArrays{} -> fail "ABC does not support uninterpreted functions"
    ArrayTrueOnEntries{} -> fail "ABC does not support uninterpreted functions"
    FnApp{} -> fail "ABC does not support uninterpreted functions"

-- | Create a representation of the expression as Boolean variables.
bitblastExpr :: forall t s tp . Network t s -> AppExpr t tp -> IO (NameType s tp)
bitblastExpr h ae = do
  let g = gia h
  let natFail :: IO a
      natFail = failTerm (AppExpr ae) "natural number expression"
  let intFail :: IO a
      intFail = failTerm (AppExpr ae) "integer expression"
  let realFail :: IO a
      realFail = failTerm (AppExpr ae) "real expression"
  let arrayFail :: IO a
      arrayFail = failTerm (AppExpr ae) "array expression"
  let structFail :: IO a
      structFail = failTerm (AppExpr ae) "struct expression"
  case appExprApp ae of

    TrueBool  -> do
      return $ B $ GIA.true
    FalseBool -> do
      return $ B $ GIA.false
    NotBool xe -> do
      B . GIA.not <$> eval' h xe
    AndBool x y -> do
      B <$> (join $ GIA.and g <$> eval' h x <*> eval' h y)
    XorBool x y -> do
      B <$> (join $ GIA.xor g <$> eval' h x <*> eval' h y)
    IteBool c x y -> do
      B <$> (join $ GIA.mux g <$> eval' h c <*> eval' h x <*> eval' h y)

    RealIsInteger{} -> realFail
    PredToBV p -> BV . AIG.singleton <$> eval' h p
    BVTestBit i xe -> assert (i <= toInteger (maxBound :: Int)) $
       (\v -> B $ v AIG.! (fromInteger i)) <$> eval' h xe
    BVEq  x y -> B <$> join (AIG.bvEq g <$> eval' h x <*> eval' h y)
    BVSlt x y -> B <$> join (AIG.slt  g <$> eval' h x <*> eval' h y)
    BVUlt x y -> B <$> join (AIG.ult  g <$> eval' h x <*> eval' h y)
    ArrayEq{} -> arrayFail

    ------------------------------------------------------------------------
    -- Nat operations

    SemiRingMul SemiRingNat _ _ -> natFail
    SemiRingSum SemiRingNat _ -> natFail
    SemiRingEq SemiRingNat _ _ -> natFail
    SemiRingLe SemiRingNat _ _ -> natFail
    SemiRingIte SemiRingNat _ _ _ -> natFail
    NatDiv{} -> natFail

    ------------------------------------------------------------------------
    -- Integer operations

    SemiRingMul SemiRingInt _ _ -> intFail
    SemiRingSum SemiRingInt _ -> intFail
    SemiRingEq  SemiRingInt _ _ -> intFail
    SemiRingLe  SemiRingInt _ _ -> intFail
    SemiRingIte SemiRingInt _ _ _ -> intFail
    IntAbs{} -> intFail
    IntDiv{} -> intFail
    IntMod{} -> intFail
    IntDivisible{} -> intFail

    ------------------------------------------------------------------------
    -- Real value operations

    SemiRingMul SemiRingReal _ _ -> realFail
    SemiRingSum SemiRingReal _ -> realFail
    SemiRingEq  SemiRingReal _ _ -> realFail
    SemiRingLe  SemiRingReal _ _ -> realFail
    SemiRingIte SemiRingReal _ _ _ -> realFail
    RealDiv{} -> realFail
    RealSqrt{} -> realFail

    --------------------------------------------------------------------
    -- Operations that introduce irrational numbers.

    Pi -> realFail
    RealSin{} -> realFail
    RealCos{} -> realFail
    RealATan2{} -> realFail
    RealSinh{} -> realFail
    RealCosh{} -> realFail
    RealExp{} -> realFail
    RealLog{} -> realFail

    --------------------------------------------------------------------
    -- Bitvector operations

    BVUnaryTerm u -> do
      let w = UnaryBV.width u
      let cns v = return $ AIG.bvFromInteger g (widthVal w) v
      let ite :: BoolExpr t
              -> AIG.BV (GIA.Lit s)
              -> AIG.BV (GIA.Lit s)
              -> IO (AIG.BV (GIA.Lit s))
          ite p x y = do
            c <- eval' h p
            AIG.ite g c x y
      BV <$> UnaryBV.sym_evaluate cns ite u
    BVConcat _w xe ye -> do
      x <- eval' h xe
      y <- eval' h ye
      return $ BV $ x AIG.++ y
    BVSelect idx n xe -> do
      x <- eval' h xe
      return $ BV $ AIG.sliceRev x (fromIntegral (natValue idx)) (fromIntegral (natValue n))
    BVNeg _w x -> do
      BV <$> join (AIG.neg g <$> eval' h x)
    BVAdd _w x y -> do
      BV <$> join (AIG.add g <$> eval' h x <*> eval' h y)
    BVMul _w x y -> do
      BV <$> join (AIG.mul g <$> eval' h x <*> eval' h y)
    BVUdiv _w x y -> do
     BV <$> join (AIG.uquot g <$> eval' h x <*> eval' h y)
    BVUrem _w x y -> do
      BV <$> join (AIG.urem g <$> eval' h x <*> eval' h y)
    BVSdiv _w x y ->
      BV <$> join (AIG.squot g <$> eval' h x <*> eval' h y)
    BVSrem _w x y ->
      BV <$> join (AIG.srem g  <$> eval' h x <*> eval' h y)

    BVIte _ _ c x y -> BV <$> join (AIG.ite g <$> eval' h c <*> eval' h x <*> eval' h y)

    BVShl _w x y -> BV <$> join (AIG.shl g <$> eval' h x <*> eval' h y)
    BVLshr _w x y -> BV <$> join (AIG.ushr g <$> eval' h x <*> eval' h y)
    BVAshr _w x y -> BV <$> join (AIG.sshr g <$> eval' h x <*> eval' h y)

    BVZext  w' xe -> do
      x <- eval' h xe
      return $ BV $ AIG.zext g x (widthVal w')
    BVSext  w' xe -> do
      x <- eval' h xe
      return $ BV $ AIG.sext g x (widthVal w')
    BVTrunc w' xe -> do
      x <- eval' h xe
      return $ BV $ AIG.trunc (widthVal w') x
    BVBitNot _w x -> do
      BV . fmap (AIG.lNot' g) <$> eval' h x
    BVBitAnd _w x y -> do
      BV <$> join (AIG.zipWithM (AIG.lAnd' g) <$> eval' h x <*> eval' h y)
    BVBitOr _w x y -> do
      BV <$> join (AIG.zipWithM (AIG.lOr' g) <$> eval' h x <*> eval' h y)
    BVBitXor _w x y -> do
      BV <$> join (AIG.zipWithM (AIG.lXor' g) <$> eval' h x <*> eval' h y)

    ------------------------------------------------------------------------
    -- Array operations

    ArrayMap{} -> arrayFail
    ConstantArray{} -> arrayFail
    MuxArray{} -> arrayFail
    SelectArray{} -> arrayFail
    UpdateArray{} -> arrayFail

    ------------------------------------------------------------------------
    -- Conversions.

    NatToInteger{}  -> intFail
    IntegerToReal{} -> realFail
    BVToNat{} -> natFail
    BVToInteger{} -> intFail
    SBVToInteger{} -> intFail

    RoundReal{} -> realFail
    FloorReal{} -> realFail
    CeilReal{}  -> realFail
    RealToInteger{} -> intFail

    IntegerToNat{} -> natFail
    IntegerToBV{}  -> intFail

    ------------------------------------------------------------------------
    -- Complex operations

    Cplx (r :+ i) -> do
      GroundComplex <$> ((:+) <$> eval' h r <*> eval' h i)
    RealPart c -> do
      GroundRat . realPart <$> eval' h c
    ImagPart c -> do
      GroundRat . imagPart <$> eval' h c

    ------------------------------------------------------------------------
    -- Structs

    StructCtor{}  -> structFail
    StructField{} -> structFail
    StructIte{}   -> structFail

newNetwork :: IO (GIA.SomeGraph (Network t))
newNetwork = do
  GIA.SomeGraph g <- GIA.newGIA
  nc <- liftST $ H.new
  outputsRef <- newIORef []
  let s = Network { gia = g
                  , nameCache = nc
                  , revOutputs = outputsRef
                  }
  return (GIA.SomeGraph s)

withNetwork :: (forall s . Network t s -> IO a) -> IO a
withNetwork m = do
  GIA.SomeGraph h <- newNetwork
  m h

asInteger :: Monad m => (l -> m Bool) -> AIG.BV l -> m Integer
asInteger f v = go 0 0
  where n = AIG.length v
        go r i | i == n = return r
        go r i = do
          b <- f (v `AIG.at` i)
          let q = if b then 1 else 0
          go ((r `shiftL` 1) .|. q) (i+1)

-- | Look to see if literals have been assigned to expression.
evalNonce :: Network t s
          -> Nonce t tp
          -> (GIA.Lit s -> Bool)
          -> IO (GroundValue tp)
          -> IO (GroundValue tp)
evalNonce ntk n eval_fn fallback = do
  -- Look to see if literals have been assigned to expression.
  mnm <- liftST $ H.lookup (nameCache ntk) n
  case mnm of
    Just (B l) -> return $ eval_fn l
    Just (BV bv) -> asInteger (return . eval_fn) bv
    Just (GroundNat x) -> return x
    Just (GroundInt x) -> return x
    Just (GroundRat x) -> return x
    Just (GroundComplex c) -> return c
    Just (GroundString c) -> return c
    Nothing -> fallback

evaluateSatModel :: forall t s
                  . Network t s
                 -> [Bool] -- ^ Fixed input arguments (used for QBF).
                 -> GIA.SatResult
                 -> IO (SatResult (GroundEvalFn t))
evaluateSatModel ntk initial_args sat_res = do
  case sat_res of
    GIA.Sat assignment -> do
      -- Get literal evaluation function.
      eval_fn <- GIA.evaluator (gia ntk) (assignment ++ initial_args)
      -- Create cache for memoizing results.
      groundCache <- newIdxCache
      let f :: Expr t tp -> IO (GroundValue tp)
          f e = case exprMaybeId e of
                  Nothing -> evalGroundExpr f e
                  Just n ->
                    fmap unGVW $ idxCacheEval groundCache e $ fmap GVW $ do
                      evalNonce ntk n eval_fn $ do
                        evalGroundExpr f e
      return $ Sat $ GroundEvalFn f

    GIA.Unsat -> return Unsat
    GIA.SatUnknown ->
      fail "evaluateSatModel: ABC returned unknown sat result"


runQBF :: Network t s
       -> Int
          -- ^ Number of existential variables.
       -> GIA.Lit s
          -- ^ Condition to check satifiability of.
       -> CInt
          -- ^ Maximum number of iterations to run.
       -> IO (SatResult (GroundEvalFn t))
runQBF ntk e_cnt cond max_iter = do
  tot_cnt <- GIA.inputCount (gia ntk)
  let a_cnt = tot_cnt - e_cnt
      initial_forall = replicate a_cnt False
  mr <- GIA.check_exists_forall (gia ntk) e_cnt cond initial_forall max_iter
  case mr of
    Left  m -> fail m
    Right r -> evaluateSatModel ntk initial_forall r

addOutput :: Network t s -> GIA.Lit s -> IO ()
addOutput h l = do
  modifyIORef' (revOutputs h) $ (l:)

outputExpr :: Network t s -> Expr t tp -> IO ()
outputExpr h e = do
  r <- eval h e
  case r of
    B l -> addOutput h l
    BV v -> Fold.traverse_ (addOutput h) v
    GroundNat _ -> fail $ "Cannot bitblast nat values."
    GroundInt _ -> fail $ "Cannot bitblast integer values."
    GroundRat _ -> fail $ "Cannot bitblast real values."
    GroundComplex _ -> fail $ "Cannot bitblast complex values."
    GroundString _ -> fail $ "Cannot bitblast string values."

-- | @getForallPred ntk v p ev av@ adds assertion that:
-- @Ep.Eev.Aav.p = v@.
getForallPred :: Network t s
              -> Some (QuantifierInfo t)
              -> GIA.Lit s
              -> VarBinding t s
              -> VarBinding t s
              -> IO (GIA.Lit s)
getForallPred ntk (Some b) p e_binding a_binding = do
  let g = gia ntk
  let c = nameCache ntk
  let e = boundTopTerm b
  let t = boundInnerTerm b
  -- Bind top-most quantifier to e
  liftST $ H.insert c (nonceExprId e) (B p)
  -- Switch on quantifier type.
  case boundQuant b of
    ForallBound -> do
      -- Generate predicate p => (Av. t)
      recordBinding ntk a_binding
      B c_a <- eval ntk t
      c1 <- GIA.implies g p c_a
      -- Generate predicate (Av. t) => p
      recordBinding ntk e_binding
      B c_e <- eval ntk t
      c2 <- GIA.implies g c_e p
      -- Delete binding to elements.
      deleteBinding ntk e_binding
      -- Return both predicates.
      GIA.and g c1 c2
    ExistBound -> do
      -- Generate predicate p => (Ev. t)
      recordBinding ntk e_binding
      B c_e <- eval ntk t
      c1 <- GIA.implies g p c_e
      -- Generate predicate (Ev. t) => p
      recordBinding ntk a_binding
      B c_a <- eval ntk t
      c2 <- GIA.implies g c_a p
      -- Delete binding to elements.
      deleteBinding ntk a_binding
      -- Return both predicates.
      GIA.and g c1 c2

-- | Check variables are supported by ABC.
checkSupportedByAbc :: Monad m => CollectedVarInfo t -> m ()
checkSupportedByAbc vars = do
  let errors = Fold.toList (vars^.varErrors)
  -- Check no errors where reported in result.
  when (not (null errors)) $ do
    fail $ show $ text "This formula is not supported by abc:" <$$>
                  indent 2 (vcat errors)

checkNoLatches :: Monad m => CollectedVarInfo t -> m ()
checkNoLatches vars = do
  when (not (Set.null (vars^.latches))) $ do
    fail "Cannot check satisfiability of circuits with latches."

-- | Check that var result contains no universally quantified variables.
checkNoForallVars :: Monad m => CollectedVarInfo t -> m ()
checkNoForallVars vars = do
  unless (Map.null (vars^.forallQuantifiers)) $ do
    fail "This operation does not support universally quantified variables."

recordUninterpConstants :: Network t s -> Set (Some (ExprBoundVar t)) -> IO ()
recordUninterpConstants ntk s = do
  let recordCon v = recordBinding ntk =<< addBoundVar' ntk v
  mapM_ recordCon (Fold.toList s)

recordBoundVar :: Network t s -> Some (QuantifierInfo t) -> IO ()
recordBoundVar ntk info = do
  recordBinding ntk =<< addBoundVar ntk info

-- | Expression to check is satisfiable.
checkSat :: Config
         -> (Int -> String -> IO ())
         -> BoolExpr t
         -> IO (SatResult (GroundEvalFn t))
checkSat cfg logLn e = do
  -- Get variables in expression.
  let vars = predicateVarInfo e
  max_qbf_iter <- fromInteger <$> (getOpt =<< getOptionSetting abcQbfIterations cfg)
  checkSupportedByAbc vars
  checkNoLatches vars
  withNetwork $ \ntk -> do
    -- Get network
    let g = gia ntk
    -- Add bindings for uninterpreted bindings.
    recordUninterpConstants ntk (vars^.uninterpConstants)
    -- Add bindings for bound variables.
    let e_quants = vars^.existQuantifiers
    let a_quants = vars^.forallQuantifiers
    let e_only_quants = Fold.toList $ Map.difference e_quants a_quants
    let a_only_quants = Fold.toList $ Map.difference a_quants e_quants
    let both_quants   = Fold.toList $ Map.intersection a_quants e_quants

    -- Add bindings for existential variables.
    mapM_ (recordBoundVar ntk) e_only_quants

    -- Get predicate to hold value on whether quantifier is true
    -- true or false.
    both_preds <- mapM (\_ -> GIA.newInput (gia ntk)) both_quants

    -- Get existential variables for representing both bound variables.
    e_both_bindings  <- mapM (addBoundVar ntk) both_quants

    exist_cnt <- GIA.inputCount g
    -- Add variables that are only universally quantified.
    mapM_ (recordBoundVar ntk) a_only_quants
    -- Get uninterval variables for representing both bound variables.
    a_both_bindings  <- mapM (addBoundVar ntk) both_quants
    -- Evaluate lit.
    B c <- eval ntk e
    -- Add predicates for both vars.
    preds <- sequence $ do
      zipWith4 (getForallPred ntk) both_quants both_preds e_both_bindings a_both_bindings
    -- Get final pred.
    p <- foldM (GIA.and (gia ntk)) c preds
    -- Add bindings for uninterpreted bindings.
    if Map.null a_quants then do
      logLn 2 "Calling ABC's SAT solver"
      r <- GIA.checkSat (gia ntk) p
      evaluateSatModel ntk [] r
    else do
      logLn 2 "Calling ABC's QBF solver"
      runQBF ntk exist_cnt p max_qbf_iter

-- | Associate an element in a binding with the term.
recordBinding :: Network t s -> VarBinding t s -> IO ()
recordBinding ntk b = liftST $
  case b of
    BoolBinding n r -> H.insert (nameCache ntk) n (B r)
    BVBinding   n r -> H.insert (nameCache ntk) n (BV r)

deleteBinding :: Network t s -> VarBinding t s -> IO ()
deleteBinding ntk b = liftST $
  case b of
    BoolBinding n _ -> H.delete (nameCache ntk) n
    BVBinding   n _ -> H.delete (nameCache ntk) n

freshBV :: AIG.IsAIG l g => g s -> NatRepr n -> IO (AIG.BV (l s))
freshBV g w = AIG.generateM_msb0 (widthVal w) (\_ -> GIA.newInput g)

-- | Add an uninterpreted variable.
freshBinding :: Network t s
             -> Nonce t tp
                -- ^ Unique id for variable.
             -> ProgramLoc
                -- ^ Location of binding.
             -> BaseTypeRepr tp
                -- ^ Type of variable
             -> IO (VarBinding t s)
freshBinding ntk n l tp = do
  let g = gia ntk
  case tp of
    BaseBoolRepr -> do
      BoolBinding n <$> GIA.newInput g
    BaseBVRepr w -> do
      BVBinding n <$> freshBV g w
    BaseNatRepr     -> failAt l "Natural number variables are not supported by ABC."
    BaseIntegerRepr -> failAt l "Integer variables are not supported by ABC."
    BaseRealRepr    -> failAt l "Real variables are not supported by ABC."
    BaseStringRepr  -> failAt l "String variables are not supported by ABC."
    BaseComplexRepr -> failAt l "Complex variables are not supported by ABC."
    BaseArrayRepr _ _ -> failAt l "Array variables are not supported by ABC."
    BaseStructRepr{}  -> failAt l "Struct variables are not supported by ABC."

-- | Add a bound variable.
addBoundVar :: Network t s -> Some (QuantifierInfo t) -> IO (VarBinding t s)
addBoundVar ntk (Some info) = do
  let bvar = boundVar info
  freshBinding ntk (bvarId bvar) (bvarLoc bvar) (bvarType bvar)

-- | Add a bound variable.
addBoundVar' :: Network t s -> Some (ExprBoundVar t) -> IO (VarBinding t s)
addBoundVar' ntk (Some bvar) = do
  freshBinding ntk (bvarId bvar) (bvarLoc bvar) (bvarType bvar)

readSATInput :: (String -> IO ())
             -> Streams.InputStream String
             -> [Int]
             -> IO GIA.SatResult
readSATInput logLn in_stream vars = do
  mln <- Streams.read in_stream
  case mln of
    Nothing -> fail "Unexpected end of SAT solver output."
    Just "s SATISFIABLE" -> do
      msln <- Streams.read in_stream
      case words <$> msln of
        Just ("v":num) -> do
          let trueVars :: HSet.HashSet Int
              trueVars = HSet.fromList $ filter (>0) $ read <$> num
          let varValue v = HSet.member v trueVars
          return $ GIA.Sat (varValue <$> vars)
        Just _ -> do
          fail "Could not parse output from sat solver."
        Nothing -> fail "Unexpected end of SAT solver output."
    Just "s UNSATISFIABLE" -> do
       return $ GIA.Unsat
    Just ln -> do
       logLn ln
       readSATInput logLn in_stream vars

-- | Write an external file using DIMACS format.
writeDimacsFile :: Network t s
                -> FilePath
                -> BoolExpr t
                -> IO [Int]
writeDimacsFile ntk cnf_path condition = do
  -- Get variables in expression.
  let vars = predicateVarInfo condition
  checkSupportedByAbc vars
  checkNoLatches vars
  checkNoForallVars vars
  -- Add bindings for uninterpreted bindings.
  recordUninterpConstants ntk (vars^.uninterpConstants)
  -- Add bindings for existential variables.
  Fold.traverse_ (recordBoundVar ntk) (vars^.existQuantifiers)
  -- Generate predicate for top level term.
  B c <- eval ntk condition
  GIA.writeCNF (gia ntk) c cnf_path

-- | Run an external solver using competition dimacs format.
runExternalDimacsSolver :: (Int -> String -> IO ()) -- ^ Logging function
                        -> (FilePath -> IO String)
                        -> BoolExpr t
                        -> IO (SatResult (GroundEvalFn t))
runExternalDimacsSolver logLn mkCommand condition = do
  temp_dir <- getTemporaryDirectory
  let close (path,h) = do
        hClose h
        removeFile path
  bracket (openTempFile temp_dir "sat.cnf") close $ \(cnf_path,_h) -> do
    logLn 2 $ "Writing CNF file to " ++ show cnf_path ++ "."
    withNetwork $ \ntk -> do
      vars <- writeDimacsFile ntk cnf_path condition
      command <- mkCommand cnf_path
      logLn 2 $ "About to call: " ++ command
      let stopProcess (_,_,_,ph) = do
            terminateProcess ph
      let runSatProcess (_in_stream, out_stream, err_stream, _ph) = do
            -- Log stderr to output.
            void $ forkIO $ logErrorStream err_stream (logLn 2)
            -- Read stdout as result.
            out_lines <- Streams.map UTF8.toString =<< Streams.lines out_stream
            res <- readSATInput (logLn 2) out_lines vars
            -- Create model
            evaluateSatModel ntk [] res
      bracketOnError (Streams.runInteractiveCommand command) stopProcess runSatProcess

hasBoundVars :: CollectedVarInfo t -> Bool
hasBoundVars vars = not (Map.null (vars^.forallQuantifiers))
                 || not (Map.null (vars^.existQuantifiers))

-- | Write AIG that outputs given value.
writeAig :: FilePath
         -> [Some (Expr t)]
            -- ^ The combinational outputs.
         -> [Some (Expr t)]
            -- ^ The latch outputs (may be empty)
         -> IO ()
writeAig path v latchOutputs = do
  -- Get variables in expression.
  let vars = runST $ collectVarInfo $ do
               Fold.traverse_ (traverseSome_ (recordExprVars ExistsOnly)) v
               Fold.traverse_ (traverseSome_ (recordExprVars ExistsOnly))
                              latchOutputs
  -- Check inputs.
  checkSupportedByAbc vars
  when (hasBoundVars vars) $ do
    fail "Cannot write an AIG with bound variables."
  -- Generate AIG
  withNetwork $ \ntk -> do
    -- Add bindings for uninterpreted bindings.
    recordUninterpConstants ntk (vars^.uninterpConstants)
    -- Add bindings for existential variables.
    Fold.traverse_ (recordBoundVar ntk) (vars^.existQuantifiers)

    -- Get input count
    cInCount <- getInputCount ntk
    -- Add latchInputs
    Fold.traverse_ (addBoundVar' ntk) $ vars^.latches
    -- Add value to AIGER output.
    Fold.traverse_ (traverseSome_ (outputExpr ntk)) v
    -- Get current number of outputs.
    cOutCount <- getOutputCount ntk
    -- Write latch outputs.
    Fold.traverse_ (traverseSome_ (outputExpr ntk)) latchOutputs
    -- Get number of outputs including latches.
    allInCount <- getInputCount ntk
    allOutCount <- getOutputCount ntk
    let inLatchCount = allInCount - cInCount
    let outLatchCount = allOutCount - cOutCount
    when (inLatchCount /=  outLatchCount) $ do
      fail $ "Expected " ++ show inLatchCount ++ " latch outputs, when "
          ++ show outLatchCount ++ " are given."
    out <- getOutputs ntk
    GIA.writeAigerWithLatches path (GIA.Network (gia ntk) out) inLatchCount

getOutputs :: Network t s -> IO [GIA.Lit s]
getOutputs ntk = reverse <$> readIORef (revOutputs ntk)

-- | Return number of inputs so far in network.
getInputCount :: Network t s -> IO Int
getInputCount ntk = GIA.inputCount (gia ntk)

-- | Return number of outputs so far in network.
getOutputCount :: Network t s -> IO Int
getOutputCount ntk = length <$> readIORef (revOutputs ntk)
