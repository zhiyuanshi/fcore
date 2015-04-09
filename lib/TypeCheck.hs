{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -Wall #-}
{- |
Module      :  TypeCheck
Description :  Type checker for the source language.
Copyright   :  (c) 2014—2015 The F2J Project Developers (given in AUTHORS.txt)
License     :  BSD3

Maintainer  :  Zhiyuan Shi <zhiyuan.shi@gmail.com>, Weixin Zhang <zhangweixinxd@gmail.com>
Stability   :  experimental
Portability :  portable
-}

{- We make typechecking (this file) happen before desugaring (Desugar.hs) so that
the error messages presented to the programmer can be clearer. However, an
undesired consequence of such approach for the compiler implementer is that the
implementation of the typing rules does not follow strictly the formalization.
For instance, in the formalization there is no rule for handling multi-field
records as they are desugared into intersections of single-field records first.
But here we have to handle such cases.-}

module TypeCheck
  ( typeCheck

  -- For REPL
  , typeCheckWithEnv
  , mkInitTcEnvWithEnv
  , TypeError
  ) where

import Src
import SrcLoc

import IOEnv
import JavaUtils
import PrettyUtils
import JvmTypeQuery
import Panic
import StringPrefixes

import Text.PrettyPrint.ANSI.Leijen

import System.IO
import System.Process

import Control.Monad.Error

import Data.Maybe (fromMaybe, isJust, fromJust)
import qualified Data.Map  as Map
import qualified Data.Set  as Set
import Data.List (intersperse, findIndex)

import Prelude hiding (pred)

type Connection = (Handle, Handle)

typeCheck :: ReaderExpr -> IO (Either LTypeErrorExpr (Type, CheckedExpr))
-- type_server is (Handle, Handle)
typeCheck e = withTypeServer (\type_server ->
  (evalIOEnv (mkInitTcEnv type_server) . runErrorT . infer) e)

-- Temporary hack for REPL
typeCheckWithEnv :: ValueContext -> ReaderExpr -> IO (Either LTypeErrorExpr (Type, CheckedExpr))
-- type_server is (Handle, Handle)
typeCheckWithEnv value_ctxt e = withTypeServer (\type_server ->
  (evalIOEnv (mkInitTcEnvWithEnv value_ctxt type_server) . runErrorT . infer) e)

withTypeServer :: (Connection -> IO a) -> IO a
withTypeServer do_this =
  do cp <- getClassPath
     let p = (proc "java" ["-cp", cp, namespace ++ "TypeServer"])
               { std_in = CreatePipe, std_out = CreatePipe }
     (Just inp, Just out, _, proch) <- createProcess p
     hSetBuffering inp NoBuffering
     hSetBuffering out NoBuffering
     res <- do_this (inp, out)
     terminateProcess proch
     return res

data TcEnv
  = TcEnv
  { tceTypeContext     :: TypeContext
  , tceValueContext    :: ValueContext
  , tceTypeserver   :: Connection
  , tceMemoizedJavaClasses :: Set.Set ClassName -- Memoized Java class names
  }

mkInitTcEnv :: Connection -> TcEnv
mkInitTcEnv type_server
  = TcEnv
  { tceTypeContext     = Map.empty
  , tceValueContext    = Map.empty
  , tceTypeserver   = type_server
  , tceMemoizedJavaClasses = Set.empty
  }

-- Temporary hack for REPL
mkInitTcEnvWithEnv :: ValueContext -> Connection -> TcEnv
mkInitTcEnvWithEnv value_ctxt type_server
  = TcEnv
  { tceTypeContext     = Map.empty
  , tceValueContext    = value_ctxt
  , tceTypeserver   = type_server
  , tceMemoizedJavaClasses = Set.empty
  }

data TypeError
  = General Doc
  | DuplicateParam Name
  | ExpectJClass
  | IndexTooLarge
  | TypeMismatch Type Type
  | KindMismatch Kind Kind Type
  | MissingTyAscription Name
  | NotInScope Name
  | ProjectionOfNonProduct
  | NotWellKinded Type
  | NotMember Name Type
  | NotAFunction Type

  -- Java-specific type errors
  | NoSuchClass       ClassName
  | NoSuchConstructor ClassName [ClassName]
  | NoSuchMethod      (JCallee ClassName) MethodName [ClassName]
  | NoSuchField       (JCallee ClassName) FieldName
  deriving (Show)

type LTypeErrorExpr = Located (TypeError, Maybe ReaderExpr)

instance Error LTypeErrorExpr where

instance Pretty LTypeErrorExpr where
    pretty (L loc (err, expr)) =
        case expr of
          Nothing -> pretty loc <> pretty err
          Just expr -> pretty loc <$> pretty err <$> text "In the expression" <> colon <+> pretty expr

instance Pretty TypeError where
  pretty (General doc)      = prettyError <+> doc
  pretty (NotInScope x)  = prettyError <+> code (text x) <+> text "is not in scope"
  pretty (DuplicateParam ident) = prettyError <+> text "duplicate parameter" <+> code (text ident)
  pretty (NotWellKinded t)  = prettyError <+> code (pretty t) <+> text "is not well-kinded"
  pretty (KindMismatch expected found t) =
    prettyError <+> text "kind mismatch" <> colon <$>
    indent 2 (text "expected" <+> code (pretty expected) <> comma <$>
              text "   found" <+> code (pretty found)) <$>
    text "in the type" <> colon <+> pretty t

  pretty (TypeMismatch expected found) =
    prettyError <+> text "type mismatch" <> colon <$>
    indent 2 (text "expected" <+> code (pretty expected) <> comma <$>
              text "   found" <+> code (pretty found))
  pretty (NoSuchClass c)  = prettyError <+> text "no such class:" <+> code (text c)
  pretty (NotMember x t)  = prettyError <+> code (text x) <+> text "is not a member of the type" <+> code (pretty t)
  pretty (NotAFunction t) = prettyError <+> code (pretty t) <+> text "is not a function; it cannot be applied"

  -- Java-specific type errors
  pretty (NoSuchMethod (NonStatic c) m cs) =
    prettyError <+> text "no such method" <+> code (text m) <+>
    text "on" <+> code (pretty (JType (JClass c))) <+>
    text "with parameters of type" <+> commas (map (code . pretty . JType . JClass) cs)
  pretty (NoSuchMethod (Static c) m cs) =
    prettyError <+> text "no such static method" <+> code (text m) <+>
    text "on" <+> code (pretty (JType (JClass c))) <+>
    text "with parameters of type" <+> commas (map (code . pretty . JType . JClass) cs)

  pretty (NoSuchField (NonStatic c) f) =
    prettyError <+> text "no such field" <+> code (text f) <+>
    text "on" <+> code (pretty (JType (JClass c)))
  pretty (NoSuchField (Static c) f) =
    prettyError <+> text "no such static field" <+> code (text f) <+>
    text "on" <+> code (pretty (JType (JClass c)))

  pretty (MissingTyAscription ident) =
    prettyError <+> text "recursive definition" <+> code (text ident) <+>
    text "needs type ascription for the right-hand side"

  pretty e = prettyError <+> text (show e)

instance Error TypeError where
  -- strMsg

type Checker a = ErrorT LTypeErrorExpr (IOEnv TcEnv) a

getTcEnv :: Checker TcEnv
getTcEnv = lift getEnv

setTcEnv :: TcEnv -> Checker ()
setTcEnv tc_env = lift $ setEnv tc_env

getTypeContext :: Checker TypeContext
getTypeContext = liftM tceTypeContext getTcEnv

getValueContext :: Checker ValueContext
getValueContext = liftM tceValueContext getTcEnv

getTypeServer :: Checker (Handle, Handle)
getTypeServer = liftM tceTypeserver getTcEnv

getMemoizedJavaClasses :: Checker (Set.Set ClassName)
getMemoizedJavaClasses = liftM tceMemoizedJavaClasses getTcEnv

memoizeJavaClass :: ClassName -> Checker ()
memoizeJavaClass c
  = do TcEnv{..} <- getTcEnv
       memoized_java_classes <- getMemoizedJavaClasses
       setTcEnv TcEnv{ tceMemoizedJavaClasses = c `Set.insert` memoized_java_classes, ..}

withLocalTVars :: [(ReaderId, (Kind, TypeValue))] -> Checker a -> Checker a
withLocalTVars tvars do_this
  = do delta <- getTypeContext
       let delta' = Map.fromList tvars `Map.union` delta
                -- `Map.fromList` is right-biased and `Map.union` is left-biased.
       TcEnv {..} <- getTcEnv
       setTcEnv TcEnv { tceTypeContext = delta', ..}
       r <- do_this
       TcEnv {..} <- getTcEnv
       setTcEnv TcEnv { tceTypeContext = delta, ..}
       return r

withLocalVars :: [(ReaderId, Type)]-> Checker a -> Checker a
withLocalVars vars do_this
  = do gamma <- getValueContext
       let gamma' = Map.fromList vars `Map.union` gamma
                -- `Map.fromList` is right-biased and `Map.union` is left-biased.
       TcEnv {..} <- getTcEnv
       setTcEnv TcEnv { tceValueContext = gamma', ..}
       r <- do_this
       TcEnv {..} <- getTcEnv
       setTcEnv TcEnv { tceValueContext = gamma, ..}
       return r

type TypeSubstitution = Map.Map Name Type

applyTSubst :: TypeSubstitution -> Type -> Type
applyTSubst s (TVar a)     = fromMaybe (TVar a) (Map.lookup a s)
-- applyTSubst _ (JClass c)   = JClass c
applyTSubst _ (JType c)    = JType c
applyTSubst s (Fun t1 t2)  = Fun (applyTSubst s t1) (applyTSubst s t2)
applyTSubst s (Forall a t) = Forall a (applyTSubst s' t) where s' = Map.delete a s
applyTSubst _ _            = sorry "TypeCheck.applyTSubst"

-- | Kinding.
kind :: TypeContext -> Type -> IO (Maybe Kind)
kind d (TVar a)     = case Map.lookup a d of Nothing     -> return Nothing
                                             Just (k, _) -> return (Just k)
kind _  Unit        = return (Just Star)
kind d (Fun t1 t2)  = justStarIffAllHaveKindStar d [t1, t2]
kind d (Forall a t) = kind d' t where d' = Map.insert a (Star, TerminalType) d
kind d (Product ts) = justStarIffAllHaveKindStar d ts
kind d (RecordType fs)  = justStarIffAllHaveKindStar d (map snd fs)
kind d (ListOf t)   = kind d t
kind d (And t1 t2)  = justStarIffAllHaveKindStar d [t1, t2]
kind d (Thunk t)    = kind d t

-- Δ,x::* ⊢ t :: k
-- -------------------- (K-Abs) Restriction compared to F_omega: x can only have kind *
-- Δ ⊢ λx. t :: * => k
kind d (OpAbs x t) = do
  maybe_k <- kind (Map.insert x (Star, TerminalType) d) t
  case maybe_k of
    Nothing -> return Nothing
    Just k  -> return $ Just (KArrow Star k)

-- Δ ⊢ t1 :: k11 => k12  Δ ⊢ t2 :: k11
-- ------------------------------------ (K-App)
-- Δ ⊢ t1 t2 :: k12
kind d (OpApp t1 t2) = do
  maybe_k1 <- kind d t1
  maybe_k2 <- kind d t2
  case (maybe_k1, maybe_k2) of
    (Just (KArrow k11 k12), Just k2) | k2 == k11 -> return (Just k12)
    _ -> return Nothing

kind _ t = return (Just Star) -- TODO

justStarIffAllHaveKindStar :: TypeContext -> [Type] -> IO (Maybe Kind)
justStarIffAllHaveKindStar d ts
  = do ps <- mapM (hasKindStar d) ts
       if and ps
          then return (Just Star)
          else return Nothing

hasKindStar :: TypeContext -> Type -> IO Bool
hasKindStar d t
  = do k <- kind d t
       return (k == Just Star)

-- | Typing.
infer :: ReaderExpr -> Checker (Type, CheckedExpr)
infer e@(L loc (Var name))
  = do value_ctxt <- getValueContext
       case Map.lookup name value_ctxt of
         Just t  -> return (t, L loc $ Var (name,t))
         Nothing -> throwError (NotInScope name `withExpr` e)

infer (L loc (Lit lit)) = return (srcLitType lit, L loc $ Lit lit)

infer (L loc (Lam (x1,t1) e))
  = do checkType t1
       d <- getTypeContext
       let t1' = expandType d t1
       (t', e') <- withLocalVars [(x1,t1')] (infer e)
       return (Fun t1' t', L loc $ Lam (x1,t1') e')

infer (L _ (App e1 e2)) =
  do (t1, e1') <- infer e1
     (t2, e2') <- infer e2

     case e1' of
       L loc (Constr (Constructor n ts) es) ->
           case t1 of
             Fun t11 t12 ->
                 do d <- getTypeContext
                    unless (subtype d t2 t11) $ throwError (TypeMismatch t11 t2 `withExpr` e2)
                    return (t12, L loc $ Constr (Constructor n ts) (es ++ [e2']))
             _ -> throwError (NotAFunction t1 `withExpr` e1)
       _ ->
        case t1 of
          -- Local type inference:
          -- `f [T] e` can be written as `f e` if the type of e is just T.
          Forall _ _ -> infer (App (TApp e1 t2 `withLoc` e1) e2 `withLoc` e1)

          Fun t11 t12 ->
            do d <- getTypeContext
               unless (subtype d t2 t11) $ throwError (TypeMismatch t11 t2 `withExpr` e2)
               case (t11, t2) of
                 (Thunk _, Thunk _) -> return (t12, App e1' e2' `withLoc` e1')
                 (Thunk _, _)       -> return (t12, App e1' (Lam ("_", Unit) e2' `withLoc` e2') `withLoc` e1')
                 (_, Thunk _)       -> return (t12, App e1' (App e2' (noLoc $ Lit UnitLit) `withLoc` e2') `withLoc` e1')
                 (_, _)             -> return (t12, App e1' e2' `withLoc` e1')

          Thunk (Fun t11 t12) ->
            do d <- getTypeContext
               unless (subtype d t2 t11) $ throwError (TypeMismatch t11 t2 `withExpr` e2)
               case (t11, t2) of
                 (Thunk _, Thunk _) -> return (t12, App e1' e2' `withLoc` e1')
                 (Thunk _, _)       -> return (t12, App e1' (Lam ("_", Unit) e2' `withLoc` e2') `withLoc` e1')
                 (_, Thunk _)       -> return (t12, App e1' (App e2' (noLoc $ Lit UnitLit) `withLoc` e2') `withLoc` e1')
                 (_, _)             -> return (t12, App e1' e2' `withLoc` e1')

          _ -> throwError (NotAFunction t1 `withExpr` e1)

infer (L loc (BLam a e))
  = do (t, e') <- withLocalTVars [(a, (Star, TerminalType))] (infer e)
       return (Forall a t, L loc $ BLam a e')

infer (L loc (TApp e arg))
  = do (t, e') <- infer e
       checkType arg
       d <- getTypeContext
       let arg' = expandType d arg
       case t of
         Forall a t1 -> let t' = fsubstTT (a, arg') t1
                        in case e' of
                             L loc' (Constr (Constructor n _) es) ->
                               case t' of
                                 Forall _ _ -> return (t', e')
                                 _ -> return (t', L loc' $ Constr (Constructor n (unwrapFun t')) es) -- all type parameters instantiated
                             _ -> return (t', L loc $ TApp e' arg')
         _           -> sorry "TypeCheck.infer: TApp"

infer (L loc (Tuple es))
  | length es < 2 = panic "Src.TypeCheck.infer: Tuple: fewer than two items"
  | otherwise     = do (ts, es') <- mapAndUnzipM infer es
                       return (Product ts, L loc $ Tuple es')

infer expr@(L loc (Proj e i))
  = do (t, e') <- infer e
       case t of
         Product ts
           | 1 <= i && i <= length ts -> return (ts !! (i - 1), L loc $ Proj e' i)
           | otherwise -> throwError $ IndexTooLarge `withExpr` expr
         _ -> throwError $ ProjectionOfNonProduct `withExpr` e

infer (L loc (PrimOp e1 op e2)) =
  case op of
    Arith _ ->
      do (_, e1') <- inferAgainst e1 (JType (JClass "java.lang.Integer"))
         (_, e2') <- inferAgainst e2 (JType (JClass "java.lang.Integer"))
         return (JType (JClass "java.lang.Integer"), L loc $ PrimOp e1' op e2')
    Compare _ ->
      do (t1, e1') <- infer e1
         (_ , e2') <- inferAgainst e2 t1
         return (JType (JClass "java.lang.Boolean"), L loc $ PrimOp e1' op e2')
    Logic _ ->
      do (_, e1') <- inferAgainst e1 (JType (JClass "java.lang.Boolean"))
         (_, e2') <- inferAgainst e2 (JType (JClass "java.lang.Boolean"))
         return (JType (JClass "java.lang.Boolean"), L loc $ PrimOp e1' op e2')

infer (L loc (If e1 e2 e3))
  = do (_, e1')  <- inferAgainst e1 (JType (JClass "java.lang.Boolean"))
       (t2, e2') <- infer e2
       (t3, e3') <- infer e3
       d <- getTypeContext
       return (fromMaybe (panic message) (leastUpperBound d t2 t3), L loc $ If e1' e2' e3')
  where
    message = "infer: least upper bound of types of two branches does not exist"

infer (L loc (Let rec_flag binds e)) =
  do checkDupNames (map bindId binds)
     binds' <- case rec_flag of
                 NonRec -> mapM normalizeBind binds
                 Rec    -> do sigs <- collectBindIdSigs binds
                              withLocalVars sigs (mapM normalizeBind binds)
     (t, e') <- withLocalVars (map (\ (f,t,_) -> (f,t)) binds') (infer e)
     return (t, L loc $ LetOut rec_flag binds' e')

infer (L loc LetOut{..}) = panic "TypeCheck.infer: LetOut"

--  Case           Possible interpretations
--  ---------------------------------------
--  e.x            Field access, record elim
--  e.x ( )        Method invocation
--  e.x ()         Method invocation, application (of a unit lit)
--  e.x (g y)      Method invocation, application
--  e.x (g y,...)  Method invocation, application (of a tuple)

-- In all the cases of application except the first, it is impossible for `e.x`
-- to be a field access since field accesses cannot return something that
-- accepts a value as its argument (But with Java 8 lambdas? TODO.). So `e.x`
-- can only be a method invocation.

-- e.x
infer (L loc (Dot e x Nothing)) =
  do (t, _) <- infer e
     case deThunkOnce t of
       JType (JClass _) -> infer (L loc $ JField (NonStatic e) x undefined)
       RecordType _     -> infer (L loc $ RecordProj e x)
       And _ _          -> infer (L loc $ RecordProj e x)
       _                -> throwError (NotMember x t `withExpr` e) -- TODO: should be x's loc

-- e.x ( )
infer (L loc (Dot e x (Just ([], UnitImpossible)))) =
  do (t, _) <- infer e
     case deThunkOnce t of
       JType (JClass _) -> infer (L loc $ JMethod (NonStatic e) x [] undefined)
       _                -> throwError (NotMember x t `withExpr` e) -- TODO: should be x's loc

-- e.x ()
infer (L loc (Dot e x (Just ([], UnitPossible)))) =
  do (t, _) <- infer e
     case deThunkOnce t of
       JType (JClass _) -> infer (L loc $ JMethod (NonStatic e) x [] undefined)
       RecordType _     -> infer (L loc $ App (L loc $ RecordProj e x) (noLoc $ Lit UnitLit))
       And _ _          -> infer (L loc $ App (L loc $ RecordProj e x) (noLoc $ Lit UnitLit))
       _                -> throwError (NotMember x t `withExpr` e) -- TODO: should be x's loc

-- e.x (a)
infer (L loc (Dot e x (Just ([arg], _)))) =
  do (t, _) <- infer e
     case deThunkOnce t of
       JType (JClass _) -> infer (L loc $ JMethod (NonStatic e) x [arg] undefined)
       RecordType _     -> infer (L loc $ App (L loc $ RecordProj e x) arg)
       And _ _          -> infer (L loc $ App (L loc $ RecordProj e x) arg)
       _                -> throwError (NotMember x t `withExpr` e) -- TODO: should be x's loc

-- e.x (a,...)
infer (L loc (Dot e x (Just (args, _)))) =
  do (t, _) <- infer e
     case deThunkOnce t of
       JType (JClass _) -> infer (L loc $ JMethod (NonStatic e) x args undefined)
       RecordType _     -> infer (L loc $ App (L loc $ RecordProj e x) tuple)
       And _ _          -> infer (L loc $ App (L loc $ RecordProj e x) tuple)
       _                -> throwError (NotMember x t `withExpr` e) -- TODO: should be x's loc
    where tuple = Tuple args `withLocs` args

-- JNew, JMethod, and JField

infer (L loc (JNew c args))
  = do checkClassName c
       (arg_cs, args') <- mapAndUnzipM inferAgainstAnyJClass args
       checkConstruction c arg_cs
       return (JType (JClass c), L loc $ JNew c args')

infer (L loc (JMethod callee m args _)) =
  case callee of
    Static c ->
      do (arg_cs, args') <- mapAndUnzipM inferAgainstAnyJClass args
         ret_c <- checkMethodCall (Static c) m arg_cs
         let ret_type = case ret_c of "java.lang.Void" -> Unit
                                      -- "char" -> JType (JPrim "char")
                                      _ -> JType (JClass ret_c)
         return (ret_type, L loc $ JMethod (Static c) m args' ret_c)
    NonStatic e ->
      do (c, e')         <- inferAgainstAnyJClass e
         (arg_cs, args') <- mapAndUnzipM inferAgainstAnyJClass args
         ret_c <- checkMethodCall (NonStatic c) m arg_cs
         let ret_type = case ret_c of "java.lang.Void" -> Unit
                                      -- "char" -> JType (JPrim "char")
                                      _ -> JType (JClass ret_c)
         return (ret_type, L loc $ JMethod (NonStatic e') m args' ret_c)

infer (L loc (JField callee f _)) =
  case callee of
    Static c ->
      do ret_c <- checkFieldAccess (Static c) f
         return (JType (JClass ret_c), L loc $ JField (Static c) f ret_c)
         -- if ret_c == "char"
         --    then return (JType (JPrim ret_c), JField (Static c) f ret_c)
         --    else return (JType (JClass ret_c), JField (Static c) f ret_c)
    NonStatic e ->
      do (t, e') <- infer e
         case t of
           JType (JClass c) ->
             do ret_c   <- checkFieldAccess (NonStatic c) f
                return (JType (JClass ret_c), JField (NonStatic e') f ret_c `withLoc` e')
                -- if ret_c == "char"
                --   then return (JType (JPrim "char"), JField (NonStatic e') f ret_c)
                --   else return (JType (JClass ret_c), JField (NonStatic e') f ret_c)
           _ -> throwError (NotMember f t `withExpr` e) -- TODO: should be f's loc

infer (L loc (Seq es)) =
  do (ts, es') <- mapAndUnzipM infer es
     return (last ts, Seq es' `withLocs` es')

infer (L loc (Merge e1 e2)) =
  do (t1, e1') <- infer e1
     (t2, e2') <- infer e2
     return (And t1 t2, Merge e1' e2' `withLoc` e1')

infer (L loc (PolyList l t)) =
  do (ts, es) <- mapAndUnzipM infer l
     case ts of [] -> return (ListOf t, PolyList es t `withLocs` es)
                _  ->
                     do d <- getTypeContext
                        case findIndex (not . compatible d t) ts of
                          Nothing -> return (ListOf t, PolyList es t `withLocs` es)
                          Just i -> throwError $ TypeMismatch t (ts !! i) `withExpr` (l !! i)

infer e@(L loc (JProxyCall (L _ (JNew c args)) t)) =
    if c /= (namespace ++ "FunctionalList")
    then
        throwError $ (General $ text $ show c ++ " from JProxyCall: not supported") `withExpr` e
    else
        do ([t1, t2], es) <- mapAndUnzipM infer args
           d <- getTypeContext
           if compatible d (ListOf t1) t2
             then return (t2, L loc $ JProxyCall (L loc $ JNew c es) t2)
             else throwError $ TypeMismatch t1 t2 `withExpr` e

infer e@(L loc (JProxyCall jmethod t)) =
    case jmethod of
        L _ (JMethod (NonStatic e) methodname _ _) -> do
            ty <- case methodname of
                "head" -> do (ListOf a, _) <- infer e
                             return a
                "tail" -> do (a, _) <- infer e
                             return a
                _      -> throwError $ (General $ text $ show methodname ++ " from JProxyCall: not supported") `withExpr` e
            d <- getTypeContext
            m <- infer jmethod
            return (ty, L loc $ JProxyCall (snd m) ty)

infer (L loc (RecordCon fs)) =
  do (ts, es') <- mapAndUnzipM infer (map snd fs)
     let fs' = zip (map fst fs) ts
     return (foldl (\acc (l,t) -> And acc (RecordType [(l,t)])) (RecordType [head fs']) (tail fs'), L loc $ RecordCon (zip (map fst fs) es'))

infer expr@(L loc (RecordProj e l)) =
  do (t, e') <- infer e
     case Map.lookup l (recordFields t) of
       Just t1 -> return (t1, L loc $ RecordProj e' l)
       Nothing -> throwError (NotMember l t `withExpr` expr) -- TODO: should be l's loc

infer (L loc (RecordUpdate e fs)) =
  do (_, es') <- mapAndUnzipM infer (map snd fs)
     (t, e')  <- infer e
     return (t, L loc $ RecordUpdate e' (zip (map fst fs) es'))

-- Well, I know the desugaring is too early to happen here...
infer (L loc (LetModule (Module m binds) e)) =
  do let fs = map bindId binds
     let letrec = L loc $ Let Rec binds (L loc $ RecordCon (map (\f -> (f, noLoc $ Var f)) fs))
     infer (L loc $ Let NonRec [Bind m [] [] letrec Nothing] e)
infer (L loc (ModuleAccess m f)) = infer (L loc $ RecordProj (L loc $ Var m) f)

-- Type synonyms: type T A1 ... An = t in e
-- First make sure that A1 ... An are distinct.
-- Then rewrite to "type T = \A1. ... An. t in e" and kind-check \A1. ... \An. t.
infer expr@(L _ (Type t params rhs e))
  = do checkDupNames params
       typeContext <- getTypeContext
       maybe_kind <- liftIO $ kind typeContext pulledRight
       case maybe_kind of
         Nothing -> throwError $ NotWellKinded pulledRight `withExpr` expr
         Just k  -> withLocalTVars [(t, (k, NonTerminalType pulledRight))] $ infer e
  where
    pulledRight = pullRight params rhs

-- data List A = Nil | Cons A (List A) and ...; e
-- gamma |- Nil: \/A. List A, Cons: \/A. A List A
-- delta |- List: \A. List A
infer (L loc (Data recflag databinds e)) =
    do checkDupNames [ name | DataBind name _ _ <- databinds]
       mapM_ (\(DataBind name params cs) ->
                  do checkDupNames $ name:params
                     let names = map constrName cs
                     checkDupNames names
             ) databinds

       case recflag of
         NonRec -> do
           binds <- mapM (\bind@(DataBind name params _) ->
                             do kind_dt <- getDatatype bind
                                (cs', constr_binds)<- withLocalTVars (kind_dt : zip params (repeat (Star, TerminalType)))
                                                                     $ getConstrbinds bind
                                return ( kind_dt, constr_binds, DataBind name params cs')
                         ) databinds
           let (tvars, vars, databinds') = unzip3 binds
           (t, e') <- withLocalTVars tvars $ withLocalVars (concat vars) $ infer e
           return (t, L loc $ Data recflag databinds' e')
         Rec -> do
           kind_dts <- mapM getDatatype databinds
           withLocalTVars kind_dts $ do
             (vars, databinds') <- mapAndUnzipM (
                     \bind@(DataBind name params _) ->
                            do (cs', constr_binds)<- withLocalTVars (zip params (repeat (Star, TerminalType)))
                                                                    $ getConstrbinds bind
                               return ( constr_binds, DataBind name params cs')
                    ) databinds
             (t ,e') <- withLocalVars (concat vars) (infer e)
             return (t, L loc $ Data recflag databinds' e')

    where getDatatype (DataBind name params cs) =
            do let names = map constrName cs
                   dt = Datatype name (map TVar params) names
                   kind_dt = (foldr (\_ acc -> KArrow Star acc) Star params, NonTerminalType $ pullRight params dt)
               return (name, kind_dt)

          getConstrbinds (DataBind name params cs) =
            do type_ctxt <- getTypeContext
               let names = map constrName cs
                   dt = Datatype name (map TVar params) names
                   constr_types = [pullRightForall params $ wrap Fun [expandType type_ctxt t | t <- ts] dt | Constructor _ ts <- cs]
                   cs' = [ Constructor ctrname ((map (expandType type_ctxt) ts) ++ [dt]) | (Constructor ctrname ts) <- cs]
                   constr_binds = zip names constr_types
               return (cs', constr_binds)

infer e@(L loc (ConstrTemp name)) =
    do g <- getValueContext
       case Map.lookup name g of
         Just t  -> case t of
                      Forall _ _ -> return (t, L loc $ Constr (Constructor name []) [])
                      _ -> return (t, L loc $ Constr (Constructor name (unwrapFun t)) []) -- non-parameterized constructors
         Nothing -> throwError (NotInScope name `withExpr` e)

infer expr@(L loc (Case e alts)) =
 do
   (t, e') <- infer e
   if not (isDatatype t)
    then if isString t
           then inferString
           else throwError $ TypeMismatch t (Datatype "Datatype" [] []) `withExpr` e
    else do
     value_ctxt <- getValueContext
     type_ctxt <- getTypeContext
     let pats = [pat' | ConstrAlt pat' _ <- alts]
         exps = [exp' | ConstrAlt _ exp' <- alts]
     -- check patterns
     pats' <- mapM (typecheckPattern t) pats
     let alts' = zipWith substAltPattern alts pats'

     -- infer e
     (ts, es) <- mapAndUnzipM
                 (\(ConstrAlt pat e2) ->
                      let newvars = getLocalVars pat
                      in  do checkDupNames . fst . unzip $ newvars
                             withLocalVars newvars (infer e2))
                 alts'

     -- result type check
     let resType = head ts
     let i = findIndex (not . compatible type_ctxt resType) ts
     when (isJust i) $
            throwError $ TypeMismatch resType (ts !! fromJust i) `withExpr` (exps !! fromJust i)

     -- exhaustive test
     let exhaustivity = exhaustiveTest value_ctxt (map (\x -> [x]) pats') 1
     unless (null exhaustivity) $
         throwError $ General (text "patterns are not exhausive, missing patterns:" <$>
                               vcat (map (hcat . map pretty) exhaustivity)) `withExpr` expr

     -- overlap test
     let patmatrix = map (\x -> [x]) pats'
         overlapcases = foldr (\num acc ->
                             if usefulClause (take num patmatrix) (patmatrix !! num)
                             then acc
                             else (pats'!! num):acc
                         ) [] [1.. length patmatrix -1]
     when (overlapcases /= []) $
         throwError $ General (text "patterns are overlapped:"<$> vcat (map pretty overlapcases )) `withExpr` expr

     return (resType, L loc $ Case e' (zipWith substAltExpr alts' es))

  where substAltExpr (ConstrAlt c _) = ConstrAlt c
        substAltPattern (ConstrAlt _ exp') p = ConstrAlt p exp'

        isDatatype (Datatype{}) = True
        isDatatype _ = False

        isString (JType (JClass "java.lang.String")) = True
        isString _ = False

        getLocalVars PWildcard  = []
        getLocalVars (PVar nam ty) = [(nam, ty)]
        getLocalVars (PConstr _ pats) = concat $ map getLocalVars pats

        -- ty is the expected type
        typecheckPattern ty (PVar nam _) = return (PVar nam ty)
        typecheckPattern _  PWildcard    = return PWildcard
        typecheckPattern ty pctr@(PConstr ctr pats) = do
            unless (isDatatype ty) $ throwError $ TypeMismatch ty (Datatype "Datatype" [] []) `withExpr` expr
            let Datatype _ ts_feed _ = ty
                nam = constrName ctr
            type_ctxt <- getTypeContext
            value_ctxt <- getValueContext
            case Map.lookup nam value_ctxt of
                Nothing -> throwError $ NotInScope nam `withExpr` expr
                Just t_constr ->
                    let ts = unwrapFun $ feedToForall t_constr ts_feed
                    in do unless (compatible type_ctxt (last ts) ty) $ throwError $ TypeMismatch t_constr ty `withExpr` expr
                          unless ((length ts -1) == (length pats)) $ throwError $ General (text "Constructor" <+> bquotes (text nam)
                                          <+> text "should have" <+> int (length ts -1) <+> text "arguments, but has been given"
                                          <+> int (length pats) <+> text "in pattern" <+> pretty pctr ) `withExpr` expr
                          pat' <- zipWithM typecheckPattern ts pats
                          return $ PConstr (Constructor nam ts) pat'

        -- inferString :: ReaderExpr -> Checker (Type, CheckedExpr)
        inferString =
          do
            (_, e') <- infer e
            let empt = [ b1' | ConstrAlt (PConstr (Constructor "empty" _) []) b1' <-  alts]
            let cons = [ (sub1,sub2,b2') | ConstrAlt (PConstr (Constructor "cons" _) [sub1, sub2]) b2' <- alts]
            unless (length alts == 2 && length empt == 1 && length cons == 1) $
              throwError $ (General $ text "String should have two patterns [] and head:tail") `withExpr` e

            let [b1]               = empt
                [(sub1, sub2, b2)] = cons
            unless (isWildcardOrVar sub1 && isWildcardOrVar sub2) $
              throwError $ (General $ text "String should have two patterns [] and head:tail") `withExpr` e

            let localvar  = case sub1 of PVar nam _ -> [(nam, JType(JClass "java.lang.Character"))]
                                         _          -> []
                localvar' = case sub2 of PVar nam _ -> (nam, JType(JClass "java.lang.String")):localvar
                                         _          -> []
            (t1, emptyexpr) <- infer b1
            (_,  nonemptyexpr) <- withLocalVars localvar' $ inferAgainst b2 t1
            let emptyalt = ConstrAlt (PConstr (Constructor "empty" []) []) emptyexpr
                nonemptyalt = ConstrAlt (PConstr (Constructor "cons" []) [sub1, sub2]) nonemptyexpr
            return (t1, CaseString e' [emptyalt, nonemptyalt] `withLoc` e)

-- | "Pull" the type params at the LHS of the equal sign to the right.
-- A (high-level) example:
--   A B t  ->  \A. \B. t
-- Another concrete example:
--   ghci> pullRight ["A", "B"] (JType (JClass "java.lang.Integer"))
--   OpAbs "A" (OpAbs "B" (JType (JClass "java.lang.Integer")))
pullRight :: [Name] -> Type -> Type
pullRight params t = foldr OpAbs t params

pullRightForall :: [Name] -> Type -> Type
pullRightForall params t = foldr Forall t params

inferAgainst :: ReaderExpr -> Type -> Checker (Type, CheckedExpr)
inferAgainst expr expected_ty
  = do (found_ty, expr') <- infer expr
       d <- getTypeContext
       if compatible d found_ty expected_ty
          then return (found_ty, expr')
          else throwError $ TypeMismatch expected_ty found_ty `withExpr` expr

inferAgainstAnyJClass :: ReaderExpr -> Checker (ClassName, CheckedExpr)
inferAgainstAnyJClass expr
  = do (ty, expr') <- infer expr
       case deThunkOnce ty of
        -- JType (JPrim "char") -> return ("java.lang.Character", expr')
        JType (JClass c) -> return (c, expr')
        ListOf _         -> return (namespace ++ "FunctionalList", expr')
        _ -> throwError $ TypeMismatch ty (JType $ JPrim "Java class") `withExpr` expr

-- | Check "f [A1,...,An] (x1:t1) ... (xn:tn): t = e"
normalizeBind :: ReaderBind -> Checker (Name, Type, CheckedExpr)
normalizeBind bind
  = do bind' <- checkBindLHS bind
       (bindRhsTy, bindRhs') <- withLocalTVars (map (\a -> (a, (Star, TerminalType))) (bindTyParams bind')) $
                                  do expandedBindArgs <- mapM (\(x,t) -> do { d <- getTypeContext; return (x,expandType d t) }) (bindParams bind')
                                     withLocalVars expandedBindArgs (infer (bindRhs bind'))
       case bindRhsTyAscription bind' of
         Nothing -> return ( bindId bind'
                           , wrap Forall (bindTyParams bind') (wrap Fun (map snd (bindParams bind')) bindRhsTy)
                           , wrap (\x acc -> BLam x acc `withLoc` acc) (bindTyParams bind') (wrap (\x acc -> Lam x acc `withLoc` acc) (bindParams bind') bindRhs'))
         Just ty_ascription ->
           withLocalTVars (map (\a -> (a, (Star, TerminalType))) (bindTyParams bind')) $
             do checkType ty_ascription
                d <- getTypeContext
                let ty_ascription' = expandType d ty_ascription
                if compatible d ty_ascription' bindRhsTy
                   then return (bindId bind'
                               , wrap Forall (bindTyParams bind') (wrap Fun (map snd (bindParams bind')) bindRhsTy)
                               , wrap (\x acc -> BLam x acc `withLoc` acc) (bindTyParams bind') (wrap (\x acc -> Lam x acc `withLoc` acc) (bindParams bind') bindRhs'))
                   else throwError $ TypeMismatch (expandType d ty_ascription') bindRhsTy `withExpr` bindRhs bind

-- | Check the LHS to the "=" sign of a bind, i.e., "f A1 ... An (x1:t1) ... (xn:tn)".
-- First make sure the names of type params and those of value params are distinct, respectively.
-- Then check and expand the types of value params.
checkBindLHS :: ReaderBind -> Checker ReaderBind
checkBindLHS Bind{..}
  = do checkDupNames bindTyParams
       checkDupNames (map fst bindParams)
       bindParams' <- withLocalTVars (map (\a -> (a, (Star, TerminalType))) bindTyParams) $
                    -- Restriction: type params have kind *
                    do d <- getTypeContext
                       forM bindParams (\(x,t) ->
                         do checkType t
                            return (x, expandType d t))
       return Bind { bindParams = bindParams', .. }

collectBindIdSigs :: [ReaderBind] -> Checker [(Name, Type)]
collectBindIdSigs
  = mapM (\ Bind{..} ->
            case bindRhsTyAscription of
              Nothing    -> throwError (noExpr $ MissingTyAscription bindId)
              Just tyAscription ->
                do d <- getTypeContext
                   let d' = foldr (\a acc -> Map.insert a (Star, TerminalType) acc) d bindTyParams
                   return (bindId,
                           wrap Forall bindTyParams $
                           wrap Fun [expandType d' ty |  (_,ty) <- bindParams] $
                           expandType d' tyAscription))

-- | Check that a type has kind *.
checkType :: Type -> Checker ()
checkType t =
  case t of
    JType (JClass c) -> checkClassName c
    JType (JPrim _)  -> prettySorry "TypeCheck.checkType" (pretty t)
    _ -> do
      delta <- getTypeContext
      maybe_kind <- liftIO $ kind delta t
      case maybe_kind of
        Nothing   -> throwError (noExpr $ NotWellKinded t)
        Just Star -> return ()
        Just k    -> throwError (noExpr $ KindMismatch Star k t)

unlessIO :: (Monad m, MonadIO m) => IO Bool -> m () -> m ()
unlessIO test do_this
  = do ok <- liftIO test
       unless ok do_this

-- Client library of typeserver API

checkClassName :: ClassName -> Checker ()
checkClassName c
  = do memoized_java_classes <- getMemoizedJavaClasses
       unless (c `Set.member` memoized_java_classes) $
         do h  <- getTypeServer
            res <- liftIO (isJvmType h c)
            if res
               then memoizeJavaClass c
               else throwError (noExpr $ NoSuchClass c)

checkConstruction :: ClassName -> [ClassName] -> Checker ()
checkConstruction c args
  = do h <- getTypeServer
       unlessIO (hasConstructor h c args) $
         throwError (noExpr $ NoSuchConstructor c args)

checkMethodCall :: JCallee ClassName -> MethodName -> [ClassName] -> Checker ClassName
checkMethodCall callee m args
  = do typeserver <- getTypeServer
       res <- liftIO (methodTypeOf typeserver c (m, static_flag) args)
       case res of
         Nothing           -> throwError (noExpr $ NoSuchMethod callee m args)
         Just return_class -> return return_class
    where
       (static_flag, c) = unwrapJCallee callee

checkFieldAccess :: JCallee ClassName -> FieldName -> Checker ClassName
checkFieldAccess callee f
  = do typeserver <- getTypeServer
       res <- liftIO (fieldTypeOf typeserver c (f, static_flag))
       case res of
         Nothing           -> throwError (noExpr $ NoSuchField callee f)
         Just return_class -> return return_class
    where
       (static_flag, c) = unwrapJCallee callee

unwrapJCallee :: JCallee ClassName -> (Bool, ClassName)
unwrapJCallee (NonStatic c) = (False, c)
unwrapJCallee (Static    c) = (True, c)

srcLitType :: Lit -> Type
srcLitType (Int _)    = JType (JClass "java.lang.Integer")
srcLitType (String _) = JType (JClass "java.lang.String")
srcLitType (Bool _)   = JType (JClass "java.lang.Boolean")
srcLitType (Char _)   = JType (JClass "java.lang.Character")
srcLitType UnitLit    = Unit

checkDupNames :: [Name] -> Checker ()
checkDupNames names
  = case findOneDup names of
      Nothing   -> return ()
      Just name -> throwError (noExpr $ DuplicateParam name)

-- | Find one instance of duplicate in a list.
findOneDup :: Ord a => [a] -> Maybe a
findOneDup xs = go xs Set.empty
  where
    go []      _ = Nothing
    go (x:xs') s = if Set.member x s
                     then Just x
                     else go xs' (Set.insert x s)

unwrapFun :: Type -> [Type]
unwrapFun (Fun t t') = t : unwrapFun t'
unwrapFun t = [t]

feedToForall :: Type -> [Type] -> Type
feedToForall =
    foldl (\t t_feed -> case t of
                          Forall a t' -> fsubstTT (a, t_feed) t'
                          _ -> prettySorry "TypeCheck.feedToForall" (pretty t))

noExpr :: TypeError -> LTypeErrorExpr
noExpr err = noLoc (err, Nothing)

withExpr :: TypeError -> ReaderExpr -> LTypeErrorExpr
withExpr err expr = (err, Just expr) `withLoc` expr

---- find the arity of a constructor
ctrArity :: Map.Map Name Type -> ReaderId -> Int
ctrArity value_ctxt name =
    length (removeForall t) - 1
    where Just t =  Map.lookup name value_ctxt
          removeForall (Forall _ b) = removeForall b
          removeForall x            = unwrapFun x

-- Useful clause detect
-- whether clause q is useful with respect to matrix P
usefulClause :: [[Pattern]] -> [Pattern] -> Bool

---- base case
usefulClause [] _ = True
usefulClause _ [] = False

---- q begins with a constructor c
---- U (P, q) = U (S(c,P), S(c,q))
usefulClause pats clause@(PConstr ctr _:_) =
    usefulClause (specializedMatrix ctr pats)
                 (specializedMatrix ctr [clause] !! 0)

---- q begins with a wildcard(or a variable)
usefulClause pats clause =
    -- P has some missing constructor
    -- U (P, _:rest) = U (D(p), rest))
    if all isWildcardOrVar patshead || missingconstrs /= []
    then usefulClause (defaultMatrix pats) (tail clause)
    -- P has all constructors appeared
    -- U (P, q) = whether exists a constructor c that U (S(c,P), S(c,q)) is true
    else any (\ctr -> usefulClause (specializedMatrix ctr pats)
                                   (specializedMatrix ctr [clause] !!0))
             appearconstrs
    where patshead = map head pats
          (appearconstrs, missingconstrs) = constrInfo patshead

-- Test a Pattern matrix is exhaustive
exhaustiveTest :: Map.Map Name Type -> [[Pattern]] -> Int -> [[Pattern]]

---- basic cases
exhaustiveTest _ [] 0 = [[]]
exhaustiveTest _ _  0 = []

exhaustiveTest value_ctxt pats n
    -- Simga is the set of appearing constructors
    -- Sigma is empty
    -- if I(D(p), n-1) returns (p2,...,pn)
    -- I(P, n) = (_, p2,...,pn)
    | all isWildcardOrVar patshead = map (PWildcard :) $ exhaustiveTest value_ctxt (map tail pats) (n-1)
    | missingconstrs == []         = exhaustivityForCtr
    | otherwise                    = exhaustivityForCtr ++ exhaustivityForWildcard
    -- if I(S(c, P), a+n-1) returns (r1,...,ra, p2,...,pn)
    -- I(P, n) = (c(r1,...ra), p2,...,pn)
    where patshead = map head pats
          (appearconstrs, missingconstrs) = constrInfo patshead
          exhaustivityForCtr =
                 [ PConstr ctr component: eachres' |
                         ctr <- appearconstrs,
                         let arity = length (constrParams ctr) - 1,
                         eachres <- exhaustiveTest value_ctxt (specializedMatrix ctr pats) (arity + n - 1),
                         let (component, eachres') = splitAt arity eachres ]
    -- Sigma is incomplete
    -- if I(D(P), n-1) returns (p2,...,pn)
    -- I(P, n) = (c(_,...,_), p2,...,pn) for each missing constructor c
          exhaustivityForWildcard =
                 [ cur: eachres | eachres <- exhaustiveTest value_ctxt (defaultMatrix pats) (n-1),
                                  name <- missingconstrs,
                                  let arity = ctrArity value_ctxt name,
                                  let cur = PConstr (Constructor name []) $ replicate arity PWildcard ]
