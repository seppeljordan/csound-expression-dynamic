-- | Main types
{-# Language
  DeriveFunctor
, DeriveFoldable
, DeriveTraversable
, DeriveGeneric
, TypeSynonymInstances
, FlexibleInstances
#-}
module Csound.Dynamic.Types.Exp(
    E, RatedExp(..), isEmptyExp, RatedVar, ratedVar, ratedVarRate, ratedVarId,
    ratedExp, noRate, withRate, setRate,
    Exp, toPrimOr, toPrimOrTfm, PrimOr(..), MainExp(..), Name,
    InstrId(..), intInstrId, ratioInstrId, stringInstrId,
    VarType(..), Var(..), Info(..), OpcFixity(..), Rate(..),
    Signature(..), isInfix, isPrefix,
    Prim(..), Gen(..), GenId(..),
    Inline(..), InlineExp(..), PreInline(..),
    BoolExp, CondInfo, CondOp(..), isTrue, isFalse,
    NumExp, NumOp(..), Note,
    MultiOut,
    IsArrInit, ArrSize, ArrIndex
) where

import           Control.Applicative
import           Data.Fix
import           Data.Foldable hiding (concat)
import           Data.Functor.Classes (Eq1(liftEq), Eq2(liftEq2))
import           Data.Hashable
import qualified Data.IntMap as IM
import           Data.Map (Map)
import           Data.Maybe (isNothing)
import           Data.Traversable
import           GHC.Generics (Generic)

import qualified Csound.Dynamic.Tfm.DeduceTypes as R(Var(..))

type Name = String
type LineNum = Int

-- | An instrument identifier
data InstrId
    = InstrId
    { instrIdFrac :: Maybe Int
    , instrIdCeil :: Int }
    | InstrLabel String
    deriving (Show, Eq, Ord, Generic)

-- | Constructs an instrument id with the integer.
intInstrId :: Int -> InstrId
intInstrId n = InstrId Nothing n

-- | Constructs an instrument id with fractional part.
ratioInstrId :: Int -> Int -> InstrId
ratioInstrId beforeDot afterDot = InstrId (Just $ afterDot) beforeDot

-- | Constructs an instrument id with the string label.
stringInstrId :: String -> InstrId
stringInstrId = InstrLabel

-- | The inner representation of csound expressions.
type E = Fix RatedExp

instance Hashable E where
    hashWithSalt s x = s `hashWithSalt` cata hash x

data RatedExp a = RatedExp
    { ratedExpRate      :: Maybe Rate
        -- ^ Rate (can be undefined or Nothing,
        -- it means that rate should be deduced automatically from the context)
    , ratedExpDepends   :: Maybe LineNum
        -- ^ Dependency (it is used for expressions with side effects,
        -- value contains the privious statement)
    , ratedExpExp       :: Exp a
        -- ^ Main expression
    } deriving (Show, Eq, Ord, Functor, Foldable, Traversable, Generic)

instance Eq1 RatedExp where
  liftEq comp r1 r2 =
    ratedExpRate r1 == ratedExpRate r2 &&
    ratedExpDepends r1 == ratedExpDepends r2 &&
    (liftEq (liftEq comp) (ratedExpExp r1) (ratedExpExp r2))

-- | RatedVar is for pretty printing of the wiring ports.
type RatedVar = R.Var Rate

-- | Makes an rated variable.
ratedVar :: Rate -> Int -> RatedVar
ratedVar     = flip R.Var

-- | Querries a rate.
ratedVarRate :: RatedVar -> Rate
ratedVarRate = R.varType

-- | Querries an integral identifier.
ratedVarId :: RatedVar -> Int
ratedVarId   = R.varId

ratedExp :: Maybe Rate -> Exp E -> E
ratedExp r = Fix . RatedExp r Nothing

noRate :: Exp E -> E
noRate = ratedExp Nothing

withRate :: Rate -> Exp E -> E
withRate r = ratedExp (Just r)

-- rate coversion

setRate :: Rate -> E -> E
setRate r a = Fix $ (\x -> x { ratedExpRate = Just r }) $ unFix a

-- | It's a primitive value or something else. It's used for inlining
-- of the constants (primitive values).
newtype PrimOr a = PrimOr { unPrimOr :: Either Prim a }
    deriving (Show, Eq, Ord, Functor, Generic)

instance Eq1 PrimOr where
  liftEq comp (PrimOr x) (PrimOr y) = liftEq comp x y

-- | Constructs PrimOr values from the expressions. It does inlining in
-- case of primitive values.
toPrimOr :: E -> PrimOr E
toPrimOr a = PrimOr $ case ratedExpExp $ unFix a of
    ExpPrim (PString _) -> Right a
    ExpPrim p  -> Left p
    ReadVar v | noDeps -> Left (PrimVar (varRate v) v)
    _         -> Right a
    where
        noDeps = isNothing $ ratedExpDepends $ unFix a

-- | Constructs PrimOr values from the expressions. It does inlining in
-- case of primitive values.
toPrimOrTfm :: Rate -> E -> PrimOr E
toPrimOrTfm r a = PrimOr $ case ratedExpExp $ unFix a of
    ExpPrim (PString _) -> Right a
    ExpPrim p | (r == Ir || r == Sr) -> Left p
    ReadVar v | noDeps -> Left (PrimVar (varRate v) v)
    _         -> Right a
    where
        noDeps = isNothing $ ratedExpDepends $ unFix a


-- Expressions with inlining.
type Exp a = MainExp (PrimOr a)

-- Csound expressions
data MainExp a
    = EmptyExp
    -- | Primitives
    | ExpPrim Prim
    -- | Application of the opcode: we have opcode information (Info) and the arguments [a]
    | Tfm Info [a]
    -- | Rate conversion
    | ConvertRate Rate Rate a
    -- | Selects a cell from the tuple, here argument is always a tuple (result of opcode that returns several outputs)
    | Select Rate Int a
    -- | if-then-else
    | If (CondInfo a) a a
    -- | Boolean expressions (rendered in infix notation in the Csound)
    | ExpBool (BoolExp a)
    -- | Numerical expressions (rendered in infix notation in the Csound)
    | ExpNum (NumExp a)
    -- | Reading/writing a named variable
    | InitVar Var a
    | ReadVar Var
    | WriteVar Var a
    -- | Arrays
    | InitArr Var (ArrSize a)
    | ReadArr Var (ArrIndex a)
    | WriteArr Var (ArrIndex a) a
    | WriteInitArr Var (ArrIndex a) a
    | TfmArr IsArrInit Var Info [a]
    -- | Imperative If-then-else
    | IfBegin Rate (CondInfo a)
--  | ElseIfBegin (CondInfo a) -- It's expressed with nested if-else
    | ElseBegin
    | IfEnd
    -- | looping constructions
    | UntilBegin (CondInfo a)
    | UntilEnd
    | WhileBegin (CondInfo a)
    | WhileRefBegin Var
    | WhileEnd
    -- | Verbatim stmt
    | Verbatim String
    -- | Dependency tracking
    | Starts
    | Seq a a
    | Ends a
    -- | read macros arguments
    | InitMacrosInt String Int
    | InitMacrosDouble String Double
    | InitMacrosString String String
    | ReadMacrosInt String
    | ReadMacrosDouble String
    | ReadMacrosString String
    deriving (Show, Eq, Ord, Functor, Foldable, Traversable, Generic)

expEq1 :: (a -> b -> Bool) -> MainExp a -> MainExp b -> Bool
expEq1 _ EmptyExp EmptyExp = True
expEq1 _ (InitMacrosInt s1 i1) (InitMacrosInt s2 i2) = s1 == s2 && i1 == i2
expEq1 _ (ExpPrim p1) (ExpPrim p2) = p1 == p2
expEq1 comp (Tfm i1 xs1) (Tfm i2 xs2) = i1 == i2 && liftEq comp xs1 xs2
expEq1 comp (ConvertRate a1 b1 c1) (ConvertRate a2 b2 c2) =
  a1 == a2 && b1 == b2 && comp c1 c2
expEq1 comp (Select r1 i1 x1) (Select r2 i2 x2) =
  r1 == r2 && i1 == i2 && comp x1 x2
expEq1 comp (If i1 x1 y1) (If i2 x2 y2) =
  liftEq comp i1 i2 && comp x1 x2 && comp y1 y2
expEq1 comp (ExpBool b1) (ExpBool b2) =
  liftEq comp b1 b2
expEq1 comp (ExpNum n1) (ExpNum n2) =
  liftEq comp n1 n2
expEq1 comp (InitVar v1 x1) (InitVar v2 x2) =
  v1 == v2 && comp x1 x2
expEq1 _ (ReadVar x) (ReadVar y) = x == y
expEq1 comp (WriteVar v1 x1) (WriteVar v2 x2) =
  v1 == v2 && comp x1 x2
expEq1 comp (InitArr v1 size1) (InitArr v2 size2) =
  v1 == v2 && liftEq comp size1 size2
expEq1 comp (ReadArr v1 index1) (ReadArr v2 index2) =
  v1 == v2 && liftEq comp index1 index2
expEq1 comp (WriteArr v1 index1 x1) (WriteArr v2 index2 x2) =
  v1 == v2 && comp x1 x2 && liftEq comp index1 index2
expEq1 comp (WriteInitArr v1 index1 x1) (WriteInitArr v2 index2 x2) =
  v1 == v2 && comp x1 x2 && liftEq comp index1 index2
expEq1 comp (TfmArr i1 v1 info1 xs1) (TfmArr i2 v2 info2 xs2) =
  i1 == i2 && v1 == v2 && info1 == info2 && liftEq comp xs1 xs2
expEq1 comp (IfBegin r1 cond1) (IfBegin r2 cond2) =
  r1 == r2 && liftEq comp cond1 cond2
expEq1 _ ElseBegin ElseBegin = True
expEq1 _ IfEnd IfEnd = True
expEq1 comp (UntilBegin c1) (UntilBegin c2) = liftEq comp c1 c2
expEq1 _ UntilEnd UntilEnd = True
expEq1 comp (WhileBegin c1) (WhileBegin c2) = liftEq comp c1 c2
expEq1 _ (WhileRefBegin v1) (WhileRefBegin v2) = v1 == v2
expEq1 _ WhileEnd WhileEnd = True
expEq1 _ (Verbatim x) (Verbatim y) = x == y
expEq1 _ Starts Starts = True
expEq1 comp (Seq x1 y1) (Seq x2 y2) =
  comp x1 x2 && comp y1 y2
expEq1 comp (Ends x) (Ends y) = comp x y
expEq1 _ (InitMacrosDouble s1 d1) (InitMacrosDouble s2 d2) =
  d1 == d2 && s1 == s2
expEq1 _ (InitMacrosString x1 y1) (InitMacrosString x2 y2) =
  x1 == x2 && y1 == y2
expEq1 _ (ReadMacrosInt s1) (ReadMacrosInt s2) = s1 == s2
expEq1 _ (ReadMacrosDouble s1) (ReadMacrosDouble s2) = s1 == s2
expEq1 _ (ReadMacrosString s1) (ReadMacrosString s2) = s1 == s2
expEq1 _ _ _ = False


instance Eq1 MainExp where
  liftEq = expEq1


type IsArrInit = Bool
type ArrSize a = [a]
type ArrIndex a = [a]

isEmptyExp :: E -> Bool
isEmptyExp e = isNothing (ratedExpDepends re) && (ratedExpExp re == EmptyExp)
    where re = unFix e

-- Named variable
data Var
    = Var
        { varType :: VarType    -- global / local
        , varRate :: Rate
        , varName :: Name }
    | VarVerbatim
        { varRate :: Rate
        , varName :: Name
        } deriving (Show, Eq, Ord, Generic)

-- Variables can be global (then we have to prefix them with `g` in the rendering) or local.
data VarType = LocalVar | GlobalVar
    deriving (Show, Eq, Ord, Generic)

-- Opcode information.
data Info = Info
    -- Opcode name
    { infoName          :: Name
    -- Opcode type signature
    , infoSignature     :: Signature
    -- Opcode can be infix or prefix
    , infoOpcFixity     :: OpcFixity
    } deriving (Show, Eq, Ord, Generic)

isPrefix, isInfix :: Info -> Bool

isPrefix = (Prefix ==) . infoOpcFixity
isInfix  = (Infix  ==) . infoOpcFixity

-- Opcode fixity
data OpcFixity = Prefix | Infix | Opcode
    deriving (Show, Eq, Ord, Generic)

-- | The Csound rates.
data Rate   -- rate:
    ----------------------------
    = Xr    -- audio or control (and I use it for opcodes that produce no output, ie procedures)
    | Ar    -- audio
    | Kr    -- control
    | Ir    -- init (constants)
    | Sr    -- strings
    | Fr    -- spectrum (for pvs opcodes)
    | Wr    -- special spectrum
    | Tvar  -- I don't understand what it is (fix me) used with Fr
    deriving (Show, Eq, Ord, Enum, Bounded, Generic)

-- Opcode type signature. Opcodes can produce single output (SingleRate) or multiple outputs (MultiRate).
-- In Csound opcodes are often have several signatures. That is one opcode name can produce signals of the
-- different rate (it depends on the type of the outputs). Here we assume (to make things easier) that
-- opcodes that MultiRate-opcodes can produce only the arguments of the same type.
data Signature
    -- For SingleRate-opcodes type signature is the Map from output rate to the rate of the arguments.
    -- With it we can deduce the type of the argument from the type of the output.
    = SingleRate (Map Rate [Rate])
    -- For MultiRate-opcodes Map degenerates to the singleton. We have only one link.
    -- It contains rates for outputs and inputs.
    | MultiRate
        { outMultiRate :: [Rate]
        , inMultiRate  :: [Rate] }
    deriving (Show, Eq, Ord)

instance Hashable Signature where
    hashWithSalt s x = case x of
        SingleRate m -> s `hashWithSalt` (0 :: Int) `hashWithSalt` (hash $ fmap (\b -> (take 5 b)) $ head' $ toList m)
        MultiRate a b -> s `hashWithSalt` (1 :: Int) `hashWithSalt` (hash $ take 5 a) `hashWithSalt` (hash $ take 5 b)
        where
            head' xs = case xs of
                [] -> Nothing
                x:_ -> Just x

-- Primitive values
data Prim
    -- instrument p-arguments
    = P Int
    | PString Int       -- >> p-string (read p-string notes at the bottom of the file):
    | PrimInt Int
    | PrimDouble Double
    | PrimString String
    | PrimInstrId InstrId
    | PrimVar
        { primVarTargetRate :: Rate
        , primVar           :: Var }
    deriving (Show, Eq, Ord, Generic)

-- Gen routine.
data Gen = Gen
    { genSize    :: Int
    , genId      :: GenId
    , genArgs    :: [Double]
    , genFile    :: Maybe String
    } deriving (Show, Eq, Ord, Generic)

data GenId = IntGenId Int | StringGenId String
    deriving (Show, Eq, Ord, Generic)

-- Csound note
type Note = [Prim]

------------------------------------------------------------
-- types for arithmetic and boolean expressions

data Inline a b = Inline
    { inlineExp :: InlineExp a
    , inlineEnv :: IM.IntMap b
    } deriving (Show, Eq, Ord, Functor, Foldable, Traversable)

instance Eq2 Inline where
  liftEq2 expComp envComp x y =
    liftEq expComp (inlineExp x) (inlineExp y) &&
    liftEq (liftEq envComp)
      (IM.toAscList (inlineEnv x))
      (IM.toAscList (inlineEnv y))

instance (Eq a) => Eq1 (Inline a) where
  liftEq = liftEq2 (==)

instance (Hashable a, Hashable b) => Hashable (Inline a b) where
    hashWithSalt s (Inline a m) = s `hashWithSalt` (hash a) `hashWithSalt` (hash $ IM.toList m)

-- Inlined expression.
data InlineExp a
    = InlinePrim Int
    | InlineExp a [InlineExp a]
    deriving (Show, Eq, Ord, Generic)

instance Eq1 InlineExp where
  liftEq _ (InlinePrim a) (InlinePrim b) = a == b
  liftEq comp (InlineExp x xs) (InlineExp y ys) =
    comp x y && liftEq (liftEq comp) xs ys
  liftEq _ _ _ = False

-- Expression as a tree (to be inlined)
data PreInline a b = PreInline a [b]
    deriving (Show, Eq, Ord, Functor, Foldable, Traversable, Generic)

instance Eq2 PreInline where
  liftEq2 compFirst compSecond
      (PreInline first1 seconds1) (PreInline first2 seconds2) =
    compFirst first1 first2 &&
    liftEq compSecond seconds1 seconds2

instance (Eq a) => Eq1 (PreInline a) where
  liftEq = liftEq2 (==)

-- booleans

type BoolExp a = PreInline CondOp a
type CondInfo a = Inline CondOp a

-- Conditional operators
data CondOp
    = TrueOp | FalseOp | And | Or
    | Equals | NotEquals | Less | Greater | LessEquals | GreaterEquals
    deriving (Show, Eq, Ord, Generic)

isTrue, isFalse :: CondInfo a -> Bool

isTrue  = isCondOp TrueOp
isFalse = isCondOp FalseOp

isCondOp :: CondOp -> CondInfo a -> Bool
isCondOp op = maybe False (op == ) . getCondInfoOp

getCondInfoOp :: CondInfo a -> Maybe CondOp
getCondInfoOp x = case inlineExp x of
    InlineExp op _ -> Just op
    _ -> Nothing

-- Numeric expressions (or Csound infix operators)

type NumExp a = PreInline NumOp a

data NumOp = Add | Sub | Neg | Mul | Div | Pow | Mod
    deriving (Show, Eq, Ord, Generic)

-------------------------------------------------------
-- instances for cse that ghc was not able to derive for me

instance Foldable PrimOr where foldMap = foldMapDefault

instance Traversable PrimOr where
    traverse f x = case unPrimOr x of
        Left  p -> pure $ PrimOr $ Left p
        Right a -> PrimOr . Right <$> f a

----------------------------------------------------------

-- | Multiple output. Specify the number of outputs to get the result.
type MultiOut a = Int -> a


------------------------------------------------------
-- hashable instances

instance (Hashable a, Hashable b) => Hashable (PreInline a b)
instance (Hashable a) => Hashable (InlineExp a)
instance Hashable CondOp
instance Hashable NumOp

instance Hashable Gen
instance Hashable GenId
instance Hashable Prim
instance Hashable Rate

instance Hashable OpcFixity
instance Hashable Info
instance Hashable VarType
instance Hashable Var

instance Hashable a => Hashable (MainExp a)
instance Hashable a => Hashable (PrimOr a)
instance Hashable a => Hashable (RatedExp a)
instance Hashable InstrId

--------------------------------------------------------------
-- comments
--
-- p-string
--
--    separate p-param for strings (we need it to read strings from global table)
--    Csound doesn't permits us to use more than four string params so we need to
--    keep strings in the global table and use `strget` to read them
