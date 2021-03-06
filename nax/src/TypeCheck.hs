{-# LANGUAGE TupleSections #-}

module TypeCheck where

import Parser(parse2,kindP)

import Names
import Syntax
import BaseTypes
import Types
import Terms(applyE,abstract)
import Monads(FIO,fio,handleM,handleMM,fresh,freshName)
import Control.Monad(foldM,when,liftM,liftM2)
import Data.IORef(newIORef,readIORef,writeIORef,IORef)
import qualified Data.Map as DM
-- import Eval(normalizeInEnv)
import Parser(parseExpr)


import Data.List(unionBy,union,nub,find,intersect,(\\),isInfixOf)
import Data.Char(toLower)
import UniqInteger(nextinteger)
import Text.PrettyPrint.HughesPJ(Doc,text,int,(<>),(<+>),($$),($+$)
                                ,render,vcat,sep,nest,parens)
import Debug.Trace(trace)                                
--------------------------------------------------------
-- Type inference
--------------------------------------------------------

data Expected a = Infer (IORef a) | Check a

instance Show a => Show(Expected a) where
  show (Check x) = show x
  show (Infer r) = "unknown (we are trying to infer it)"

zonkExpRho (Check r) = fmap Check (zonkRho r)
zonkExpRho (Infer r) = return(Infer r)

extract (Check r) = zonkRho r
extract (Infer ref) = 
 do { r <- fio(readIORef ref); zonkRho r }

---------------------------------------------------
-- Frags are static environments that are created
-- by type checking, they capture the changes to the
-- environment that are made by binding structures
-- such as patterns and declaration.


data Frag = Frag 
            { lambnd::   [(Name,Scheme)]   -- Used for generalization, holds all variables in the environment
            , existbnd:: [Name]            -- Existentially bound type variables when pattern matching
            , values:: [(Name,Class Kind Typ TExpr)] 
                       -- Every time evalDecC is called (at the toplevel loop)
                       -- The runtime value of things declared are added to
                       -- the value part of the Frag, so typechecking future
                       -- declarations can look up the values associated with
                       -- backtick names in types such as (Vector Int {`succ n})
            , scopednames:: [Class Name Name Name]
                       -- typings on patterns, such as (\ (x::[a]) -> ...)
                       -- introduced scoped variables (like 'a') that might
                       --  appear in terms in the scope of the variable 'x'.
            , ppinfo :: PI
            , table:: DM.Map Name NameContents
            }
         
nullFrag = Frag [] [] [] [] pi0 tyConTable

------------------------------------------------------------------------------
-- There are 5 kinds of Names: Kind, Type, Exp, TyCon, and ECon names
-- when we look these up we need different kind of information
-- when checking Parsed values
-- Kvar -- a real kind
-- TyVar -- A real Type
-- ExpVar -- A scheme and (possibly a CSP constant)
-- TyCon (MuSyntax,Polykind) or a 
-- ECon -- A scheme and (ExpSynonym transformer or a MuSyntax)

data VARRole 
  = Normal (TExpr,Scheme)                                  -- x 
  | InSyntax (String,Int,SourcePos -> [Expr] -> FIO Expr)  -- succ in: succ x --> In [*] (Succ x)
  | TermIndex (Name,Integer,Typ)                                   -- x in: \ (v:Vector a {`succ x}) -> 4

data NameContents 
  = KVAR Kind
  | TYVAR Typ
  | EVAR VARRole -- (Either (TExpr,Scheme) (String,Int,SourcePos -> [Expr] -> FIO Expr))
  | TYCON1 (MuSyntax,PolyKind)
  | TYCON2 (String,Int,SourcePos -> [Typ] -> FIO Typ)
  | ECON (Scheme,String,MuSyntax)
  
addTable f (nm,x) frag = frag{table= DM.insert nm (f x) (table frag)}



defined frag nm = 
  case DM.lookup nm (table frag) of
    Just _ -> True
    Nothing -> False

namePositions frag nm = DM.foldrWithKey acc [] (table frag)
  where acc k _ ms | nm==k = loc k : ms
        acc k _ ms = ms
    
instance Show NameContents where
  show (KVAR k) = "Kind "++show k
  show (TYVAR t) = "Type "++show t
  show (EVAR (Normal sch)) = "Expr "++show sch
  show (EVAR (TermIndex (nm,uniq,t))) = "Term index ("++show uniq++") "++show nm++": "++show t
  show (EVAR (InSyntax (nm,n,f))) = "'In' syntax with arity "++show n++plistf id ". " (nm:take n strings) " " " = "++show comp      
   where comp = f noPos (map ty (take n nameSupply))
         ty nm = EVar nm
  show (TYCON1 (mu,k)) = "TypeCon "++show k++sh mu
    where sh None = ""
          sh (Syn x) = ", Mu syntax. "++x
  show (TYCON2 (str,n,f)) = "TypeCon syntax with arity "++show n++", "++ str        
  show (ECON (sch,nm,mu)) = "Expr syntax. "++show sch++sh mu
    where sh None = ""
          sh (Syn x) = ", 'In' syntax. "++nm

--------------------------------------------------
-- operations on Frags

-- look up a classified name in a Frag, to compute a Tele entry

nameToTele:: Frag -> Class Name Name Name -> FIO (Name, Class () Kind Typ)
nameToTele frag clname = 
  case (clname,DM.lookup (unClass clname) (table frag)) of
    (_,Nothing) -> fail (cl++" "++show v++" not found in table\n") -- ++ pp (DM.toList(table frag)))
       where (cl,v) = showCl clname
             pp xs = plistf f "  " xs "\n  " "\n\n"
             f (nm,x) = show nm++" = "++show x
    (Kind nm,Just(KVAR k)) -> return (nm,Kind ())
    (Type nm,Just(TYVAR t)) -> do { k <- kindOf t; k2 <- zonkKind k; return(nm,Type k2)}
    (Exp nm,Just(EVAR (TermIndex(_,uniq,t)))) -> return(nm,Exp t)
    (Exp nm,Just(EVAR(Normal(_,sch)))) -> 
        do { (rho,_) <- instantiate sch
           ; case rho of
              Tau t -> do { t2 <- zonk t; return(nm,Exp t2)}
              Rarr _ _ -> error ("The name "++show nm++" does not have a monomorphic type.") }
    (x,w) -> fail (v++" is found in the environment with a class different from "++cl++show w)
       where (cl,v) = showCl x
       
       
addSyn f frag = frag{ppinfo = push f (ppinfo frag)}
  where push f pi = pi{synonymInfo = f : (synonymInfo pi)}

showFrag n frag = do { writeln "\nshowFrag\nTypes ="; mapM_ f (take n (DM.toList (table frag))) }
  where f (nm,t) = writeln(show nm++": "++show t)

showScoped s frag = writeln(s++plistf show " " (scopednames frag) "," "")
addScope classNm frag = return (frag{scopednames = classNm:(scopednames frag)})
       
data BindMode = LamBnd | LetBnd  

addTermVar var sigma LamBnd frag =  
        addTable EVAR (var,Normal(TEVar var sigma,sigma)) (frag{lambnd = ((var,sigma):(lambnd frag))})
addTermVar var sigma LetBnd frag = addTable EVAR (var,Normal(TEVar var sigma,sigma)) frag

 
addExQuant xs frag = frag{existbnd = (xs++ existbnd frag)}  
                  
browseFrag:: String -> Frag -> String     
browseFrag n frag = plistf g "\n" tableL "\n" "\nDONE"
  where {-
        select (Nm(s,loc),sch) = (s,loc,sch)
        mytake Nothing xs = xs
        mytake (Just n) xs = take n xs
        max = maximum (0 : map (\(x,y,z)-> length x) pairs)
        strings = map f pairs
        f (s,loc,v) = pad (max+1) s ++ show loc ++ " " ++ show v 
        -}
        p (x,y) = isInfixOf n (name x)
        tableL = filter p (DM.toList (table frag))
        max2 = maximum (0 : map (\(x,y)-> length (name x)) tableL)
        g (s,x) = pad (max2+1) (show s)++": "++show x
                  
tvsEnv:: Frag -> FIO Pointers
tvsEnv frag = do { vss <- mapM f monoSchemes; return(concat vss) }
  where monoSchemes = map snd (lambnd frag) 
        f s = do { (ptrs,names) <- getVarsScheme s; return ptrs }
        
namesEnv:: Frag -> FIO [Name]
namesEnv frag = do { vss <- mapM f monoSchemes; return(concat vss ++ existbnd frag) }
  where monoSchemes = map snd (lambnd frag) 
        f s = do { (ptrs,names) <- getVarsScheme s; return(map unClass names)}        

------------------------------------------------------------------
-- Forcing a particular shape on a type that might be polymorphic

expecting :: SourcePos -> String -> (Typ -> Typ -> Typ) -> Expected Rho -> FIO(Rho,Rho)
expecting loc shape f expect =
  do { a <- freshType Star; b <- freshType Star
     ; case expect of
         Check (Tau p) -> unify loc [shape] p (f a b)
         Infer ref -> do { a <- zonk (f a b); fio(writeIORef ref (Tau a)) }
         Check other -> fail ("\nThe type: "++show other++" is not conducive to "++shape)
     ; m <- zonk a
     ; t2 <- zonk b
     ; return(Tau m,Tau t2) }

sigmaPair:: SourcePos -> String -> Scheme -> FIO(Scheme,Scheme)
sigmaPair loc shape (Sch vs rho) = 
  do { (r1,r2) <- expecting loc shape pairT (Check rho)
     ; return(Sch vs r1,Sch vs r2) }

sigmaTuple:: SourcePos -> Int -> Scheme -> FIO[Scheme]
sigmaTuple loc size (Sch vs rho) = 
  do { rs <- mapM (\ n -> freshType Star) [1..size]
     ; let message = "\nThe type: "++show rho++" is not a tuple."
     ; case rho of
         (Tau p) -> unify loc [message] p (TyTuple Star rs)
         (Rarr _ _) -> fail (message)
     ; zs <- mapM zonk rs         
     ; return(map (Sch vs . Tau) zs)
     }

isTuple:: SourcePos -> Int -> Expected Rho -> FIO [Typ]
isTuple loc size x = do {y <- zonkExpRho x; help y}
  where help (Check (Tau (TyTuple k ts))) = return ts
        help (Check (Tau t)) = 
           do { rs <- mapM (\ n -> freshType Star) [1..size]
              ; let message = "\nThe type: "++show t++" is not a tuple."
              ; unify loc [message] t (TyTuple Star rs)
              ; mapM zonk rs }
        help (Infer ref) = 
           do { rs <- mapM (\ n -> freshType Star) [1..size]
              ; fio(writeIORef ref (Tau(TyTuple Star rs)))
              ; return rs }
              

unifyMonad :: SourcePos -> Expected Rho -> FIO(Typ,Typ,TEqual)
unifyMonad loc (Check (t@(Tau(TyApp m a)))) = return (m,a,TRefl (rhoToTyp t))
unifyMonad loc expected =
  do { a <- freshType Star
     ; m <- freshType (Karr Star Star)
     ; p <- morepolyRExpectR_ loc ["\nWhile forcing a monadic type on "++show expected] (Tau(TyApp m a)) expected
     ; a' <- zonk a
     ; m' <- zonk m
     ; return(m',a',p) }

---------------------------------------------------
-- Whenever we parse a type or kind, we don't have enough
-- ingormation to fill in all the information stored in types.
-- So we make a pass over the parsed type filling in the missing 
-- informations. This includes kinds for types, and the
-- expansion of type synonyms. The WellFormed... functions do this.


-- first some helper functions
notInScope mess sort nm count frag =
 (unlines (("\n\nError *****\n"++sort ++" var: "++show nm++", not in scope."):mess))
 
mismatch mess expected actual nm =
  unlines(("\nThe '"++expected++"' variable: "++show nm++
           " was found in scope, but is used inconsistently as an '"++
           actual++"'\n"++near nm):mess)

univ (Kind nm) = do { return(nm,Kind (Kname nm))}
univ (Type nm) = do { k <- freshKind; t <- freshType k; return(nm,Type (TyVar nm k))}
univ (Exp nm) =  
   do { k <- freshKind
      ; t <- freshType k
      ; return(nm,Exp (TEVar nm (mono t)))}

addMulti [] frag = frag
addMulti ((m@(nm,Exp (term@(TEVar _ sch)))):more) frag = 
   addMulti more (addTable EVAR (nm,Normal(term,sch)) frag)
addMulti ((m@(nm,Exp (term@(Emv(u,ptr,ty))))):more) frag = 
   addMulti more (addTable EVAR (nm,Normal(term,Sch [] (Tau ty))) frag)
addMulti ((m@(nm,Type t)):more) frag =
   addMulti more (addTable TYVAR (nm,t) frag)
addMulti ((m@(nm,Kind k)):more) frag =
   addMulti more (addTable KVAR (nm,k) frag)   
addMulti (m:more) frag =  
   addMulti more (frag)



-- when a programmer annotates a pattern with a type
-- ie like  (x:forall a. x -> Vector a {`succ x})
-- the free Exp variables ('x' above) must be added
-- as 'TermIndex' variables, not 'Normal' variables.
-- And all variables must be added to the scope.

freshClass (Kind nm) = do { k <- freshKind; return(nm,Kind k)}
freshClass (Type nm) = do { k <- freshKind; t <- freshType k; return(nm,Type t)}
freshClass (Exp nm) =  
   do { k <- freshKind
      ; t <- freshType k
      ; e <- freshExp t
      ; return(nm,Exp (TEVar nm (mono t))) }
      
addAnnMulti [] frag = return frag
addAnnMulti (m:ms) frag =
  do frag2 <- case m of
               (nm,Exp (term@(TEVar _ (Sch [] (Tau t))))) -> 
                 do { uniq <- fio(nextinteger)
                    ; addScope (Exp nm) (addTable EVAR (nm,TermIndex(nm,uniq,t)) frag) }
               (nm,Type t) -> addScope (Type nm) (addTable TYVAR (nm,t) frag)
               (nm,Kind k) -> addScope (Kind nm) (addTable KVAR (nm,k) frag)  
               _ -> return frag
     addAnnMulti ms frag2
   


wfGadtKind:: SourcePos -> [String] -> Frag -> Kind -> FIO(Kind,[(Name, Class Kind Typ TExpr)])
wfGadtKind pos mess frag k = 
  do { (ptrs,names) <- getVarsKind k
     ; boundNames <- mapM univ names  -- bind all free variables
     ; let frag2 = addMulti boundNames frag
     ; k2 <- wfKind 0 pos (("Checking wff kind: "++show k):mess) frag2 k
     ; let f (nm,Kind i) = do { kvar <- freshKind; return(nm,Kind kvar)}
           f (nm,Type i) = do { k <- freshKind; tvar <- freshType k; return(nm,Type tvar)}
           f (nm,Exp i) = do { k <- freshKind; t <- freshType k
                             ; evar <- freshExp t; return(nm,Exp evar)}
     ; sub  <- mapM f boundNames
     ; k3 <- kindSubb pos ([],sub,[]) k2
     ; return(k2,boundNames)  -- FIX (k3,boundNames)
     }

wfKind:: Int -> SourcePos -> [String] -> Frag -> Kind -> FIO Kind
wfKind i pos mess frag k = do { x <- pruneK k; f x }
  where f Star = return Star
        f (zz@(Tarr t k)) = 
           do { (t2,tkind) <- wellFormedType (i+1) pos (("checking wff lifted type:\n  "++show t++"\nin kind arrow:\n  "++show zz):mess) frag t
              ; k2 <- wfKind (i+1) pos mess frag k
              ; return(Tarr t2 k2) }
        f (Karr k1 k2) = liftM2 Karr (wfKind (i+1) pos mess frag k1) (wfKind (i+1) pos mess frag k2)
        f (k@(Kvar _)) = return k
        f (Kname nm) = 
            case DM.lookup nm (table frag) of
              Just (TYVAR t) -> fail(mismatch mess "kind" "type" nm)
              Just (KVAR k) -> return k
              Just (EVAR(Normal(e,sch))) -> fail(mismatch mess "type" "expression" nm)
              Just (EVAR(TermIndex(e,u,sch))) -> fail(mismatch mess "type" "expression" nm)              
              other -> fail(notInScope mess "type" nm 5 frag)     
    
-- When we see a parsed TyCon object, it might stand for either a real
-- type constructor, or the name of a Type synonym. Here is where we
-- decide and expand type synonyms.

wellFormedTyCon i pos mess frag c xs = 
   case DM.lookup c (table frag) of
     Nothing -> fail (unlines(("\n"++show pos++"\nUnknown type constructor: "++show c):mess))                         
     Just (TYCON1(syn,polyk)) ->     -- Left is a real TyCon, its polykind is stored in the table
         do { k <- instanK pos polyk
            ; return(applyT(TyCon syn c polyk : xs),k) }
     Just (TYCON2(str,arity,f)) ->  -- Right is a type synonym, its expansion function is 'f'
        if arity==length xs 
           then do { t2 <- f pos xs  -- Its f's job to expand into a new type.
                   ; wellFormedType (i+1) pos mess frag t2 }
           else fail("\nType synonym: "++show c++", with arity "++show arity++
                     ", is not appled to the correct number of args.\n  "++
                     plistf id "" (show c : map (show) xs) " " "")
     Just t -> fail (unlines(("\n"++show pos++"\nWe were expecting a Type Constructor, but we found a "++show t++
                              " for "++show c++".\nPerhaps you forgot the { } brackets?"):mess))                           


expandTypSyn env (TyApp f x) xs = expandTypSyn env f (x:xs)
expandTypSyn env (TyCon mu nm polyk) xs = 
   case DM.lookup nm (table env) of
     Just(TYCON2(str,arity,f)) -> Just(nm,f,xs)
     other -> Nothing
expandTypSyn env _ xs = Nothing

wellFormedType:: Int -> SourcePos -> [String] -> Frag -> Typ -> FIO(Typ,Kind)
wellFormedType i pos mess frag typ = do { x <- prune typ
                                      --; writeln (replicate i ' ' ++"Enter WFT "++show x)
                                      ; ans@(t,k) <- f x
                                      ; k2 <- zonkKind k
                                      --; (_,zs) <- getVars t
                                      --; (_,qs) <- getVarsKind k2
                                      --; writeln (replicate i ' '++"Exit WFT "++show t++": "++show k2++" vars = "++show zs++show qs)
                                      ; return(t,k2) }
  where call x = wellFormedType (i+1) pos mess frag x
        has k1 x = do { (x2,k2) <- call x
                       ; unifyK pos (("checking term ("++show x2++": "++show k2++") has expected kind:"++show k1):mess) k2 k1
                       ; return x2 }                       
        f (TyVar nm _) = 
           case DM.lookup nm (table frag) of
              Just (TYVAR t) -> do { k <- kindOf t; return(t,k) }
              Just (KVAR k) -> fail(mismatch mess "type" "kind" nm)
              Just (EVAR(Normal(e,sch))) -> fail(mismatch mess "type" "expression" nm)
              Just (EVAR(TermIndex(e,u,sch))) -> fail(mismatch mess "type" "expression" nm)              
              other -> fail(notInScope mess "type" nm 5 frag)     
        f (typ@(TyApp _ _)) | Just (nm,f,xs) <- expandTypSyn frag typ [] =
          do { t2 <- f (loc typ) xs
             -- ; writeln("\nMacro expands "++show typ++"\n  "++show t2)
             ; ans <- call t2
             ; return ans}
        f (typ@(TyApp f (TyLift e))) = 
          do { (term,dom) <- wellFormedTerm (i+1) pos mess frag e
             ; rng <- freshKind
             ; (f2,k2) <- call f
             ; unifyK pos mess k2 (Tarr dom rng)
             ; z3 <- zonkKind k2
             ; sv <- getVarsKind z3
             ; return(TyApp f2 (TyLift(Checked term)),rng)}            
        f (typ@(TyApp f x)) = 
          do { dom <- freshKind; rng <- freshKind
             ; (f2,k2) <- call f
             ; unifyK pos mess k2 (Karr dom rng)
             ; x2 <- has dom x
             ; return(TyApp f2 x2,rng)}
        f (t@(TyTuple k ts)) = 
          do { k2 <- wfKind (i+1) pos (("Checking tuple kind: "++show t):mess) frag k
             ; ts2 <- mapM (has k2) ts
             ; return(TyTuple k2 ts2,k2) }
        f (TyCon _ c _) = wellFormedTyCon i pos mess frag c []
        f (TyArr x y) = 
          do { x2 <- has Star x; y2 <- has Star y; return(TyArr x2 y2,Star)}
        f (t@(TySyn nm arity xs body)) = wellFormedType (i+1) pos mess frag body
        f (TyProof f x) =
          do { (f2,kf) <- call f
             ; (x2,kx) <- call x
             ; unifyK pos mess kx kf
             ; return(TyProof f2 x2,Star)}
        f (TyMu k Nothing) =
          do { let m = ("\nChecking wff (Mu "++show k++")"):mess
             -- ; k <- freshKind -- want kinds inferred
             -- Howver the commented line above does not work
             --  because of "collect" function used by "runcount" function
             --  I think we must only consider TyMu in its fully applied form
             --  or do something else
             ; (k2,newvs) <- wfGadtKind pos m frag k -- kind checking
             ; return(TyMu k2 Nothing,Karr (Karr k2 k2) k2) }
        f (TyMu k (Just t)) = error ("No Mu* in wellFormedType yet")
        f (TcTv (x@(uniq,ptr,k))) = return (TcTv x,k)   
        f (TyLift t) = fail ("Lifted type in non application argument position: "++show t)
{-        
        f (TyLift (Checked texp)) = 
          do { t <- typeOf texp
             ; return(TyLift (Checked texp),LiftK t)}
        f (TyLift (Parsed term)) =
          do let trans msg = unlines (msg:mess)
             (rho,term2) <- handleM (inferExpT frag term) trans
             case rho of
               Tau t -> return(TyLift (Checked term2),LiftK t)
               Rarr x y -> fail (unlines (("\nLifted term in type: "++show term++", is a function, "++show rho++", not data"):mess))
-}

wellFormedTerm :: Int -> t -> [String] -> Frag -> Term -> FIO (TExpr, Typ)
wellFormedTerm i pos message frag (Checked texp) = 
   do { -- writeln("\nEnter wellFormedTerm checked "++near texp ++show texp);
        ty <- typeOf texp; return(texp,ty)}
wellFormedTerm i pos message frag (Parsed term) =
   do { -- writeln(replicate i ' '++"Enter WFTerm Parsed "++show term);
        -- terms need to have their free variables be replaced by CSP constants?
        let trans msg = unlines (msg:message)
      ; (rho,term2) <- handleM (inferExpT frag term) trans
      ; (term,typ) <- case rho of
                Tau t -> return(term2,t)
                (Rarr (Sch [] (Tau dom)) (Tau rng)) -> return(term2,TyArr dom rng)
                Rarr x y -> fail (unlines (("\nLifted term in type: "++show term++", is a function, "++show rho++", not data"):message))
          
      -- ; writeln(replicate i ' '++"Exit WFTerm "++show term++": "++show typ++show ww)
      ; return (term,typ)
      }

etaReduce (TECast eq x) = TECast eq (etaReduce x)
etaReduce (term@(TEAbs ElimConst [(PVar x _,TEApp f (TEVar y _))]))
   | x==y = trace ("HERE1 "++show term) (etaReduce f)
   | otherwise = trace ("HERE2 "++show term++", "++show x++" "++show y) term
etaReduce term = trace ("HERE3 "++show term) term   
  

wellFormedRho:: Int -> SourcePos -> [String] -> Frag -> Rho -> FIO Rho
wellFormedRho i pos mess frag (Tau t) = 
   do { (t2,k) <- wellFormedType i pos mess frag t
      ; return(Tau t2) }
wellFormedRho i pos mess frag (Rarr s r) =
  liftM2 Rarr (wellFormedScheme (i+1) pos mess frag s) (wellFormedRho (i+1) pos mess frag r)

 -- new version
wellFormedScheme:: Int -> SourcePos -> [String] -> Frag -> Scheme -> FIO Scheme
wellFormedScheme i pos mess frag (Sch [] rho) = liftM monoR (wellFormedRho (i+1) pos mess frag rho)
wellFormedScheme i pos mess frag (Sch vs rho) = 
  do { (frag2,vs2,sub) <- freshPairs pos mess frag vs
     ; rho2 <- return rho
     ; rho3 <- wellFormedRho (i+1) pos mess frag2 rho2 
     ; return(Sch vs2 rho3)}

freshPairs:: SourcePos -> [String] -> Frag -> Telescope -> FIO (Frag,Telescope,[(Name,Class Kind Typ TExpr)])
freshPairs pos mess frag [] = return (frag,[],[]) 
freshPairs pos mess frag ((nm,Type k):more) =   
  do { k2 <- wfKind 0 pos mess frag k
     ; nm2 <- freshName nm
     ; let pair1 = (nm,Type(TyVar nm2 k2))
           pair2 = (nm,Type(TyVar nm2 k2))
           frag2 = addMulti [pair1] frag  
     ; (frag3,ans,sub) <- freshPairs pos mess frag2 more
     ; return(frag3,(nm2,Type k2):ans,pair2:sub)}


generalizeK:: SourcePos -> Frag -> Kind -> FIO PolyKind
generalizeK pos env k =
  do { envPtrs <- tvsEnv env
     ; (freePtrs,freeNames) <- getVarsKind k
     -- ; writeln ("GEN "++show envPtrs++"\n    "++show freePtrs++"\n    "++show freeNames)
     ; let genericPtrs = freePtrs \\ envPtrs
     ; (subst@(ps,ns,ts),tele) <- ptrSubst (map classToName freeNames) genericPtrs nameSupply ([],[],[])
     ; tele2 <- orderTele tele  -- the tele may need reordering!!!
     ; k2 <- kindSubb pos subst k    
     ; zonkPolyK(PolyK tele2 k2)
     }
     
     
-- Generalize all free variables, both Names and Pointers!

generalizeAll:: SourcePos -> Frag -> Rho -> FIO Scheme
generalizeAll pos env rho =
  do { (ptrs,names) <- getVarsRho rho
     -- ; writeln("\ngenAll  "++show rho++"\n  pointers = "++show ptrs++", names = "++show names)
     ; let namesNotToUse = map classToName names
     ; nameTele <- mapM (nameToTele env) names
     -- ; writeln("\nAll  "++show rho++"\n  pointers = "++show ptrs++", names = "++show names++"\n   "++show nameTele)
     ; let namesNotToUse = map classToName names
     ; (subst,tele) <- ptrSubst namesNotToUse ptrs nameSupply  ([],[],[])
     ; body <- rhoSubb pos subst rho 
     ; nameTele2 <- teleSubb pos subst nameTele
     -- ; writeln("\nbody = "++show body++",  "++show (tele++nameTele2)++"\n subst = "++show subst)
     ; ordered_tele <- orderTele (tele++nameTele2)
     ; return(Sch ordered_tele body)
     }
            





--------------------------------------------------------------------
-- Typing Literals

tcLit ::  SourcePos -> Literal -> Expected Rho -> FIO(Literal,TEqual)
tcLit loc x@(LInt n) expect = zap loc x (Tau tint) expect
tcLit loc x@(LInteger n) expect = zap loc x (Tau tinteger) expect
tcLit loc x@(LDouble n) expect = zap loc x (Tau tdouble) expect
tcLit loc x@(LChar c) expect = zap loc x (Tau tchar) expect
tcLit loc x@(LUnit) expect = zap loc x (Tau tunit) expect

-- zap pos term rho expect  ----> p  means  rho => expect
zap :: Show term => SourcePos -> term -> Rho -> Expected Rho -> FIO(term,TEqual)
zap loc term rho (Check r) = do { p <- morepolyRRT loc message rho r; return (term,p) }
  where message = ["\nChecking that term '"++show term++"' has type '"++show r++"'"++"\nwhen its really has type '"++show rho++"'."]
zap loc term rho (Infer r) = do { a <- zonkRho rho; fio(writeIORef r a); return(term,TRefl (rhoToTyp a)) }


-------------------------------------------

inferPat :: SourcePos -> Frag -> Pat -> FIO(Scheme,Frag,Pat)
inferPat pos k (PAnn p s) = 
  do { sch <- wellFormedScheme 0 pos [] k s
     ; (k2,p2) <- bindPat (loc p) k sch p
     ; sch2 <- zonkScheme sch
     ; return(sch2,k2,p2)}
inferPat pos k pat =
  do { rho <- freshRho Star
     ; (k2,p2) <- bindPat (loc pat) k (monoR rho) pat
     ; rho2 <- zonkRho rho
     ; return (monoR rho2,k2,p2)}

bindPat :: SourcePos -> Frag -> Scheme -> Pat -> FIO(Frag,Pat)
bindPat pos k sigma pat =  
  let message = "\nChecking that "++show pat++" has type "++show sigma
  in case pat of
      (PVar (v@(Nm(var,pos))) _) ->
          do { let ans = addTermVar v sigma LamBnd k
             ; return(ans,PVar (Nm(var,pos)) (Just(schemeToTyp sigma)))}    
      (PLit pos x) -> 
          do { let (t,y) = inferLit x
             ; p <- morepolySRT pos [message] sigma (Tau t)
             ; return (k,PLit pos y) }              
      (PTuple ps) -> 
          do { zs <- sigmaTuple pos (length ps) sigma
             ; (ps2,ans) <- bindPats pos k (zip ps zs)
             ; return(ans,PTuple ps2)}             
      (PCon (c@(Nm(_,pos2))) ps) ->
          do { (polyk,exp) <- lookupVar c k
             ; (vs,rho) <- existInstance polyk
             ; (pairs,range) <- constrRange pos2 c ps rho []
             ; p <- morepolySRT pos [message] sigma (Tau range)
             ; (ps2,k2) <- bindPats pos2 k pairs
             ; return(addExQuant vs k2,PCon c ps2)  }      
      (PWild p) -> return(k,PWild p)    

-- bindPatList :: SourcePos -> Frag -> [(Pat, Scheme)] -> FIO ([Pat], Frag)
                   
bindPats pos k [] = return([],k)
bindPats pos k ((pat,scheme):more) = 
  do { (frag1,p) <- bindPat pos k scheme pat
     ; (ps,frag2) <- bindPats pos frag1 more
     ; return(p:ps,frag2) }

constrRange loc c [] rho pairs =
  do { tau <- okRange c rho; return(reverse pairs,tau)}
constrRange loc c (p:ps) t pairs =
   do { (dom,rng,proof) <- unifyFunT loc ["Too many arguments to constructor "++show c] t
      ; constrRange loc c ps rng ((p,dom):pairs)}

okRange c (Tau t) = help t
  where help (TyCon syn nm polykind) = return t
        help (TyApp f x) = help f
        help t = fail ("\nNon type constructor: "++show t++" as range of constructor: "++show c)
okRange c rho = fail ("\nNon tau type: "++show rho++" as range of constructor: "++ show c)

 
checkBindings loc frag0 pats rho =
  do { (ptrs,names) <- foldM (accumBy getVarsAnnPat) ([],[]) pats
     ; checkBs loc frag0 pats rho }


checkBs
  ::    SourcePos
     -> Frag
     -> [Pat]
     -> Rho
     -> FIO (Frag, [Pat], [Scheme], Rho)
checkBs pos frag0 [] result = return(frag0,[],[],result) 
checkBs pos frag0 (p:ps) rho =
  do { (dom,rng,equalProof) <- unifyFunT (loc p) ["\nChecking lambda patterns "++show (p:ps)++ " are a function"] rho
     ; (frag1,p1) <- bindPat (loc p) frag0 dom p
     ; (frag2,ps2,ts,rng3) <- checkBs pos frag1 ps rng
     ; return(frag2,p1:ps2,dom:ts,rng3)
     }

inferBindings inDefDecl loc frag0 pats =
  do { (ptrs,names) <- foldM (accumBy getVarsAnnPat) ([],[]) pats

     ; let inScope = scopednames frag0
           unbound = names \\ inScope
     ; when (not(null unbound) && inDefDecl)  -- all type variables must be bound in a Def
            (fail ("\nError "++near pats++
                   "The variables "++plistf showClass "" unbound "," " "++
                   "in pattern typing\n   "++plistf show "" pats " " ""++
                   "\nare not bound."))
            
     ; binders <- mapM freshClass names
     ; frag1 <- addAnnMulti binders frag0
     ; inferBs loc frag1 pats }
     
inferBs :: SourcePos -> Frag -> [Pat] -> FIO ([Scheme], Frag, [Pat])
inferBs env k [] = return([],k,[])
inferBs env k (p:ps) =
  do { (rho,k2,p2) <- inferPat env k p
     ; (rhos,k3,ps2) <- inferBs env k2 ps
     ; return(rho:rhos,k3,p2:ps2)}

---------------------------------

applyTyp exp [] = exp
applyTyp exp ts = AppTyp exp ts

abstractTyp [] exp = exp
abstractTyp ts exp = AbsTyp ts exp

tyConArity:: Name -> Frag -> FIO(MuSyntax,Int)
tyConArity c env = 
  do { (Sch _ rho,exp) <- lookupVar c env
     ; let arity (Rarr x y) = 1 + arity y
           arity (Tau (TyArr x y)) = 1 + arity (Tau y)
           arity x = 0
           mu = case DM.lookup c (table env) of  
                 Just(ECON(sch,str,mu)) -> mu
                 other -> None
     ; return(mu,arity rho)}

smartApp:: TExpr -> TExpr -> FIO TExpr
smartApp x y = do { m <- pruneE x; (help m) } where
  help x = return(TEApp x y) 
{-  
  help (TECon mu c (Rarr dom rng) arity xs) | length xs < arity =
     do { -- actual <- checkExp y
          -- ; let mess = "\nChecking the constructor argument:\n   "++show y++": "++show actual++"\nhas expected type:\n   "++show dom
          -- ; morepolySS (loc y) [mess] (Sch [] actual) dom 
        ; return(TECon mu c rng arity (xs++[y]))}
-}

------------------------------------------

expandExprSyn env x xs = 
      case x of 
        (EApp f x) -> expandExprSyn env f (x:xs)   
        (EVar nm) -> help nm
        (EFree nm) -> help nm
        other -> Nothing
  where help nm = case DM.lookup nm (table env) of
                    Just(EVAR(InSyntax(str,arity,f))) -> Just(nm,f,xs)
                    other -> Nothing

-------------------------------------------------
lookupVar :: Name -> Frag -> FIO(Scheme,TExpr)
lookupVar (nm@(Nm(_,loc))) frag = 
    case DM.lookup nm (table frag) of 
      Just(EVAR (Normal(term,scheme))) -> do { sc2 <- zonkScheme scheme; return(sc2,term) }
      Just(EVAR (TermIndex(name,uniq,t))) -> 
         do { uniq <- fio(nextinteger)
            ; let sch = mono t
            ; return(sch,CSP(name,uniq,VCode(TEVar nm sch)))}
      Just(ECON(sch,str,mu)) -> do {sc2 <- zonkScheme sch; return(sc2,TEVar nm sc2)}
      Just(other) -> fail("\n"++show loc++" term variable: "++show nm++" used in wrong context.\n   "++show other)
      Nothing -> fail message 
  where message = "\n"++show loc++" unknown term variable: "++show nm
                  -- ++ browseFrag (Just 4) frag++"\n..."

typeLamClause env t (pat,exp) =
     do { (frag,[pat2],ts,result) <- checkBindings (expLoc exp) env [pat] t
        ; e2 <- typeExpT frag exp (Check result)
        ; escapeCheck exp t frag 
        ; return(pat2,e2) 
        } 
        
-- escapeCheck :: Show a => a -> Rho -> Frag -> FIO()
escapeCheck term typ frag =  
 do { (ptrs,names) <- getVarsRho typ
    ; let resultVars = foldr typeAccDrop [] names
    ; let bad = filter (`elem` resultVars) (existbnd frag) -- skolvars
    ; if (not (null bad))
         then (fail ("\nWhile checking the term\n   "++show term++"\nskolem variables escape "++show bad))
         else return ()
    }
  
 
rigidCheck term typ frag others =  
 do { (ptrs,names) <- getVarsRho typ
    ; let resultVars = foldr typeAccDrop others names
    ; skolvars <- namesEnv frag 
   -- ; writeln ("Rigid checking "++show typ++show resultVars++" "++show skolvars)
    ; let bad = filter (`elem` resultVars) skolvars
    ; if (not (null bad))
         then  showFrag 10 frag >>
               (fail ("\nWhile checking the term\n   "++show term++"\nskolem variables escape "++show bad))
         else return ()
    }
     


----------------------------------------------------------------
-- types for mendler operators 



-- expandOverTele  (r -> ans) [i,j,k]  ==>  (r i j k -> ans i j k)
-- expandOverTele   t [i,j,k]          ==>  (t i j k)
expandOverTele :: Typ -> Telescope -> Typ
expandOverTele x xs =  case x of 
                    (TyArr x y) -> TyArr (help x xs) (help y xs)
                    x ->  help x xs
  where help r [] = r
        help r ((nm,Kind ()):ts) = error ("Large eliminations can't abstract over kinds: "++show nm)
        help r ((nm,Type k):ts) = help (TyApp r (TyVar nm k))  ts
        help  r ((nm,Exp t):ts) = help (TyApp r (TyLift (Checked(TEVar nm (mono t))))) ts
     

{-
test = do { (ss,ts,x) <- elimTypes noPos "mall" (Karr Star Star) f r tele
                                                             -- (ElimConst) 
          ; writeln(plistf show "\n" ss "\n" "")
          ; writeln (show(ts,x)) }
  where v x = TEVar (toName x) (mono tint)
        f = (TyVar (toName "F") (Karr Star Star))
        r = (TyVar (toName "R") (Karr Star Star))
        tele = ElimFun [(toName "i",Exp(TyVar (toName "Int") Star))
                       , (toName "t",Type Star)]
                       (TyTuple Star 
                              [TyVar (toName "t") Star
                              ,TyApp (TyVar (toName "K") Star)
                                     (TyLift (Checked(TEApp (v "length") (v "i"))))])
-} 

-------------------------------------------------------------

-- expand  (r -> ans) [i,j,k]  ==>  (r i j k -> ans i j k)
-- expand   t [i,j,k]          ==>  (t i j k)
expand :: Typ -> [Typ] -> Typ
expand (TyArr dom rng) ts = TyArr (expand dom ts) (expand rng ts)
expand t ts = applyT(t:ts)


-- The pattern
-- rngVars <- getVarsRho rng                         -- compute all vars
-- namesToBind <- mapM univ (freeNames env rngVars)  -- tag and assume non-global ones
-- let rngEnv = addMulti namesToBind env             -- add to the environment



getTypesFor [] (ptrs,names) = return []
getTypesFor (x:xs) (e@(ptrs,names)) = liftM2(:)(find x names)(getTypesFor xs e) 
  where find x [] = fail ("Eliminator name: "++show x++" not mentioned in body.")
        find x (Kind y: ys) = if x==y then return(Kind y) else find x ys
        find x (Type y: ys) = if x==y then return(Type y) else find x ys
        find x (Exp y: ys)  = if x==y then return(Exp y)  else find x ys
  
teleKind [] = Star  
teleKind ((nm,Kind ()):xs) = Karr (Kname nm) (teleKind xs)
teleKind ((nm,Type k):xs) = Karr k (teleKind xs)
teleKind ((nm,Exp t):xs) = Tarr t (teleKind xs)


typeElim:: Frag -> Elim [Name] -> FIO (Elim Telescope,Kind)
typeElim env ElimConst = return(ElimConst,Star)
typeElim env (e@(ElimFun ns t)) = 
   do { allVars <- getVars t                  -- compute the Class for all vars.
      ; boundVars <- getTypesFor ns allVars   -- assign Class to only those listed.
      ; namesToBind <- mapM univ (boundVars)-- FIX ME?                     
      ; let env2 = addMulti namesToBind env   -- extend the env with these types      
      ; (t2,k) <- wellFormedType 0
                   (loc e) 
                   (["Checking wff type: "++show t++" from large elimination"]) 
                    env2  t
      ; unifyK (loc e) ["Checking wff type: "++show t++" from large elimination as result kind *"] k Star
      ; tele <- binderToTelescope namesToBind >>= zonkTele
      ; t3 <- zonk t2
      ; k <- zonkKind(teleKind tele)
      -- ; writeln ("\nTypeELIM "++show e++"\n  names bound = "++show namesToBind++ ": "++ show k)
      ; return(ElimFun tele t3,k)}

-- an eliminator like { {i} . (Nat' {i},a) }  
-- binds "i" in the body (Nat' {i},a) and 
-- expects other variables, like "a" to be in scope.

warn s = do { writeln (s++"\n\npress any key to continue ... ")
            ; fio (getChar)
            ; return ()}
   
wellFormedElim:: Int -> SourcePos -> Frag -> Elim [Typ] -> FIO (Elim (Telescope,[Class (Kind,())(Typ,Kind)(TExpr,Typ) ]),Kind)
wellFormedElim i pos env ElimConst = return(ElimConst,Star)
wellFormedElim i pos env (elim@(ElimFun ts body)) = 
  do { (_,bodyNames) <- getVars body
     ; (_,argNames) <- foldM (accumBy getVars) ([],[]) ts 
     ; let inScope = scopednames env
           freeInBody = bodyNames \\ argNames
           shadow = argNames `intersect` inScope
           notBound = freeInBody \\ inScope           
     ; when (not(null shadow))
            (warn ("\nWarning: The variables "++plistf showClass "" shadow "," " "++
                      "\nbound in the index transformer\n  "++show elim++
                      "\nshadow variables used in explicit typings."))
     ; when (not(null notBound))                      
            (warn ("\nWarning: "++near body++"The variables "++plistf showClass "" notBound "," " "++
                   "\nfrom the body of the index transformer\n  "++show elim++
                   "\nwhich are not in scope, are universally quantified."))
     ; bodyNamesToBind <- mapM univ (argNames ++ notBound)
     ; let env2 = addMulti bodyNamesToBind env
      
     ; let message x t = ["Checking wellformedness of"++x++"elim arg: "++show t]
           wft (TyLift e) = fmap Exp(wellFormedTerm (i+1) pos (message " lifted " e) env2 e)
           wft t          = fmap Type(wellFormedType (i+1) pos (message " " t)        env2 t)
     ; pairs <- mapM wft ts
     -- ; writeln("\nWellFormedElim "++show ts ++ show pairs)
     ; (body2,k2) <- wellFormedType (i+1) pos ["Checking wellformedness of elim body: "++show body] env2 body
     ; let acc (Type(t,k)) ans = Karr k ans
           acc (Exp(e,t)) ans  = Tarr t ans
           acc (Kind(k,())) ans = ans
     ; tele <- binderToTelescope bodyNamesToBind >>= zonkTele
     ; kind <- zonkKind (foldr acc k2 pairs)
     ; body3 <- zonk body2
     ; pairs2 <- mapM zonkCL pairs
    --  ; writeln("\n\nElim = "++show (ElimFun (tele,pairs2) body3)++"\nKind = "++show kind)
     
     ; return(ElimFun (tele,pairs2) body3,kind)  }  



binderToTelescope :: [(Name, Class Kind Typ TExpr)] -> FIO Telescope
binderToTelescope xs = mapM f xs
  where f (nm,Kind k) = return(nm,Kind ())
        f (nm,Type t) = liftM (nm,) (fmap Type (kindOf t))
        f (nm,Exp e) = liftM (nm,) (fmap Exp (typeOf e))



-----------------------------------------------------
-- generalization

generalizeR:: SourcePos -> Frag -> Rho -> FIO Scheme
generalizeR pos env rho =
  do { writeln("Generalizing "++show rho)
     ; envPtrs <- tvsEnv env
     ; (freePtrs,freeNames) <- getVarsRho rho
     ; let genericPtrs = freePtrs \\ envPtrs
     ; (subst@(ps,ns,ts),tele) <- ptrSubst (map classToName freeNames) genericPtrs nameSupply ([],[],[])
     ; r2 <- rhoSubb pos subst rho
     ; zonkScheme(Sch tele r2)
     }     

generalizeS:: SourcePos -> Frag -> Scheme -> FIO Scheme
generalizeS pos env (s@(Sch us rho)) =
  do { envPtrs <- tvsEnv env
     ; (freePtrs,freeNames) <- getVarsScheme s
     ; let badnames = (map classToName freeNames++ map fst us)
     ; let genericPtrs = freePtrs \\ envPtrs
     ; (subst@(ps,ns,ts),tele) <- ptrSubst badnames genericPtrs nameSupply ([],[],[])
     ; let g (nm,Kind ()) = return (nm,Kind ())
           g (nm,Type k) = do { k2 <- kindSubb pos subst k; return(nm,Type k2)}
           g (nm,Exp t) = do { t2 <- tySubb pos subst t; return(nm,Exp t2)} 
     ; vs2 <- mapM g us 
     ; sch2 <- schemeSubb pos subst (Sch (tele++vs2) rho)
     ; return sch2
     }     

mess c = ["While checking the well formedness of the type of constructor "++show c]


{-

freeNames :: Frag -> Vars -> [Class Name Name Name]
freeNames frag (ptrs,names) = filter p names
  where p (Kind x) = True
        p (Type x) = True
        p (Exp x) = case DM.lookup x (table frag) of  
                     Just(EVAR(Left _)) -> False  -- throw away names bound in scope
                     Just(EVAR(Right _)) -> False
                     Just(ECON _) -> False  -- throw away names bound in scope                     
                     other  -> True
-}

--------------------------------------------------------------------
-- functions that extend the "table" part of a frag
-- these are all called by "elab" below that extends
-- the environment for each new Decl

bindPolyPat env (Sch free rho) (PVar nm _) = (env2,PVar nm (Just (TyAll free (rhoToTyp rho))))
  where env2 = addTable EVAR (nm,Normal(TEVar nm (Sch free rho),Sch free rho)) env
bindPolyPat env sch (p@(PWild loc)) = (env,p)
bindPolyPat env sch (p@(PLit loc i)) = (env,p)
bindPolyPat env (Sch free (Tau (TyTuple _ ts))) (PTuple ps) = (env4,PTuple qs)
  where (env4,qs) = all env (map Tau ts) ps
        all env [] [] = (env,[])
        all env (t:ts) (p:ps) = (env3,q:qs)
              where (env2,q) = (bindPolyPat env (Sch free t) p)
                    (env3,qs) = all env2 ts ps
        all env _ _ = error ("Tuple pattern binding has bad type")
bindPolyPat env _ p = (env,p)

addData (mu@None) t polyk cs env = env2
  where env1 = addTable TYCON1 (t,(mu,polyk)) env
        env2 = foldr (\(c,arity,sch) e ->addTable ECON (c,(sch,"",mu)) e) env1 cs
addData (mu@(Syn r)) t polyk cs env = env4
  where env1 = addTable TYCON1 (t,(mu,polyk)) env
        env2 = foldr (\(c,arity,sch) e -> addTable ECON (c,(sch,lowercase c,Syn(lowercase c))) e) env1 cs
        env3 = foldr (\(c,arity,sch) e -> addTable EVAR (lowerName c,InSyntax(constrMacro polyk arity c (lowercase c))) e) env2 cs
        env4 = addTable TYCON2 (tyConMacro t r polyk) env3

lowercase (Nm(z:zs,pos)) = (toLower z: zs)
lowercase (Nm(x,pos)) = x

lowerName (Nm(z:zs,pos)) = Nm(toLower z: zs,pos)
lowerName x = x

checkDec:: Bool -> Frag -> Name -> FIO ()
checkDec False frag name = return ()
checkDec True frag name =
   do { write ((show name)++", ")
      ; when (defined frag name) 
             (fail ("\n"++near name++"The declaration of "++show name++
                    " is already in scope.\nOther definitions occur at"++
                    plistf show "\n  " (namePositions frag name) "\n  " ""))
      ; return () }
                       
elab :: Bool -> Frag -> Decl Expr -> FIO (Frag,Decl TExpr)
elab toplevel env (GADT pos t kind cs derivs) = 
  do { checkDec toplevel env t 
     -- if toplevel then write ((show t)++", ") else return()
     ; (kind2,newvs) <- wfGadtKind pos ["checking gadt "++show t++":"++show kind] env kind
     ; ktele <- binderToTelescope newvs
     ; let polykind = PolyK ktele kind2 -- <- generalizeK pos env kind2     
     -- ; writeln("\nELAB kind = "++show polykind++",   "++show newvs)
     ; let doOneCon (c,(v:vs),doms,rng) = fail "No foralls in constructor yet"
           doOneCon (c,[],doms,rng) = 
             do { rngVars <- getVarsRho rng
                ; allVars <- foldM (accumBy getVarsScheme) rngVars doms
                ; namesToBind <- mapM univ (snd allVars) -- (freeNames env allVars)
                ; let domEnv = addMulti namesToBind env
                ; doms2 <- mapM (wellFormedScheme 0 pos (mess c) domEnv) doms
                ; zzzVars <- foldM (accumBy getVarsScheme) ([],[]) doms2
                ; let rangeEnv = addTable TYCON1 (t,(syntax derivs,polykind)) domEnv
                ; rng2 <- wellFormedRho 0 pos (mess c) rangeEnv rng     
                
                
                ; let wholetype = (foldr Rarr rng2 doms2)
                ; zs <- getVarsPolyK polykind
               -- ; writeln("\nGADT "++show t++", constr  "++show c++" allVars = "++show allVars++
               --           "\n wholetype = "++show wholetype++" polyk "++show polykind++show zs)
               
                ; sch <- generalizeAll pos rangeEnv wholetype
                ; vars <- getVarsRho wholetype
                -- ; writeln("\nGADT constr "++show c++": "++show sch)
                               
                ; return((c,map fst namesToBind,doms2,rng2),sch) }
               
     ; cs2 <- mapM doOneCon cs
     ; let conScheme ((c,_,ds,r),sch) = return (c,length ds,sch)
             -- do { tele <- binderToTelescope vs
             --    ; liftM (c,length ds,) (zonkScheme(Sch tele (foldr Rarr r ds)))} 
     
     ; cs3 <- mapM conScheme cs2
     -- ; writeln("\nELAB kind = "++show polykind++",   "++plistf show "\n " cs3 "\n  " "\n")
     ; let env4 = addData (syntax derivs) t polykind cs3 env 
     ; return(env4,GADT pos t kind2 (map fst cs2) derivs)}
     
elab toplevel env (d@(DataDec pos tname args cs derivs)) = 
  do { checkDec toplevel env tname 
       -- if toplevel then write ((show tname)++", ") else return()
     ; tkind <- freshKind                                   -- data Seq r s a =  Con (s a) (r a)
     ; tcon <- return(TyCon (syntax derivs) tname (PolyK [] tkind))    -- Seq   as a Typ
     ; argTele <- mapM (univ . Type) args                   -- [(r,r:k1),(s,s:k3),(a,a:k5)]
     ; let build [] = return(Star,[]::Telescope,[])
           build ((nm,Type t):more) =
             do { k <- kindOf t;
                ; (ans,ks,ts) <- build more
                ; return(Karr k ans,(nm,Type k):ks,t:ts)}
     ; (protoKind,ks,ts) <- build argTele 
            -- protokind = k1 -> k3 -> k5 -> *
            -- ks = [(r,k1),(s,k3),(a,k5)]
            -- ts = [a,s,r]
     ; let range = applyT (tcon:ts)  -- range = Seq a s r
           conEnv = addMulti argTele env  -- extends the environment
           doOneCon (c,domains) = 
              do { ds <- mapM (wellFormedScheme 0 (loc c)(mess c)conEnv) domains
                 ; mono <- zonkRho (foldr Rarr (Tau range) ds)
                 ; checkRho (loc c) (mess c) mono Star
                 ; return(c,ds,Sch ks mono)}
     ; cs2 <- mapM doOneCon cs
     ; unifyK pos ["checking "++show tname++" has a consistent Kind."] tkind protoKind  
     ; cs3 <- mapM (\(c,ds,sch) -> liftM (c,length ds,) (generalizeS pos env sch)) cs2
     ; polykind <- generalizeK pos env tkind 
     ; let env4 = addData (syntax derivs) tname polykind cs3 env
     ; return(env4,(DataDec pos tname args (map (\(c,ds,sch)->(c,ds)) cs2) derivs)) }
     
elab toplevel env (d@(Def loc p e)) =
  do { if toplevel then write ((show p)++", ") else return()
     -- ; let vars = patBinds p [] 
     ; ([scheme1@(Sch vs rho4)],env2,[pat2]) <- inferBindings True loc env [p]
     ; (rho,exp2) <- inferExpT env e
     ; free <- tvsEnv env
     ; (scheme2,sub) <- generalizeRho free rho
     ; let mess = "The type of the pattern, "++show pat2++"\n   "++
                  show scheme1++"\nis too polymorphic for the infered type\n   "++show scheme2++
                  "\nof the expression\n   "++show e
     ; (p1) <- morepolySST loc [mess] scheme2 scheme1
     ; let subst = (sub,[],[]) 
     ; p2 <- eqSubb loc subst p1
     ; exp3 <- expSubb loc subst exp2

     ; exp4 <- zonkExp (teCast (tGen vs p2) exp3) 
     ; sch <- zonkScheme scheme1
     ; sch2 <- zonkScheme scheme2
     ; writeln("elab DEF "++show scheme1++"\n  "++show sch++"\n   "++show sch2)
     ; let (env2,pat3) = bindPolyPat env scheme1 pat2
     ; return(env2,Def loc pat3 exp4) }

elab toplevel env (Axiom pos nm t) = 
  do { if toplevel then write ((show pos)++", ") else return()
     ; (ptrs,names) <- getVars t
     ; binders <- mapM univ names
     ; let env2 = addMulti binders env  
     ; (ty,k) <- wellFormedType 0 pos ["Checking kind in Axiom "++show nm] env2 t 
    
     ; tele <- binderToTelescope binders
     ; let (env3,_) =  bindPolyPat env (Sch tele (Tau ty)) (PVar nm Nothing)
     
     ; return(env3,Axiom pos nm t)
     }
  
elab toplevel env (FunDec fpos f _ clauses) = 
  do { checkDec toplevel env (Nm(f,fpos)) 
       -- if toplevel then write (f++", ") else return()
     ; typ <- freshRho Star
     ; let checkClause env typ (ps,body) = 
             do { let pos = case ps of { (p:ps) -> loc p; [] -> fpos}
                ; (schemes,env2,ps2) <- inferBindings False pos env ps 
                ; (rng,body2) <- inferExpT env2 body
                ; rng2 <- zonkRho rng
                -- ; writeln("Body type is: "++show rng2)
                ; let -- nvars = sum(map (\ p -> length(patBinds p [])) ps)
                      m = (show pos ++"\nWhile checking\n"++plistf show "" ps " " ""++
                           " -> "++show body)
                ; p <- morepolyRRT fpos [m] typ (toRho schemes rng) 
                ; return(ps2,teCast p body2)}
     ; clauses2 <- mapM (checkClause env typ) clauses
     ; t2 <- zonkRho typ
     ; free <- tvsEnv env
     -- ; writeln("BEFORE GEN\n"++show t2)
     ; (sig@(Sch vs _),sub) <- generalizeRho free t2 
     ; let subst = (sub,[],[])
     ; let g (ps,e) = do { ps2 <- mapM (patSubb (locL fpos ps) subst) ps
                         ; e2 <- expSubb (locL fpos ps) subst e
                         ; return(ps2,e2)}
     ; cls3 <- mapM g clauses2
     ; let env2 = addTable EVAR (Nm(f,fpos),Normal(TEVar (Nm(f,fpos)) sig,sig)) env
     ; return(env2,FunDec fpos f vs cls3)
     }
     
elab toplevel env (dec@(Synonym pos nm xs body)) =
  do { checkDec toplevel env nm
       -- if toplevel then write (show nm++", ") else return()
     ; (ptrs,names) <- getVars body  -- all the variables, those not in "xs" must be in the environment.
     ; let (ns,k) `acc2` (nm,Type t) = do { k2 <- kindOf t; return ((nm,k2):ns,Karr k2 k)}
           (ns,k) `acc2` (nm,Exp e) = do { t2 <-typeOf e; return ((nm,error ("Lifted exp as type: "++show t2)):ns,Tarr t2 k)}
           (ns,k) `acc2` (nm,Kind _) = fail ("Kind variable in synonym: "++show nm)
           find (Kind n : more) nm | nm==n = return(Kind n)
           find (Type n : more) nm | nm==n = return(Type n)
           find (Exp n  : more) nm | nm==n = return(Exp n)
           find (_ : more) nm = find more nm
           find [] nm = fail("Synonym arg '"++show nm++"' is not mentioned in synonym body\n"++show body)
     ; nameList <- mapM (find names) xs
     ; boundnames <- mapM univ nameList -- add classifying assumptions for only those in "xs"
     ; let env2 = addMulti boundnames env  -- extend the environment with these assumptions
     ; (body2,k) <- wellFormedType 0 pos ["Checking wff type: "++show body++"\nin type synonym:\n"++show dec] env2 body
                    -- body2 has had the variables in the global env replaced with CSP constants
     ; (_,kind) <- foldM acc2 ([],k) (reverse boundnames)     
     ; tele <- binderToTelescope boundnames
     ; let polyk = PolyK tele kind 
    --  ; writeln("\nSynonym "++show nm++show nameList++": "++show polyk++" = "++show body2)
     ; let printer = synonymPrint nm xs body2
           expander2 = synonymExpand2 nm nameList polyk body -- check body is well formed, but use the old one in the expanded
           env2 = addSyn printer env
           env4 = addTable TYCON2 (nm,expander2) env2
     ; return(env4,Synonym pos nm xs body2)}


kindArity (Karr x y) = 1 + kindArity y
kindArity x = 0

synonymExpand2 nm formals polyk body = (name nm,length formals,f)
  where f pos actuals = 
           do { -- writeln("\n "++show nm++" Formals "++show formals++"\nActuals = "++show actuals)
              ; let match [] [] = return []
                    match ((TyLift (Parsed e)): as) (Exp nm : fs) = 
                      do { zs <- match as fs; return((nm,Exp e):zs)}
                    match (a : as) (Type nm : fs) = 
                      do { zs <- match as fs; return((nm,Type a):zs)}
                    match _ _ = fail
                      (show pos++"\nError ***\nBad type synonym application.\n  "++
                           plistf id (show nm++" ") (map show actuals) " " "\n"++show formals)
              ; zs <- match actuals formals
              ; body2 <- subTyp zs body      
              ; zonk(TySyn nm (length formals) actuals body2) }
        

-------------------------------------------------------------------------------
-- Look at the following fix point syntax definitions
-- Nat = Mu N                  (0,0)  where N: * -> *
-- List a = Mu (L a)           (1,0)  where L: * -> * -> *
-- Tree x y = Mu (T x y)       (2,0)  where T: * -> * -> * -> *
-- Vector a n = Mu (IL a) n    (1,1)  where IL: (* -> Nat -> *) -> Nat -> *
-- Proof t i = Mu P t i        (0,2)  where P: (Tag -> Nat -> *) -> Tag -> Nat -> *
-- note that some arguments are applied to the Type Constructor before 
-- the application of Mu, and some after. There is a pair of integers
-- that can be computed by inspecting the kind. 'runcount' does this

runcount t k = collect t k [] k
collect t all xs (Karr x y) | x==y = (x,length xs,kindArity x)
collect t all xs (Karr x y) = collect t all (x:xs) y
collect t all xs k = error("\n"++show t++" does not have a kind that supports fixpoint: "++show all)

tyConMacro tname rname (polyk@(PolyK tele k)) = (augment tname rname (", syntax for "++show tname)
                                             ,(str,before+after,f))
  where (k4,before,after) = runcount (name tname) k
        tType = (TyCon (Syn rname) tname polyk)
        showType = (TyCon None tname polyk)  -- when we browse we want the In form to print, so use None.
        build tType xs = 
          do { k5 <- instanK noPos (PolyK tele k4)
             ; let muarg = applyT (tType : take before xs)
             ; return(applyT ((tyMu k5): muarg : (drop before xs)))}
        typ x = TyVar x Star       
        args = take (before+after) nameSupply
        str = rname++plistf show " " args " " " = "++show(build showType (map typ args))
        f pos xs = build tType xs
                  

             
toRho [] range = range
toRho (t:ts) range = arr t (toRho ts range)
  where arr (Sch [] (Tau dom)) (Tau rng) = Tau(arrT dom rng)
        arr sch rho = Rarr sch rho

--  macroName x1 x2 x3 = In[k] (ConstrName x1 x2 x3)
constrMacro kind arity cname mname = (mname,arity,f)
  where body pos k xs = return(EIn k (applyE (ECon (relocate cname pos) : xs)))
        f pos xs = 
           do { monokind <- instanK noPos kind
              ; let (kind2,_before,after) = runcount "T" monokind
              -- ; body2 <- (body pos kind2 xs)
              ; case compare (length xs) arity of
                  EQ -> (body pos kind2 xs)
                  LT -> do { let names = take (arity - length xs) nameSupply
                                 abstract [] x = x
                                 abstract (n:ns) x = EAbs ElimConst [(PVar n Nothing,abstract ns x)]                            
                           ; body2 <- body pos kind2 (xs++ map EVar names)
                           ; return(abstract names body2)}
                  GT -> (fail ("\n"++show pos++"\nConstructor function synonym: "++show mname++
                               "\nshould be applied to "++show arity++" arg(s). "++
                               (plistf id "\n  (" (mname : map show xs) " " ")")))
              }
             
                    

write x = fio(putStr x) 
writeln x = fio(putStrLn x)


--------------------------------------------------------
-- Given a telescope ( (x1:k1) (x2:k2) ... (xn:kn) . body),
-- which is a function with kind k1 -> k2 ... -> kn, 
-- return an instantiated version of the body, along with 
-- the new variables y1 y2 ... yn  which are either 
-- existentially or universally quantified,
 

teleToAbstractSubst:: SourcePos -> Telescope -> FIO(SubEnv,[Typ])
teleToAbstractSubst pos xs = 
   do{ subst@(_,names,_) <- rigidTele pos xs ([],[],[]) 
     ; ts <- teleToTyList names
     ; return(subst,ts) }

teleToFreshSubst :: SourcePos -> Telescope -> FIO(SubEnv,[Typ])         
teleToFreshSubst pos tele  =
   do{ subst@(_,names,_) <- freshenTele pos tele ([],[],[]) 
     ; ts <- teleToTyList names
     ; return(subst,ts) }


  
----------------------------------------------------------------------



tyConMap = map g predefinedTyCon ++ predefinedSyn
  where g (s,TyCon syn nm k) = (nm,Left (syn,k))
  
tyConTable = DM.fromList (map g predefinedTyCon)
  where g (s,TyCon syn nm k) = (nm,TYCON1 (syn,k))
   
predefinedSyn =
          [(toName "List",Right(1::Int,f))
          ,(toName "Nat",Right(0,g))
         -- ,(toName "P" ,Right(2,h))
          ]
   where f nm [(x,k)] = do { unifyK noPos ["Type synonym List arg is well kinded"] k Star
                        ; return(TySyn nm 1 [x] (listT x))}
         g nm [] = return(TySyn nm 0 [] nat)
         

 


interAct tcEnv expect = 
  do { ex <- extract expect
     ; write "\ncheck> "
     ; s <- fio getLine
     ; if s== ":q"
          then return ()
          else do {
     ; exp <- parseExpr s
     ; (rho,exp2) <- inferExpT tcEnv exp
     ; r2 <- zonkRho rho
     ; free <- tvsEnv tcEnv
     ; (sch,vs) <- generalizeRho free r2
     ; sch2 <- zonkScheme sch
     ; exp3 <- zonkExp exp2
     ; let pi = ppinfo tcEnv
     ; writeln(render(ppRho pi r2))
     ; interAct tcEnv expect
     }}

---------------------------------------------------------
-- TEqual stuff
-----------------------------------------------------------

inferExpT :: Frag -> Expr -> FIO (Rho, TExpr)
inferExpT env e = 
  do { r <- fio(newIORef (Tau (TyVar (Nm("?",noPos)) Star)))
     ; e' <- typeExpT env e (Infer r)
     ; rho <- fio (readIORef r)
     ; return(rho,e') }

typeExpT :: Frag -> Expr -> Expected Rho -> FIO TExpr
typeExpT env (ELit loc x) expect = 
     do { (x',p) <- tcLit loc x expect
        ; return (teCast p (TELit loc x')) }
        
typeExpT env (e@(EVar _)) expect 
     | Just(c,f,xs) <- expandExprSyn env e []
     = do { e2 <- f (loc e) xs
          ; typeExpT env e2 expect}
typeExpT env (e@(EVar (v@(Nm(s,loc))))) expectRho =
     do { (polyk,exp) <- lookupVar v env
        ; let mess = "\nChecking the variable:\n   "++show e++": "++
                     show polyk++"\nhas expected type:\n   "++show expectRho
        ; (ts,p) <- morepolySExpectR_ loc [mess] polyk expectRho
        ; return (teCast p exp) } -- (applyTyp exp ts)}  
typeExpT env (e@(EFree nm)) expect 
   | Just(c,f,xs) <- expandExprSyn env e [] 
   = do { e2 <- f (loc e) xs
        ; typeExpT env e2 expect }
typeExpT env (e@(EFree nm)) expectRho =
     do { (polyk,exp) <- lookupVar nm env
        ; let mess = "\nChecking the variable:\n   "++show e++": "++show polyk++"\nhas expected type:\n   "++show expectRho
        ; (ts,p) <- morepolySExpectR_ (loc nm) [mess] polyk expectRho
        -- ; writeln("\ntypeExpT EFRee "++show e++show (values env))
        ; case lookup nm (values env) of
            Just(Exp t) -> return (teCast p t)
            Nothing -> fail("\n"++near nm++"Variable marked as bound in the global environment: "++show nm++" is not n scope.")
        }         
typeExpT env (e@(ECon c)) expectRho = 
     do { (polyTyp,TEVar nm sc2) <- lookupVar c env
        ; (mu,n) <- tyConArity c env
        ; let mess = "\nChecking the constructor:\n   "++show e++": "++show polyTyp++"\nhas expected type:\n   "++show expectRho
        ; (ts,p) <- morepolySExpectR_ (loc c) [mess] polyTyp expectRho
        ; rho <- extract expectRho
        -- note we discard p, because each occurrence of a Constructor is given a monomorphic type, rho.
        ; return (TECon mu nm rho n)}     
typeExpT env (e@(EApp _ _)) expect 
     | Just(c,f,xs) <- expandExprSyn env e []
     = do { e2 <- f (loc e) xs
          ; typeExpT env e2 expect}
typeExpT env (e@(EAnn CheckT x)) expect = 
     do { writeln("\n"++near x++"Enter Type Checking Breakpoint\n   "++show x)
        ; writeln ("Expected Type\n   "++show expect)
        ; interAct env expect
        ; typeExpT env x expect }
typeExpT env (e@(EApp fun arg)) expect =
     do { (fun_ty,f) <- inferExpT env fun
        ; (arg_ty, res_ty,p1) <- unifyFunT (expLoc arg) ["\n1 While checking that "++show fun++" is a function "++near arg] fun_ty
        ; let cast (e@(TECon mu nm rho n)) = e  -- Don't cast a monomorphic Constructor
              cast e = teCast p1 e
        ; let mkTrans i t msg = do { ft <- zonkRho fun_ty; tt <- zonkScheme t; ex <- zonkExpRho expect;
                                     return(unlines [msg,"Infering the type of  the application\n   "++show e++
                                       "\nthe function '"++show fun++"'  has type\n   "++show ft++
                                       "\nthe argument '"++show arg++"' was not consistent."])}
        ; case arg_ty of
           Sch [] argRho -> do { x <- handleMM (typeExpT env arg (Check argRho))
                                               (mkTrans 0 arg_ty)
                               ; tt <- zonkRho argRho
                               ; m1 <- mkTrans 1 arg_ty ""
                               ; p2 <- morepolyRExpectR_ (expLoc arg) [m1] res_ty expect                               
                               ; eprime <- (smartApp (cast f) x)
                               ; return(teCast p2 eprime)}
           sigma -> do { (ty,x) <- handleMM (inferExpT env arg) (mkTrans 2 sigma)
                       ; free <- tvsEnv env
                       ; (sig,sub) <- generalizeRho free ty
                       ; sigma2 <- zonkScheme sigma >>= alpha
                       ; m3 <- mkTrans 3 sigma ""
                       ; let m2 =["\nWhile checking the type of the application\n  "++show e ++
                                  "\nThe argument: "++show arg++" with type\n  "++
                                  show sig++"\nis expected to be polymorphic\n  "++
                                  show sigma2]
                       ; p3 <- morepolySST (expLoc arg) m2 sig sigma2
                       ; m4 <- mkTrans 4 sigma ""
                       ; p4 <- morepolyRExpectR_ (expLoc arg) [m4] res_ty expect
                       -- Do some stuff with p3 and p4 here
                       ; smartApp (cast f) x }
        }
typeExpT env (EAbs elim ms) (Check t) = 
  do { (elim2,_) <- typeElim env elim
     -- ; writeln ("\nEntering type lambda (Check "++show t++")")
     ; pairs <- mapM (typeLamClause env t) ms
     ; return(TEAbs elim2 pairs)}
typeExpT env (EAbs elim ((pat,exp):ms)) (Infer ref) =
  do { (elim2,_) <- typeElim env elim
     -- ; writeln ("\nEntering type lambda (Infer ref)")
     ; ([dom],env2,[pat2]) <- inferBindings False (expLoc exp) env [pat]
     ; (rng,exp2) <- inferExpT env2 exp 
     ; let expected = (Rarr dom rng)
     ; fio(writeIORef ref expected)
     ; pairs <- mapM (typeLamClause env expected) ms
     ; return(TEAbs elim2 ((pat2,exp2):pairs)) }
typeExpT env (ETuple xs) expect =
  do { zs <- isTuple (expLoc (head xs)) (length xs) expect
     ; let f (term,tau) = typeExpT env term (Check (Tau tau))
     ; xs2 <- mapM f (zip xs zs)     
     ; return(TETuple xs2) } 
typeExpT env (ELet d e) expect =
  do { (env2,d2) <- elab False env d
     ; e2 <- typeExpT env2 e expect
     ; return(TELet d2 e2)}

typeExpT env (term@(EIn k x)) expect =  
  do { kind <- wfKind 0 (loc x) ["Checking well formedness of kind from In term\n   "++show term] env k
     ; (dom,rng) <- inType kind
     ; x2 <- typeExpT env x (Check (Tau dom))
     ; let message = [near x++"\nTyping the In term: "++show (EIn kind x)]
     ; p1 <- morepolyRExpectR_ (expLoc x) message (Tau rng) expect
     ; return (teCast p1 (TEIn kind x2))}  
typeExpT env (term@(EMend tag elim x ms)) expect =
  do { (elim2,k) <- wellFormedElim 0 (loc x) env elim
     ; f <- freshType (Karr k k)
     ; (Type (r@(TyVar rname rkind))) <- existTyp (Nm("r",loc x)) (Type k)
     ; (ops,input,output) <- elimTypes (loc x) tag k f r elim2   
     ; i2 <- zonk input
     ; x2 <- typeExpT env x (Check(Tau input))
     ; ms2 <- mapM (\ m -> typeOperClause rname rkind env env ops m []) ms
     ; p1 <- morepolyRExpectR_ (loc x) 
             ["Checking the return type of the mendler operator:\n"++show term] 
             (Tau output) expect   
     ; zonkExp(teCast p1 (TEMend tag elim2 x2 ms2))} 
typeExpT env term expect = error ("\nNot yet in typeExpT\n  "++ show term)

------------------------------------------    

elimParts ElimConst = do { ans <- freshType Star; return([],[],ans)}
elimParts (ElimFun (tele,xs) body) = return(tele,xs,body)

elimTypes:: SourcePos -> String -> Kind -> Typ -> Typ -> Elim (Telescope,[Class (Kind,())(Typ,Kind)(TExpr,Typ) ])  -> FIO ([Scheme],Typ,Typ)
elimTypes pos tag k f r elim = 
   do{ (xs,args,ans) <- elimParts elim
     ; subst@(_,names,_) <- freshenTele pos xs ([],[],[]) 
     -- ; writeln("\nTele = "++show xs++"\nFresh "++show names)
     ; let namepart (Exp(e,t)) = TyLift (Checked e)
           namepart (Type(t,k)) = t
     ; ts <- return(map namepart args)  
      
     ; output <- tySubb pos subst ans
     ; input <- tySubb pos subst (expand(TyApp (tyMu k) f) ts)
 
     ; let caller = Sch xs (Tau(arrT (expand r ts) ans))
           out = Sch xs (Tau(expand (arrT r (TyApp f r)) ts))
           cast = Sch xs (Tau(expand(arrT r (TyApp (tyMu k) f)) ts))
           uncast = Sch xs (Tau(expand(arrT (TyApp (tyMu k) f) r) ts))           
           inverse = Sch xs (Tau(arrT ans (expand r ts)))
           struct =  Sch xs (Tau(arrT (expand(TyApp f r) ts) ans))          
           
     ; case tag of
        "mcata" -> return([caller,struct],input,output) 
        "mhist" -> return([caller,out,struct],input,output) 
        "mprim" -> return([caller,cast,struct],input,output) 
        "msfcata" -> return([caller,inverse,struct],input,output) 
        "msfprim" -> return([caller,inverse,cast,struct],input,output)
        "mprsi" -> return([caller,cast,uncast,struct],input,output)
        "mall" -> return([caller,out,cast,inverse,struct],input,output) 
     }
        
showPointer (Kind(u,p))   = "k"++show u
showPointer (Type(u,p,k)) = "t"++show u
showPointer (Exp(u,p,k))  = "e"++show u

showPtrs ps = plistf showPointer "[" ps "," "]"
      
typeOperClause:: Name -> Kind -> Frag -> Frag -> [Scheme] -> ([Pat], Expr) -> [Pat] -> FIO(Telescope,[Pat], TExpr)
typeOperClause r rkind oldenv env [sch] ([p],body) qs = 
  do { (rho,names) <- instantiate sch
  -- ; (names,ts,rho) <- rigidize sch
     ; (sch2,rho2,proof1) <- unifyFunT noPos ["Typing body of mcata"] rho
     ; (env2,pat2) <- bindPat (loc p) env sch2 p
     ; body2 <- typeExpT env2 body (Check rho2)
     ; (ptrs,_) <- getVarsRho (Rarr sch2 rho2)
     ; pat3 <- zonkPat pat2
     ; sch3 <- zonkScheme sch2
     ; rho3 <- zonkRho rho2
     ; free <- tvsEnv env
     
     ; (sigma@(Sch tele _),sub) <- generalizeRho free (Rarr sch2 rho2)
     ; let tele2 = (r,Type rkind):tele  -- Add the existential r to the telescope
     ; let subst = (sub,[],[])
     ; body3 <- expSubb (loc body2) subst body2
     ; pat3 <- patSubb (loc pat2) subst pat2

     ; rigidCheck body rho2 oldenv [r]  --- r is the type (an existenial type variable) of the abstract carrier
     ; return(tele2,reverse(pat3:qs),teCast proof1 body3) }
typeOperClause ans rkind oldenv env [sch] (p:ps,body) qs = typeOperClause ans rkind oldenv env [sch] ([p],abstract ps body) qs
typeOperClause ans rkind oldenv env (t:ts) (p:ps,body) qs = 
   do { (env2,p2) <- bindPat (loc p) env t p
      ; typeOperClause ans rkind oldenv env2 ts (ps,body) (p2:qs) }

-------------------------------------------------------------------     
morepolySExpectR_ :: SourcePos -> [String] -> Scheme -> Expected Rho -> FIO ([Typ],TEqual)    
morepolySExpectR_ loc mess sig (Check rho) = morepolySRT loc mess sig rho
morepolySExpectR_ loc mess sig (Infer r) = 
   do { (rho,newts) <- instantiate sig
      ; fio(writeIORef r rho)
      -- ; writeln("Morepoly "++show sig ++ show newts)
      ; return(newts,tSpec sig newts)}

www = (Sch [(n,Type Star)] (Tau(TyArr (TyVar n Star) (TyVar n Star))))
  where n = toName "x"
      
morepolyRExpectR_ :: SourcePos -> [String] -> Rho -> Expected Rho -> FIO TEqual     
morepolyRExpectR_ loc mess r (Check rho) = morepolyRRT loc mess r rho
morepolyRExpectR_ loc mess rho (Infer r) = fio(writeIORef r rho) >> return (TRefl (rhoToTyp rho))
     
     
     
        
        
        


----------------------------------------------------------
-- unifyExpect :: [String] -> Typ -> Expected Typ -> FIO TEqual
-- unifyExpect mess x (Check t) = do { p <- unifyT mess Pos x t; zonkTEqual p}
-- unifyExpect mess x (Infer ref) = do { fio(writeIORef ref x); zonkTEqual(TRefl x) }


