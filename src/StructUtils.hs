module StructUtils where

import Obj
import Types
import Util
import Lookup
import Polymorphism

-- | Figure out how big the string needed for the string representation of the struct has to be.
calculateStructStrSize :: TypeEnv -> Env -> [(String, Ty)] -> Ty -> String
calculateStructStrSize typeEnv env members structTy@(StructTy name _) =
  "  int size = snprintf(NULL, 0, \"(%s )\", \"" ++ name ++ "\");\n" ++
    unlines (map memberPrnSize members)
  where memberPrnSize (memberName, memberTy) =
          let refOrNotRefType = if isManaged typeEnv memberTy then RefTy memberTy else memberTy
              maybeTakeAddress = if isManaged typeEnv memberTy then "&" else ""
              strFuncType = FuncTy [refOrNotRefType] StringTy
           in case nameOfPolymorphicFunction typeEnv env strFuncType "prn" of
                Just strFunctionPath ->
                  unlines ["  temp = " ++ pathToC strFunctionPath ++ "(" ++ maybeTakeAddress ++ "p->" ++ memberName ++ "); "
                          , "  size += snprintf(NULL, 0, \"%s \", temp);"
                          , "  if(temp) { CARP_FREE(temp); temp = NULL; }"
                          ]
                Nothing ->
                  if isExternalType typeEnv memberTy
                  then unlines [ "  size +=  snprintf(NULL, 0, \"%p \", p->" ++ memberName ++ ");"
                               , "  if(temp) { CARP_FREE(temp); temp = NULL; }"
                               ]
                  else "  // Failed to find str function for " ++ memberName ++ " : " ++ show memberTy ++ "\n"

-- | Generate C code for converting a member variable to a string and appending it to a buffer.
memberPrn :: TypeEnv -> Env -> (String, Ty) -> String
memberPrn typeEnv env (memberName, memberTy) =
  let refOrNotRefType = if isManaged typeEnv memberTy then RefTy memberTy else memberTy
      maybeTakeAddress = if isManaged typeEnv memberTy then "&" else ""
      strFuncType = FuncTy [refOrNotRefType] StringTy
   in case nameOfPolymorphicFunction typeEnv env strFuncType "prn" of
        Just strFunctionPath ->
          unlines ["  temp = " ++ pathToC strFunctionPath ++ "(" ++ maybeTakeAddress ++ "p->" ++ memberName ++ ");"
                  , "  snprintf(bufferPtr, size, \"%s \", temp);"
                  , "  bufferPtr += strlen(temp) + 1;"
                  , "  if(temp) { CARP_FREE(temp); temp = NULL; }"
                  ]
        Nothing ->
          if isExternalType typeEnv memberTy
          then unlines [ "  tempsize = snprintf(NULL, 0, \"%p\", p->" ++ memberName ++ ");"
                       , "  temp = malloc(tempsize);"
                       , "  snprintf(temp, tempsize, \"%p\", p->" ++ memberName ++ ");"
                       , "  snprintf(bufferPtr, size, \"%s \", temp);"
                       , "  bufferPtr += strlen(temp) + 1;"
                       , "  if(temp) { CARP_FREE(temp); temp = NULL; }"
                       ]
          else "  // Failed to find str function for " ++ memberName ++ " : " ++ show memberTy ++ "\n"
