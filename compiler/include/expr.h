/*
 * Copyright 2004-2017 Cray Inc.
 * Other additional copyright holders may be indicated within.
 *
 * The entirety of this work is licensed under the Apache License,
 * Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License.
 *
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef _EXPR_H_
#define _EXPR_H_

#include "baseAST.h"

#include "primitive.h"
#include "symbol.h"

#include <ostream>

class PrimitiveOp;


class Expr : public BaseAST {
public:
                  Expr(AstTag astTag);
  virtual        ~Expr();

  // Interface for BaseAST
  virtual bool    inTree();
  virtual bool    isStmt()                                           const;
  virtual QualifiedType qualType();
  virtual void    verify();

  // New interface
  virtual Expr*   copy(SymbolMap* map = NULL, bool internal = false)   = 0;
  virtual void    replaceChild(Expr* old_ast, Expr* new_ast)           = 0;

  virtual Expr*   getFirstChild()                                      = 0;

  virtual Expr*   getFirstExpr()                                       = 0;
  virtual Expr*   getNextExpr(Expr* expr);

  virtual bool    isNoInitExpr()                                     const;

  virtual void    prettyPrint(std::ostream* o);


  bool            isRef();
  bool            isWideRef();
  bool            isRefOrWideRef();

  /* Returns true if the given expression is contained by this one. */
  bool            contains(const Expr* expr)                         const;

  bool            isModuleDefinition();

  void            insertBefore(Expr* new_ast);
  void            insertAfter(Expr* new_ast);
  void            replace(Expr* new_ast);

  void            insertBefore(AList exprs);
  void            insertAfter(AList exprs);

  void            insertBefore(const char* format, ...);
  void            insertAfter(const char* format, ...);
  void            replace(const char* format, ...);

  Expr*           remove();

  bool            isStmtExpr()                                       const;
  Expr*           getStmtExpr();

  BlockStmt*      getScopeBlock();

  Symbol*         parentSymbol;
  Expr*           parentExpr;

  AList*          list;           // alist pointer
  Expr*           prev;           // alist previous pointer
  Expr*           next;           // alist next     pointer

private:
  virtual Expr*   copyInner(SymbolMap* map) = 0;
};


class DefExpr : public Expr {
public:
                  DefExpr(Symbol*  initSym      = NULL,
                          BaseAST* initInit     = NULL,
                          BaseAST* initExprType = NULL);

  virtual void    verify();

  DECLARE_COPY(DefExpr);

  virtual void    replaceChild(Expr* old_ast, Expr* new_ast);
  virtual void    accept(AstVisitor* visitor);

  virtual QualifiedType qualType();
  virtual void    prettyPrint(std::ostream* o);

  virtual GenRet  codegen();

  virtual Expr*   getFirstChild();

  virtual Expr*   getFirstExpr();

  const char*     name()                               const;

  Symbol*         sym;
  Expr*           init;
  Expr*           exprType;
};


class SymExpr : public Expr {
 private:
  Symbol* var;

 public:
  // List entries to support enumerating SymExprs in a Symbol
  // These are public because:
  //  * they are managed in Symbol (but could friend class Symbol)
  //  * they are used in for_SymbolSymExprs (but could create a real iterator)
  SymExpr* symbolSymExprsPrev;
  SymExpr* symbolSymExprsNext;

  SymExpr(Symbol* init_var);

  DECLARE_COPY(SymExpr);

  virtual void    replaceChild(Expr* old_ast, Expr* new_ast);
  virtual void    verify();
  virtual void    accept(AstVisitor* visitor);

  virtual QualifiedType qualType();
  virtual bool    isNoInitExpr() const;
  virtual GenRet  codegen();
  virtual void    prettyPrint(std::ostream* o);

  virtual Expr*   getFirstChild();

  virtual Expr*   getFirstExpr();

  Symbol* symbol() {
    return var;
  }

  void setSymbol(Symbol* s);
};


class UnresolvedSymExpr : public Expr {
 public:
  const char* unresolved;

  UnresolvedSymExpr(const char* init_var);

  DECLARE_COPY(UnresolvedSymExpr);

  virtual void    replaceChild(Expr* old_ast, Expr* new_ast);
  virtual void    verify();
  virtual void    accept(AstVisitor* visitor);
  virtual QualifiedType qualType();
  virtual GenRet  codegen();
  virtual void    prettyPrint(std::ostream *o);

  virtual Expr*   getFirstChild();

  virtual Expr*   getFirstExpr();
};



// Note -- isCallExpr() returns true for CallExpr and also
// ContextCallExpr. Therefore, it is important to use toCallExpr()
// instead of casting to CallExpr* directly.
class CallExpr : public Expr {
public:
  PrimitiveOp* primitive;        // primitive expression (baseExpr == NULL)
  Expr*        baseExpr;         // function expression

  AList        argList;          // function actuals

  bool         partialTag;
  bool         methodTag;        // Set to true if the call is a method call.
  bool         square;           // true if call made with square brackets

  CallExpr(BaseAST*     base,
           BaseAST*     arg1 = NULL,
           BaseAST*     arg2 = NULL,
           BaseAST*     arg3 = NULL,
           BaseAST*     arg4 = NULL,
           BaseAST*     arg5 = NULL);

  CallExpr(PrimitiveOp* prim,
           BaseAST*     arg1 = NULL,
           BaseAST*     arg2 = NULL,
           BaseAST*     arg3 = NULL,
           BaseAST*     arg4 = NULL,
           BaseAST*     arg5 = NULL);

  CallExpr(PrimitiveTag prim,
           BaseAST*     arg1 = NULL,
           BaseAST*     arg2 = NULL,
           BaseAST*     arg3 = NULL,
           BaseAST*     arg4 = NULL,
           BaseAST*     arg5 = NULL);

  CallExpr(const char*  name,
           BaseAST*     arg1 = NULL,
           BaseAST*     arg2 = NULL,
           BaseAST*     arg3 = NULL,
           BaseAST*     arg4 = NULL,
           BaseAST*     arg5 = NULL);

  ~CallExpr();

  virtual void    verify();

  DECLARE_COPY(CallExpr);


  virtual void    accept(AstVisitor* visitor);

  virtual void    replaceChild(Expr* old_ast, Expr* new_ast);

  virtual GenRet  codegen();
  virtual void    prettyPrint(std::ostream* o);
  virtual QualifiedType qualType();

  virtual Expr*   getFirstChild();

  virtual Expr*   getFirstExpr();
  virtual Expr*   getNextExpr(Expr* expr);

  void            insertAtHead(BaseAST* ast);
  void            insertAtTail(BaseAST* ast);

  // True if the callExpr has been emptied (aka dead)
  bool            isEmpty()                                              const;

  bool            isCast();
  Expr*           castFrom();
  Expr*           castTo();

  bool            isPrimitive()                                          const;
  bool            isPrimitive(PrimitiveTag primitiveTag)                 const;
  bool            isPrimitive(const char*  primitiveName)                const;

  FnSymbol*       isResolved()                                           const;
  FnSymbol*       resolvedFunction()                                     const;

  FnSymbol*       theFnSymbol()                                          const;

  bool            isNamed(const char*);

  int             numActuals()                                           const;
  Expr*           get(int index)                                         const;
  FnSymbol*       findFnSymbol();


private:
  GenRet          codegenPrimitive();
  GenRet          codegenPrimMove();

  void            codegenInvokeOnFun();
  void            codegenInvokeTaskFun(const char* name);

  GenRet          codegenBasicPrimitiveExpr()                            const;

  bool            isRefExternStarTuple(Symbol* formal, Expr* actual)     const;
};

// For storing several call expressions, where
// choosing between them depends on context
// (and that choice might need to be done later in resolution).
// These should only exist between resolution and cullOverReferences.
// A ContextCall has a designated call.
// The designated call will be returned if toCallExpr() is called
// on the context call.
// typeInfo/qualType on the context call will return the type info for
// the designated call.
// isCallExpr() will return true for a ContextCallExpr.
class ContextCallExpr : public Expr {
 public:
  // The options list always contains two CallExprs.
  // The first is the value/const ref return intent
  // and the second is the ref return intent version of a call.
  // Storing the ref call after the value call allows a
  // postorder traversal to skip the value call.
  // The order is important also - the first is always the value.
  AList options;

  ContextCallExpr();

  DECLARE_COPY(ContextCallExpr);

  virtual void    replaceChild(Expr* old_ast, Expr* new_ast);
  virtual void    verify();
  virtual void    accept(AstVisitor* visitor);
  virtual QualifiedType qualType();
  virtual GenRet  codegen();
  virtual void    prettyPrint(std::ostream *o);

  virtual Expr*   getFirstChild();

  virtual Expr*   getFirstExpr();

  void            setRefRValueOptions(CallExpr* refCall, CallExpr* rvalueCall);
  CallExpr*       getRefCall();
  CallExpr*       getRValueCall();
};


class ForallExpr : public Expr {
public:
  Expr* indices;
  Expr* iteratorExpr;
  Expr* expr;
  Expr* cond;
  bool maybeArrayType;
  bool zippered;

  ForallExpr(Expr* indices,
             Expr* iteratorExpr,
             Expr* expr,
             Expr* cond,
             bool maybeArrayType,
             bool zippered);

  DECLARE_COPY(ForallExpr);

  virtual void    replaceChild(Expr* old_ast, Expr* new_ast);
  virtual void    verify();
  virtual void    accept(AstVisitor* visitor);
  virtual GenRet  codegen();

  virtual Expr*   getFirstChild();
  virtual Expr*   getFirstExpr();
};


class NamedExpr : public Expr {
 public:
  const char*     name;
  Expr*           actual;

  NamedExpr(const char* init_name, Expr* init_actual);

  virtual void    verify();

  DECLARE_COPY(NamedExpr);

  virtual void    replaceChild(Expr* old_ast, Expr* new_ast);
  virtual void    accept(AstVisitor* visitor);
  virtual QualifiedType qualType();
  virtual GenRet  codegen();
  virtual void    prettyPrint(std::ostream* o);

  virtual Expr*   getFirstChild();

  virtual Expr*   getFirstExpr();
};


// Determines whether a node is in the AST (vs. has been removed
// from the AST). Used e.g. by cleanAst().
// Exception: 'n' is also live if isRootModule(n).

static inline bool isAlive(Expr* expr) {
  return expr->parentSymbol;
}

static inline bool isAliveQuick(Symbol* symbol) {
  return isAlive(symbol->defPoint);
}

static inline bool isAlive(Symbol* symbol) {
  return symbol->defPoint && isAlive(symbol->defPoint);
}

static inline bool isAlive(Type* type) {
  return isAlive(type->symbol->defPoint);
}

#define isRootModule(ast)  \
  ((ast) == rootModule)

#define isRootModuleWithType(ast, type)  \
  (E_##type == E_ModuleSymbol && ((ModuleSymbol*)(ast)) == rootModule)

static inline bool isGlobal(Symbol* symbol) {
  return isModuleSymbol(symbol->defPoint->parentSymbol);
}

static inline bool isTaskFun(FnSymbol* fn) {
  INT_ASSERT(fn);
  // Testing individual flags is more efficient than ops on entire FlagSet?
  return fn->hasFlag(FLAG_BEGIN) ||
         fn->hasFlag(FLAG_COBEGIN_OR_COFORALL) ||
         fn->hasFlag(FLAG_ON);
}

static inline FnSymbol* resolvedToTaskFun(CallExpr* call) {
  INT_ASSERT(call);
  if (FnSymbol* cfn = call->isResolved()) {
    if (isTaskFun(cfn))
      return cfn;
  }
  return NULL;
}

// Does this function require "capture for parallelism"?
// Yes, if it comes from a begin/cobegin/coforall block in Chapel source.
static inline bool needsCapture(FnSymbol* taskFn) {
  return taskFn->hasFlag(FLAG_BEGIN) ||
         taskFn->hasFlag(FLAG_COBEGIN_OR_COFORALL) ||
         taskFn->hasFlag(FLAG_NON_BLOCKING);
}

// E.g. NamedExpr::actual, DefExpr::init.
static inline void verifyNotOnList(Expr* expr) {
  if (expr && expr->list)
    INT_FATAL(expr, "Expr is in a list incorrectly");
}


bool get_int(Expr* e, int64_t* i); // false is failure
bool get_uint(Expr *e, uint64_t *i); // false is failure
bool get_string(Expr *e, const char **s); // false is failure
const char* get_string(Expr* e); // fatal on failure

CallExpr* callChplHereAlloc(Type* type, VarSymbol* md = NULL);
void insertChplHereAlloc(Expr *call, bool insertAfter, Symbol *sym,
                         Type* t, VarSymbol* md = NULL);
CallExpr* callChplHereFree(BaseAST* p);

// Walk the subtree of expressions rooted at "expr" in postorder, returning the
// current expression in "e", stopping after "expr" has been returned.
// Assignments to e in the calling context will change the path taken by the
// iterator, so should be avoided (unless you really know what you are doing).
#define for_exprs_postorder(e, expr)                            \
  for (Expr *last = (expr), *e = expr->getFirstExpr();          \
       e;                                                       \
       e = (e != last) ? getNextExpr(e) : NULL)

Expr* getNextExpr(Expr* expr);

CallExpr* createCast(BaseAST* src, BaseAST* toType);

Expr* new_Expr(const char* format, ...);
Expr* new_Expr(const char* format, va_list vl);

GenRet codegenValue(GenRet r);
GenRet codegenValuePtr(GenRet r);
#ifdef HAVE_LLVM
llvm::Value* createTempVarLLVM(llvm::Type* type, const char* name);
llvm::Value* createTempVarLLVM(llvm::Type* type);
#endif
GenRet createTempVarWith(GenRet v);

GenRet codegenDeref(GenRet toDeref);
GenRet codegenLocalDeref(GenRet toDeref);

#endif
