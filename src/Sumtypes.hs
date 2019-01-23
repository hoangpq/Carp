module Sumtypes where

import qualified Data.Map as Map
import Data.Maybe
import Debug.Trace

import Obj
import Types
import Util
--import Infer
import Concretize
import Polymorphism
import Lookup
import Template
import ToTemplate
import Deftype
import StructUtils

moduleForSumtype :: TypeEnv -> Env -> [String] -> String -> [Ty] -> [XObj] -> Maybe Info -> Maybe Env -> Either String (String, XObj, [XObj])
moduleForSumtype typeEnv env pathStrings typeName typeVariables rest i existingEnv =
  let typeModuleName = typeName
      typeModuleEnv = case existingEnv of
                             Just env -> env
                             Nothing -> Env (Map.fromList []) (Just env) (Just typeModuleName) [] ExternalEnv 0
      insidePath = pathStrings ++ [typeModuleName]
  in do -- TODO: validate members
        let structTy = StructTy typeName typeVariables
            cases = toCases rest
        okIniters <- initers insidePath structTy cases
        (okStr, strDeps) <- binderForStrOrPrn typeEnv env insidePath structTy cases "str"
        let moduleEnvWithBindings = addListOfBindings typeModuleEnv (okIniters ++ [okStr])
            typeModuleXObj = XObj (Mod moduleEnvWithBindings) i (Just ModuleTy)
            deps = strDeps -- ++
        return (typeModuleName, typeModuleXObj, deps)

data SumtypeCase = SumtypeCase { caseName :: String
                               , caseTys :: [Ty]
                               } deriving (Show, Eq)

toCases :: [XObj] -> [SumtypeCase]
toCases = map toCase

toCase :: XObj -> SumtypeCase
toCase (XObj (Lst [XObj (Sym (SymPath [] name) Symbol) _ _, XObj (Arr tyXObjs) _ _]) _ _) =
  SumtypeCase { caseName = name
              , caseTys = (map (fromJust . xobjToTy) tyXObjs)
              }

initers :: [String] -> Ty -> [SumtypeCase] -> Either String [(String, Binder)]
initers insidePath structTy cases = sequence (map (binderForCaseInit insidePath structTy) cases)

binderForCaseInit :: [String] -> Ty -> SumtypeCase -> Either String (String, Binder)
binderForCaseInit insidePath structTy@(StructTy typeName _) sumtypeCase =
  if isTypeGeneric structTy
  then Right (genericCaseInit StackAlloc insidePath structTy sumtypeCase)
  else Right (concreteCaseInit StackAlloc insidePath structTy sumtypeCase)

concreteCaseInit :: AllocationMode -> [String] -> Ty -> SumtypeCase -> (String, Binder)
concreteCaseInit allocationMode insidePath structTy sumtypeCase =
  instanceBinder (SymPath insidePath (caseName sumtypeCase)) (FuncTy (caseTys sumtypeCase) structTy) template
  where template =
          Template
          (FuncTy (caseTys sumtypeCase) (VarTy "p"))
          (\(FuncTy _ concreteStructTy) ->
             let mappings = unifySignatures structTy concreteStructTy
                 --correctedMembers = replaceGenericTypeSymbolsOnMembers mappings membersXObjs
                 --memberPairs = memberXObjsToPairs correctedMembers
             in  (toTemplate $ "$p $NAME(" ++ joinWithComma (map memberArg (zip anonMemberNames (caseTys sumtypeCase))) ++ ")"))
          (const (tokensForCaseInit allocationMode structTy sumtypeCase))
          (\(FuncTy _ _) -> [])

genericCaseInit :: AllocationMode -> [String] -> Ty -> SumtypeCase -> (String, Binder)
genericCaseInit allocationMode pathStrings originalStructTy sumtypeCase =
  defineTypeParameterizedTemplate templateCreator path t
  where path = SymPath pathStrings (caseName sumtypeCase)
        t = FuncTy (caseTys sumtypeCase) originalStructTy
        templateCreator = TemplateCreator $
          \typeEnv env ->
            Template
            (FuncTy (caseTys sumtypeCase) (VarTy "p"))
            (\(FuncTy _ concreteStructTy) ->
               (toTemplate $ "$p $NAME(" ++ joinWithComma (map memberArg (zip anonMemberNames (caseTys sumtypeCase))) ++ ")"))
            (\(FuncTy _ concreteStructTy) ->
               (tokensForCaseInit allocationMode concreteStructTy sumtypeCase))
            (\(FuncTy _ concreteStructTy) ->
               case concretizeType typeEnv concreteStructTy of
                 Left err -> error (err ++ ". This error should not crash the compiler - change return type to Either here.")
                 Right ok -> ok)


tokensForCaseInit :: AllocationMode -> Ty -> SumtypeCase -> [Token]
tokensForCaseInit allocationMode sumTy@(StructTy typeName typeVariables) sumtypeCase =
  toTemplate $ unlines [ "$DECL {"
                       , case allocationMode of
                           StackAlloc -> "    $p instance;"
                           HeapAlloc ->  "    $p instance = CARP_MALLOC(sizeof(" ++ typeName ++ "));"
                       , joinWith "\n" (map (caseMemberAssignment allocationMode (caseName sumtypeCase))
                                        (zip anonMemberNames (caseTys sumtypeCase)))
                       , "    instance._tag = " ++ tagName sumTy (caseName sumtypeCase) ++ ";"
                       , "    return instance;"
                       , "}"]

caseMemberAssignment :: AllocationMode -> String -> (String, Ty) -> String
caseMemberAssignment allocationMode caseName (memberName, _) =
  "    instance." ++ caseName ++ sep ++ memberName ++ " = " ++ memberName ++ ";"
  where sep = case allocationMode of
                StackAlloc -> "."
                HeapAlloc -> "->"

-- | Helper function to create the binder for the 'str' template.
binderForStrOrPrn :: TypeEnv -> Env -> [String] -> Ty -> [SumtypeCase] -> String -> Either String ((String, Binder), [XObj])
binderForStrOrPrn typeEnv env insidePath structTy@(StructTy typeName _) cases strOrPrn =
  if isTypeGeneric structTy
  then Right (genericStr insidePath structTy cases strOrPrn, [])
  else Right (concreteStr typeEnv env insidePath structTy cases strOrPrn, [])

-- | The template for the 'str' function for a concrete deftype.
concreteStr :: TypeEnv -> Env -> [String] -> Ty -> [SumtypeCase] -> String -> (String, Binder)
concreteStr typeEnv env insidePath concreteStructTy@(StructTy typeName _) cases strOrPrn =
  instanceBinder (SymPath insidePath strOrPrn) (FuncTy [(RefTy concreteStructTy)] StringTy) template
  where template =
          Template
            (FuncTy [RefTy concreteStructTy] StringTy)
            (\(FuncTy [RefTy structTy] StringTy) -> (toTemplate $ "String $NAME(" ++ tyToCLambdaFix structTy ++ " *p)"))
            (\(FuncTy [RefTy structTy@(StructTy _ concreteMemberTys)] StringTy) ->
                (tokensForStr typeEnv env typeName cases concreteStructTy))
            (\(ft@(FuncTy [RefTy structTy@(StructTy _ concreteMemberTys)] StringTy)) ->
               -- concatMap (depsOfPolymorphicFunction typeEnv env [] "prn" . typesStrFunctionType typeEnv)
               --           (filter (\t -> (not . isExternalType typeEnv) t && (not . isFullyGenericType) t)
               --            (map snd cases))
               []
            )

-- | The template for the 'str' function for a generic deftype.
genericStr :: [String] -> Ty -> [SumtypeCase] -> String -> (String, Binder)
genericStr insidePath originalStructTy@(StructTy typeName varTys) cases strOrPrn =
  defineTypeParameterizedTemplate templateCreator path t
  where path = SymPath insidePath strOrPrn
        t = FuncTy [(RefTy originalStructTy)] StringTy
        templateCreator = TemplateCreator $
          \typeEnv env ->
            Template
            t
            (\(FuncTy [RefTy concreteStructTy] StringTy) ->
               (toTemplate $ "String $NAME(" ++ tyToCLambdaFix concreteStructTy ++ " *p)"))
            (\(FuncTy [RefTy concreteStructTy@(StructTy _ concreteMemberTys)] StringTy) ->
               let mappings = unifySignatures originalStructTy concreteStructTy
                   --correctedMembers = replaceGenericTypeSymbolsOnMembers mappings cases
               in (tokensForStr typeEnv env typeName cases concreteStructTy))
            (\(ft@(FuncTy [RefTy concreteStructTy@(StructTy _ concreteMemberTys)] StringTy)) ->
               let mappings = unifySignatures originalStructTy concreteStructTy
                   --correctedMembers = replaceGenericTypeSymbolsOnMembers mappings cases
               in  --concatMap (depsOfPolymorphicFunction typeEnv env [] "prn" . typesStrFunctionType typeEnv)
                   --(filter (\t -> (not . isExternalType typeEnv) t && (not . isFullyGenericType) t)
                   -- (map snd cases))
                   -- ++
                   (if isTypeGeneric concreteStructTy then [] else [defineFunctionTypeAlias ft]))

tokensForStr :: TypeEnv -> Env -> String -> [SumtypeCase] -> Ty -> [Token]
tokensForStr typeEnv env typeName cases concreteStructTy  =
  (toTemplate $ unlines [ "$DECL {"
                        , "  // convert members to String here:"
                        , "  String temp = NULL;"
                        , "  int tempsize = 0;"
                        , "  (void)tempsize; // that way we remove the occasional unused warning "
                        --, calculateStructStrSize typeEnv env cases concreteStructTy
                        , "  int size = 99999; // HACK!" -- | TEMPORARY HACK, FIX!
                        , "  String buffer = CARP_MALLOC(size);"
                        , "  String bufferPtr = buffer;"
                        , ""
                        , (concatMap (strCase typeEnv env) cases)
                        , "  return buffer;"
                        , "}"])

strCase :: TypeEnv -> Env -> SumtypeCase -> String
strCase typeEnv env theCase =
  let name = caseName theCase
      tys  = caseTys  theCase
  in unlines $
     [ "  snprintf(bufferPtr, size, \"(%s \", \"" ++ name ++ "\");"
     , "  bufferPtr += strlen(\"" ++ name ++ "\") + 2;\n"
     , joinWith "\n" (map (memberPrn typeEnv env) (zip (map (\anon -> name ++ "." ++ anon) anonMemberNames) tys))
     , "  bufferPtr--;"
     , "  snprintf(bufferPtr, size, \")\");"
     ]
