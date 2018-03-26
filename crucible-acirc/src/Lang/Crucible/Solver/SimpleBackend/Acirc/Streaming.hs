{-# LANGUAGE GADTs #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
module Lang.Crucible.Solver.SimpleBackend.Acirc.Streaming
( SimulationResult(..)
, generateCircuit
) where

import           Data.Maybe
import qualified Data.Map.Strict as M
import           Data.Tuple ( swap )
import           Data.Word  ( Word64 )
import           Data.Ratio ( denominator, numerator )
import           Data.IORef ( IORef, newIORef, readIORef, writeIORef, atomicModifyIORef )

import qualified System.IO as Sys
import qualified Text.Printf as Sys
import           Control.Exception ( assert )
import           Control.Monad ( void )
import           Control.Monad.ST ( RealWorld )
import           Control.Monad.State ( runState )
import qualified Data.Text as T

-- Crucible imports
import           Data.Parameterized.HashTable (HashTable)
import qualified Data.Parameterized.HashTable as H
import           Data.Parameterized.Nonce ( NonceGenerator, freshNonce, Nonce, indexValue )
import           Data.Parameterized.Some ( Some(..) )
import qualified Data.Parameterized.Context as Ctx
-- import qualified Data.Parameterized.Context.Safe as Ctx
import           Lang.Crucible.BaseTypes ( BaseType, BaseIntegerType, BaseTypeRepr(..)
                                         , BaseRealType )
import           Lang.Crucible.Utils.MonadST ( liftST )
import           Lang.Crucible.Solver.SimpleBuilder ( Elt(..), SimpleBoundVar(..), VarKind(..)
                                                    , App(..), AppElt(..)
                                                    , NonceApp(..)
                                                    , NonceAppElt(..)
                                                    , eltId, eltMaybeId, appEltApp, nonceEltId
                                                    , nonceEltApp, symFnName
                                                    , symFnReturnType )
import           Lang.Crucible.Solver.Symbol ( solverSymbolAsText )
import qualified Lang.Crucible.Solver.WeightedSum as WS

{- | Package up the state we need during `eval`. This includes
- the memoization table, `synthesisHash`, we use for keeping track
- of wires and gates. -}
data Synthesis t = Synthesis
  { synthesisHash      :: HashTable RealWorld (Nonce t) NameType -- ^ memo table from ids (`Nonce`) to evaluated
                                                             -- form (`NameType`)
  , synthesisConstants :: IORef (M.Map Integer (Nonce t BaseIntegerType)) -- maps constants to their wire id
  , synthesisOut       :: Sys.Handle
  , synthesisGen       :: NonceGenerator IO t
  }

-- | This represents the simplified terms from crucible.
data NameType (tp :: BaseType) where
  IntToReal :: NameType BaseIntegerType -> NameType BaseRealType
  Ref       :: Word64   -> NameType BaseIntegerType

-- | Holds the results of a simulation run. This should be passed to
-- generateCircuit.
data SimulationResult a = SimulationResult
  { srInputs :: [a] -- ^ Tracks the expected inputs, in order, so that input wires can be
                    --   added correctly.
  , srTerms  :: [a] -- ^ The terms resulting from the simulation. The circuit is built from these.
  }

-- | memoization function.
--   * Takes the synthesis state
--   * id of the term (nonce)
--   * action to use in the case the term has not been
--     seen before
--   Returns the simplified term for the nonce.
memoEltNonce :: Synthesis t
             -> Nonce t tp
             -> IO (NameType tp)
             -> IO (NameType tp)
memoEltNonce synth n act = do
  let h = synthesisHash synth
  mn <- liftST $ H.lookup h n
  case mn of
    Just m  -> return m -- The id was found in the memo table
    Nothing -> do
      name <- act
      liftST $ H.insert h n name
      return name

memoConstNonce :: Synthesis t
               -> Integer
               -> (Nonce t BaseIntegerType -> IO (NameType BaseIntegerType))
               -> IO (NameType BaseIntegerType)
memoConstNonce synth val act = do
  m <- readIORef (synthesisConstants synth)
  case M.lookup val m of
    Just wireId -> return (Ref (indexValue wireId))
    Nothing     -> do
      n <- freshNonce (synthesisGen synth)
      atomicModifyIORef (synthesisConstants synth) $ \m' ->
        (M.insert val n m', ())
      memoEltNonce synth n (act n)

-- | A version of memoEltNonce that works for non-bound varables like an
-- concrete value. See 'addConstantValue' for more details.
memoElt :: Synthesis t
        -> IO (NameType tp)
        -> IO (NameType tp)
memoElt synth act = do
  name <- act
  return name

generateCircuit :: NonceGenerator IO t -> FilePath -> SimulationResult (Elt t BaseIntegerType) -> IO ()
generateCircuit gen fp (SimulationResult { srInputs = is, srTerms = es }) =
  Sys.withFile fp Sys.WriteMode $ \h -> do
    -- First, we create empty data structures for the conversion
    table     <- liftST H.new
    constants <- newIORef M.empty
    let synth = Synthesis { synthesisOut       = h
                          , synthesisHash      = table
                          , synthesisGen       = gen
                          , synthesisConstants = constants
                          }
    writeHeader synth
    recordInputs synth is
    names <- mapM (eval synth) es
    writeCircuit synth es
    writeOutputs synth names
  where
  writeOutputs :: Synthesis t -> [NameType BaseIntegerType] -> IO ()
  writeOutputs synth names = writeOutput synth wireIds
    where
    wireIds = catMaybes (map wireId names)
  wireId :: NameType BaseIntegerType -> Maybe Word64
  wireId (Ref r) = Just r
  wireId _       = Nothing
  
writeHeader :: Synthesis t -> IO ()
writeHeader synth = Sys.hPutStrLn (synthesisOut synth) "v1.0"

recordInputs :: Synthesis t -> [Elt t BaseIntegerType] -> IO ()
recordInputs synth vars = do
  mapM_ (addInput synth) (zip vars [0..])

addInput :: Synthesis t -> (Elt t BaseIntegerType, Word64) -> IO ()
addInput synth (var, inputId) = do
  case var of
    BoundVarElt bvar  -> addBoundVar synth (Some bvar) inputId
    IntElt _i _loc    -> addConstantInput synth inputId
    t -> error $ "addInput: Unsupported representation: " ++ show t

addBoundVar :: Synthesis t -> Some (SimpleBoundVar t) -> Word64 -> IO ()
addBoundVar synth (Some bvar) inputId = do
  case bvarType bvar of
    BaseIntegerRepr -> void $ memoEltNonce synth (bvarId bvar) $ do
      writeInput synth (indexValue (bvarId bvar)) inputId

writeInput :: Synthesis t -> Word64 -> Word64 -> IO (NameType BaseIntegerType)
writeInput synth out id = do
  Sys.hPrintf (synthesisOut synth) "%d input %d @ [Integer]\n" out id
  return (Ref out)

-- | This is for handling a special case of inputs. Sometimes the parameters are
-- fixed and known, but we still want the function/circuit to take values in
-- those places as "inputs". In this case, we want the circuit to declare wires
-- for them but not connect them to the rest of the circuit. So we have a
-- special case where we put them in the memo table but otherwise throw away
-- their references.
addConstantInput :: Synthesis t -> Word64 -> IO ()
addConstantInput synth id = void $ memoElt synth $ do
  out <- freshNonce (synthesisGen synth)
  Sys.hPrintf (synthesisOut synth) "%d input %d @ [Integer]\n" (indexValue out) id
  return (Ref (indexValue out))

addConstantValue :: Synthesis t -> Integer -> IO ()
addConstantValue synth val =
  void $ memoConstNonce synth val $ \wireId -> do
    Sys.hPrintf (synthesisOut synth)
                "%d const @ Integer %d\n"
                (indexValue wireId)
                val
    return (Ref (indexValue wireId))

writeCircuit :: Synthesis t -> [Elt t tp] -> IO ()
writeCircuit synth es = mapM_ (eval synth) es

eval :: Synthesis t -> Elt t tp -> IO (NameType tp)
eval _ NatElt{}       = fail "Naturals not supported"
eval _ RatElt{}       = fail "Rationals not supported"
eval _ BVElt{}        = fail "BitVector not supported"
eval synth (NonceAppElt app)  = do
  memoEltNonce synth (nonceEltId app) $ do
    doNonceApp synth app
eval synth (BoundVarElt bvar) = do
  -- Bound variables should already be handled before
  -- calling eval. See `recordUninterpConstants`.
  memoEltNonce synth (bvarId bvar) $ do
    case bvarKind bvar of
      QuantifierVarKind ->
        error "Bound variable is not defined."
      LatchVarKind ->
        error "Latches are not supported in arithmetic circuits."
      UninterpVarKind ->
        error "Uninterpreted variable that was not defined."
eval synth (IntElt n _)   = Ref <$> writeConstant synth n
eval synth (AppElt a) = do
  memoEltNonce synth (eltId a) $ do
    doApp synth a

-- | Process an application term and returns the Acirc action that creates the
-- corresponding circuitry.
doApp :: Synthesis t -> AppElt t tp -> IO (NameType tp)
doApp synth ae = do
  case appEltApp ae of
    -- Internally crucible converts integers to reals. We need to
    -- undo that, as we only support integers.
    RealToInteger n -> do
      n' <- eval synth n
      return $! intToReal n' -- TODO: rename `intToReal`
    IntegerToReal n -> do
      n' <- eval synth n
      return $! IntToReal n'
    RealMul n m -> do
      -- Like the first case above, we know that for our purposes these are
      -- really computations on integers. So we do the necessary conversions
      -- here.
      IntToReal (Ref n') <- eval synth n
      IntToReal (Ref m') <- eval synth m
      let aeId = indexValue (eltId ae)
      IntToReal . Ref <$> writeMul synth aeId n' m'
    RealSum ws -> do
      -- This is by far the trickiest case.  Crucible stores sums as weighted
      -- sums. This representation is basically a set of coefficients that are
      -- meant to be multiplied with some sums.
      ws' <- WS.eval (\r1 r2 -> do
                     r1' <- r1
                     r2' <- r2
                     return $! r1' ++ r2')
                     -- coefficient case
                     (\c t -> do
                       IntToReal (Ref t') <- eval synth t
                       assert (denominator c == 1) $ do
                         -- simplify products to simple addition, when we can
                         case numerator c of
                           1  -> return [t']
                           -1 -> let Just tId = eltMaybeId t
                                 in (:[]) <$> writeNeg synth (indexValue tId) t'
                           -- Code below is for when we can support constants
                           _ -> do
                             c'    <- writeConstant synth (numerator c)
                             let Just tId = eltMaybeId t
                             (:[]) <$> writeMul synth (indexValue tId) c' t'
                         )
                     -- just a constant
                     -- TODO what's up with this error
                     (\c -> error "We cannot support raw literals"
                       -- Code below is for when we can support constants
                       -- assert (denominator c == 1) $ do
                       --   B.constant (numerator c)
                     )
                     ws
      -- ws'' <- (ws' :: IO [_])
      case ws' of
        -- Handle the degenerate sum case (eg., +x) by propagating
        -- the reference to x forward instead of the sum.
        [x] -> return (IntToReal (Ref x))
        _   -> do
          let aeId = indexValue (eltId ae)
          IntToReal . Ref <$> writeSumN synth aeId ws'
    x -> fail $ "Not supported: " ++ show x

  where
  intToReal :: NameType BaseRealType -> NameType BaseIntegerType
  intToReal (IntToReal m) = m

-- | Process an application term and returns the Acirc action that creates the
-- corresponding circuitry.
doNonceApp :: Synthesis t -> NonceAppElt t tp -> IO (NameType tp)
doNonceApp synth ae =
  case nonceEltApp ae of
    FnApp fn args -> case T.unpack (solverSymbolAsText (symFnName fn)) of
      "julia_shiftRight!" -> case symFnReturnType fn of
        BaseIntegerRepr -> do
          let sz = Ctx.size args
          case (Ctx.intIndex 0 sz, Ctx.intIndex 1 sz) of
            (Just (Some zero), Just (Some one)) -> do
              let baseArg = args Ctx.! zero
                  byArg   = args Ctx.! one
              Ref base <- eval synth baseArg
              Ref by   <- eval synth byArg
              Ref <$> writeRShift synth (indexValue (nonceEltId ae)) base by
            _ -> fail "The improbable happened: Wrong number of arguments to shift right"
        _ -> fail "The improbable happened: shift right should only return Integer type"
      x -> fail $ "Not supported: " ++ show x
    _ -> fail $ "Not supported"

-- Circuit generation functions

writeMul :: Synthesis t -> Word64 -> Word64 -> Word64 -> IO Word64
writeMul synth out in1 in2 = do
  Sys.hPrintf (synthesisOut synth) "%d * %d %d\n" out in1 in2
  return out

writeNeg :: Synthesis t -> Word64 -> Word64 -> IO Word64
writeNeg synth out ref = do
  Sys.hPrintf (synthesisOut synth) "%d - %d\n" out ref
  return out

writeSumN :: Synthesis t -> Word64 -> [Word64] -> IO Word64
writeSumN synth out args = do
  let str = show out ++ " + " ++ concatMap (\x -> show x ++ " ") args
  Sys.hPutStrLn (synthesisOut synth) str
  return out

writeRShift :: Synthesis t -> Word64 -> Word64 -> Word64 -> IO Word64
writeRShift synth out base by = do
  Sys.hPrintf (synthesisOut synth)
              "%d >> %d %d\n"
              out base by
  return out

writeConstant :: Synthesis t -> Integer -> IO Word64
writeConstant synth val = do
  Ref out <- memoConstNonce synth val $ \wireId -> do
    Sys.hPrintf (synthesisOut synth)
                "%d const @ Integer %d\n"
                (indexValue wireId) val
    return (Ref (indexValue wireId))
  return out

writeOutput :: Synthesis t -> [Word64] -> IO ()
writeOutput synth refs = do
  let str = ":output " ++ concatMap (\x -> show x ++ " ") refs
  Sys.hPutStrLn (synthesisOut synth) str