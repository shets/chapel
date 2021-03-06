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

// ChapelArray.chpl
//
/* Operations on Domains and Arrays.

   =================================================
   Distribution, Domain and Array Equality operators
   =================================================

   Equality operators are defined to test if two distributions
   are equivalent or not:

   .. code-block:: chapel

     dist1 == dist2
     dist1 != dist2

   Or to test if two domains are equivalent or not:

   .. code-block:: chapel

     dom1 == dom2
     dom1 != dom2

   Arrays are promoted, so the result of the equality operators is
   an array of booleans.  To get a single result use the ``equals``
   method instead.

   .. code-block:: chapel

     arr1 == arr2 // compare each element resulting in an array of booleans
     arr1 != arr2 // compare each element resulting in an array of booleans
     arr1.equals(arr2) // compare entire arrays resulting in a single boolean

   ========================================
   Miscellaneous Domain and Array Operators
   ========================================

   The domain count operator ``#``
   -------------------------------

   The ``#`` operator can be applied to dense rectangular domains
   with a tuple argument whose size matches the rank of the domain
   (or optionally an integer in the case of a 1D domain). The operator
   is equivalent to applying the ``#`` operator to the component
   ranges of the domain and then using them to slice the domain.

   The array count operator ``#``
   ------------------------------
   The ``#`` operator can be applied to dense rectangular arrays
   with a tuple argument whose size matches the rank of the array
   (or optionally an integer in the case of a 1D array). The operator
   is equivalent to applying the ``#`` operator to the array's domain
   and using the result to slice the array.

   The array swap operator ``<=>``
   -------------------------------
   The ``<=>`` operator can be used to swap the contents of two arrays
   with the same shape.

   The array alias operator ``=>``
   -------------------------------

   The ``=>`` operator can be used in a variable declaration to create
   a new alias of an array. The new variable will refer to the same
   array elements as the aliased array.  In the following example,
   the variable ``Inner`` refers to the inner 9 elements of ``A``.

   .. code-block:: chapel

     var A: [0..10] int;
     var Inner => A[1..9];

   ================================================
   Set Operations on Associative Domains and Arrays
   ================================================

   Associative domains and arrays support a number of operators for
   set manipulations.  The supported set operators are:

     =====  ====================
     \+ \|    Union
     &      Intersection
     \-      Difference
     ^      Symmetric Difference
     =====  ====================

   Consider the following code where ``A`` and ``B`` are associative arrays:

   .. code-block:: chapel

     var C = A op B;

   The result ``C`` is a new associative array backed by a new associative
   domain. The domains of ``A`` and ``B`` are not modified by ``op``.

   There are also op= variants that store the result into the first operand.

   Consider the following code where ``A`` and ``B`` are associative arrays:

   .. code-block:: chapel

     A op= B;

   ``A`` must not share its domain with another array, otherwise the program
   will halt with an error message.

   For the ``+=`` and ``|=`` operators, the value from ``B`` will overwrite
   the existing value in ``A`` when indices overlap.

   ===========================================
   Functions and Methods on Arrays and Domains
   ===========================================

 */
module ChapelArray {

  use ChapelBase; // For opaque type.
  use ChapelTuple;
  use ChapelLocale;
  use ArrayViewSlice;
  use ArrayViewRankChange;
  use ArrayViewReindex;

  // Explicitly use a processor atomic, as most calls to this function are
  // likely be on locale 0
  pragma "no doc"
  var numPrivateObjects: atomic_int64;
  pragma "no doc"
  param nullPid = -1;

  pragma "no doc"
  config param debugBulkTransfer = false;
  pragma "no doc"
  config param useBulkTransfer = true;
  pragma "no doc"
  config param useBulkTransferStride = true;

  // Return POD values from arrays as values instead of const ref?
  pragma "no doc"
  config param PODValAccess = true;

  // Toggles the functionality to perform strided bulk transfers involving
  // distributed arrays.
  //
  // Currently disabled due to observations of higher communication counts
  // compared to element-by-element assignment.
  pragma "no doc"
  config param useBulkTransferDist = false;

  pragma "no doc" // no doc unless we decide to expose this
  config param arrayAsVecGrowthFactor = 1.5;
  pragma "no doc"
  config param debugArrayAsVec = false;

  pragma "privatized class"
  proc _isPrivatized(value) param
    return !_local && ((_privatization && value.dsiSupportsPrivatization()) || value.dsiRequiresPrivatization());
    // Note - _local=true means --local / single locale
    // _privatization is controlled by --[no-]privatization
    // privatization required, not optional, for PrivateDist

  // MPF 2016-10-02: This simple implementation of privatization has some
  // drawbacks:
  // 1) Creating a new privatized object necessarily does something on all
  //    locales; this would be surprising if the user explicitly requested a
  //    Block array on 2 locales for example.
  // 2) Privatized object ids are managed by Locale 0 in a way that, while
  //    relatively low overhead, adds work to Locale 0 that is not present on
  //    the other locales, and again would be surprising if a Block array were
  //    created over other locales only (say, Locales[2] and Locales[3]).

  // Given a dsi Dist/Dom/Array, create an pid integer identifying the
  // privatized version on all locales; and populate each locale
  // with a privatized value that can be retrieved by the pid
  // without communication.
  proc _newPrivatizedClass(value) : int {

    const n = numPrivateObjects.fetchAdd(1);

    const hereID = here.id;
    const privatizeData = value.dsiGetPrivatizeData();
    on Locales[0] do
      _newPrivatizedClassHelp(value, value, n, hereID, privatizeData);

    proc _newPrivatizedClassHelp(parentValue, originalValue, n, hereID, privatizeData) {
      var newValue = originalValue;
      if hereID != here.id {
        newValue = parentValue.dsiPrivatize(privatizeData);
        __primitive("chpl_newPrivatizedClass", newValue, n);
        newValue.pid = n;
      } else {
        __primitive("chpl_newPrivatizedClass", newValue, n);
        newValue.pid = n;
      }
      cobegin {
        if chpl_localeTree.left then
          on chpl_localeTree.left do
            _newPrivatizedClassHelp(newValue, originalValue, n, hereID, privatizeData);
        if chpl_localeTree.right then
          on chpl_localeTree.right do
            _newPrivatizedClassHelp(newValue, originalValue, n, hereID, privatizeData);
      }
    }

    return n;
  }

  // original is the value this method shouldn't free, because it's the
  // canonical version. The rest are copies on other locales.
  proc _freePrivatizedClass(pid:int, original:object):void
  {
    // Do nothing for null pids.
    if pid == nullPid then return;

    on Locales[0] {
      _freePrivatizedClassHelp(pid, original);
    }

    proc _freePrivatizedClassHelp(pid, original) {
      var prv = chpl_getPrivatizedCopy(object, pid);
      if prv != original then
        delete prv;

      extern proc chpl_clearPrivatizedClass(pid:int);
      chpl_clearPrivatizedClass(pid);

      cobegin {
        if chpl_localeTree.left then
          on chpl_localeTree.left do
            _freePrivatizedClassHelp(pid, original);
        if chpl_localeTree.right then
          on chpl_localeTree.right do
            _freePrivatizedClassHelp(pid, original);
      }
    }
  }

  proc _reprivatize(value) {
    const pid = value.pid;
    const hereID = here.id;
    const reprivatizeData = value.dsiGetReprivatizeData();
    on Locales[0] do
      _reprivatizeHelp(value, value, pid, hereID, reprivatizeData);

    proc _reprivatizeHelp(parentValue, originalValue, pid, hereID, reprivatizeData) {
      var newValue = originalValue;
      if hereID != here.id {
        newValue = chpl_getPrivatizedCopy(newValue.type, pid);
        newValue.dsiReprivatize(parentValue, reprivatizeData);
      }
      cobegin {
        if chpl_localeTree.left then
          on chpl_localeTree.left do
            _reprivatizeHelp(newValue, originalValue, pid, hereID, reprivatizeData);
        if chpl_localeTree.right then
          on chpl_localeTree.right do
            _reprivatizeHelp(newValue, originalValue, pid, hereID, reprivatizeData);
      }
    }
  }

  //
  // Take a rank and value and check that the value is a rank-tuple or not a
  // tuple. If the value is not a tuple and expand is true, copy the value into
  // a rank-tuple. If the value is a scalar and rank is 1, copy it into a 1-tuple.
  //
  proc _makeIndexTuple(param rank, t: _tuple, param expand: bool=false) where rank == t.size {
    return t;
  }

  proc _makeIndexTuple(param rank, t: _tuple, param expand: bool=false) where rank != t.size {
    compilerError("index rank must match domain rank");
  }

  proc _makeIndexTuple(param rank, val:integral, param expand: bool=false) {
    if expand || rank == 1 {
      var t: rank*val.type;
      for param i in 1..rank do
        t(i) = val;
      return t;
    } else {
      compilerWarning(val.type:string);
      compilerError("index rank must match domain rank");
      return val;
    }
  }

  pragma "no copy return"
  proc _newArray(value) {
    if _isPrivatized(value) then
      return new _array(_newPrivatizedClass(value), value);
    else
      return new _array(nullPid, value);
  }

  pragma "no copy return"
  proc _getArray(value) {
    if _isPrivatized(value) then
      return new _array(_newPrivatizedClass(value), value, _unowned=true);
    else
      return new _array(nullPid, value, _unowned=true);
  }

  proc _newDomain(value) {
    if _isPrivatized(value) then
      return new _domain(_newPrivatizedClass(value), value);
    else
      return new _domain(nullPid, value);
  }

  proc _getDomain(value) {
    if _isPrivatized(value) then
      return new _domain(value.pid, value, _unowned=true);
    else
      return new _domain(nullPid, value, _unowned=true);
  }

  proc _newDistribution(value) {
    if _isPrivatized(value) then
      return new _distribution(_newPrivatizedClass(value), value);
    else
      return new _distribution(nullPid, value);
  }

  proc _getDistribution(value) {
    if _isPrivatized(value) then
      return new _distribution(value.pid, value, _unowned=true);
    else
      return new _distribution(nullPid, value, _unowned=true);
  }

  // Run-time type support
  //
  // NOTE: the bodies of functions marked with runtime type init fn such as
  // chpl__buildDomainRuntimeType and chpl__buildArrayRuntimeType are replaced
  // by the compiler to just create a record storing the arguments. The body
  // is moved by the compiler to convertRuntimeTypeToValue.
  // The return type of chpl__build...RuntimeType is what tells the
  // compiler which runtime type it is creating.

  //
  // Support for domain types
  //
  pragma "runtime type init fn"
  proc chpl__buildDomainRuntimeType(d: _distribution, param rank: int,
                                   type idxType = int,
                                   param stridable: bool = false)
    return _newDomain(d.newRectangularDom(rank, idxType, stridable));

  pragma "runtime type init fn"
  proc chpl__buildDomainRuntimeType(d: _distribution, type idxType,
                                    param parSafe: bool = true)
    return _newDomain(d.newAssociativeDom(idxType, parSafe));

  pragma "runtime type init fn"
  proc chpl__buildDomainRuntimeType(d: _distribution, type idxType,
                                    param parSafe: bool = true)
   where idxType == _OpaqueIndex
    return _newDomain(d.newOpaqueDom(idxType, parSafe));

  // This function has no 'runtime type init fn' pragma since the idxType of
  // opaque domains is _OpaqueIndex, not opaque.  This function is
  // essentially a wrapper around the function that actually builds up
  // the runtime type.
  proc chpl__buildDomainRuntimeType(d: _distribution, type idxType) type
   where idxType == opaque
    return chpl__buildDomainRuntimeType(d, _OpaqueIndex);

  pragma "runtime type init fn"
  proc chpl__buildSparseDomainRuntimeType(d: _distribution, dom: domain)
    return _newDomain(d.newSparseDom(dom.rank, dom._value.idxType, dom));

  proc chpl__convertValueToRuntimeType(dom: domain) type
   where dom._value:BaseRectangularDom
    return chpl__buildDomainRuntimeType(dom.dist, dom._value.rank,
                              dom._value.idxType, dom._value.stridable);

  proc chpl__convertValueToRuntimeType(dom: domain) type
   where dom._value:BaseAssociativeDom
    return chpl__buildDomainRuntimeType(dom.dist, dom._value.idxType, dom._value.parSafe);

  proc chpl__convertValueToRuntimeType(dom: domain) type
   where dom._value:BaseOpaqueDom
    return chpl__buildDomainRuntimeType(dom.dist, dom._value.idxType);

  proc chpl__convertValueToRuntimeType(dom: domain) type
   where dom._value:BaseSparseDom
    return chpl__buildSparseDomainRuntimeType(dom.dist, dom._value.parentDom);

  proc chpl__convertValueToRuntimeType(dom: domain) type {
    compilerError("the global domain class of each domain map implementation must be a subclass of BaseRectangularDom, BaseAssociativeDom, BaseOpaqueDom, or BaseSparseDom", 0);
    return 0; // dummy
  }

  //
  // Support for array types
  //
  pragma "runtime type init fn"
  proc chpl__buildArrayRuntimeType(dom: domain, type eltType)
    return dom.buildArray(eltType);

  proc _getLiteralType(type t) type {
    if t != c_string then return t;
    else return string;
  }
  /*
   * Support for array literal expressions.
   *
   * Array literals are detected during parsing and converted
   * to a call expr.  Array values pass through the various
   * compilation phases as regular parameters.
   *
   * NOTE:  It would be nice to define a second, less specific, function
   *        to handle the case of multiple types, however this is not
   *        possible atm due to using var args with a query type. */
  pragma "no doc"
  config param CHPL_WARN_DOMAIN_LITERAL = "unset";
  proc chpl__buildArrayExpr( elems ...?k ) {

    if CHPL_WARN_DOMAIN_LITERAL == "true" && isRange(elems(1)) {
      compilerWarning("Encountered an array literal with range element(s).",
                      " Did you mean a domain literal here?",
                      " If so, use {...} instead of [...].");
    }

    // elements of string literals are assumed to be of type string
    type elemType = _getLiteralType(elems(1).type);
    var A : [1..k] elemType;  //This is unfortunate, can't use t here...

    for param i in 1..k {
      type currType = _getLiteralType(elems(i).type);

      if currType != elemType {
        compilerError( "Array literal element " + i +
                       " expected to be of type " + elemType:string +
                       " but is of type " + currType:string );
      }

      A(i) = elems(i);
    }

    return A;
  }

  proc chpl__buildAssociativeArrayExpr( elems ...?k ) {
    type keyType = _getLiteralType(elems(1).type);
    type valType = _getLiteralType(elems(2).type);
    var D : domain(keyType);

    //Size the domain appropriately for the number of keys
    //This prevents expensive resizing as keys are added.
    // Note that k/2 is the number of keys, since the tuple
    // passed to this function has 2 elements (key and value)
    // for each array element.
    D.requestCapacity(k/2);
    var A : [D] valType;

    for param i in 1..k by 2 {
      var elemKey = elems(i);
      var elemVal = elems(i+1);
      type elemKeyType = _getLiteralType(elemKey.type);
      type elemValType = _getLiteralType(elemVal.type);

      if elemKeyType != keyType {
         compilerError("Associative array key element " + (i+2)/2 +
                       " expected to be of type " + keyType:string +
                       " but is of type " + elemKeyType:string);
      }

      if elemValType != valType {
        compilerError("Associative array value element " + (i+1)/2
                      + " expected to be of type " + valType:string
                      + " but is of type " + elemValType:string);
      }

      D += elemKey;
      A[elemKey] = elemVal;
    }

    return A;
  }


  proc chpl__convertValueToRuntimeType(arr: []) type
    return chpl__buildArrayRuntimeType(arr.domain, arr.eltType);

  //
  // These routines increment and decrement the reference count
  // for a domain that is part of an array's element type.
  // Prior to introducing these routines and calls, we would
  // increment/decrement the reference count based on the
  // number of indices in the outer domain instead; this could
  // cause the domain to be deallocated prematurely in the
  // case the the outer domain was empty.  For example:
  //
  //   var D = {1..0};   // start empty; we'll resize later
  //   var A: [D] [1..2] real;
  //
  // The anonymous domain {1..2} must be kept alive as a result
  // of being part of A's type even though D is initially empty.
  // Thus, {1..2} should remain alive as long as A is.  By
  // incrementing and decrementing its reference counts based
  // on A's lifetime rather than the number of elements in domain
  // D, we ensure that is kept alive.  See
  // test/users/bugzilla/bug794133/ for more details and examples.
  //
  proc chpl_incRefCountsForDomainsInArrayEltTypes(arr:BaseArr, type eltType) {
    if (isArrayType(eltType)) {
      var ev: eltType;
      ev.domain._value.add_containing_arr(arr);
      chpl_incRefCountsForDomainsInArrayEltTypes(arr, ev.eltType);
    }
  }

  proc chpl_decRefCountsForDomainsInArrayEltTypes(arr:BaseArr, type eltType) {
    if (isArrayType(eltType)) {
      var ev: eltType;
      const refcount = ev.domain._value.remove_containing_arr(arr);
      if refcount == 0 then
        _delete_dom(ev.domain._value, _isPrivatized(ev.domain._value));
      chpl_decRefCountsForDomainsInArrayEltTypes(arr, ev.eltType);
    }
  }

  //
  // Support for subdomain types
  //
  // Note the domain of a subdomain is not yet part of the runtime type
  //
  proc chpl__buildSubDomainType(dom: domain) type
    return chpl__convertValueToRuntimeType(dom);

  //
  // Support for domain expressions, e.g., {1..3, 1..3}
  //

  proc chpl__buildDomainExpr(ranges: range(?) ...?rank) {
    for param i in 2..rank do
      if ranges(1).idxType != ranges(i).idxType then
        compilerError("idxType varies among domain's dimensions");
    for param i in 1..rank do
      if ! isBoundedRange(ranges(i)) then
        compilerError("one of domain's dimensions is not a bounded range");
    var d: domain(rank, ranges(1).idxType, chpl__anyStridable(ranges));
    d.setIndices(ranges);
    return d;
  }

  proc chpl__buildDomainExpr(keys: ?t ...?count) {
    // keyType of string literals is assumed to be type string
    type keyType = _getLiteralType(keys(1).type);
    for param i in 2..count do
      if keyType != _getLiteralType(keys(i).type) {
        compilerError("Associative domain element " + i +
                      " expected to be of type " + keyType:string +
                      " but is of type " +
                      _getLiteralType(keys(i).type):string);
      }

    //Initialize the domain with a size appropriate for the number of keys.
    //This prevents resizing as keys are added.
    var D : domain(keyType);
    D.requestCapacity(count);

    for param i in 1..count do
      D += keys(i);

    return D;
  }

  //
  // Support for domain expressions within array types, e.g. [1..n], [D]
  //
  proc chpl__ensureDomainExpr(const ref x: domain) const ref {
    return x;
  }

  proc chpl__ensureDomainExpr(x...) {
    return chpl__buildDomainExpr((...x));
  }

  //
  // Support for distributed domain expression e.g. {1..3, 1..3} dmapped Dist()
  //
  proc chpl__distributed(d: _distribution, dom: domain) {
    if isRectangularDom(dom) {
      var distDom: domain(dom.rank, dom._value.idxType, dom._value.stridable) dmapped d = dom;
      return distDom;
    } else {
      var distDom: domain(dom._value.idxType) dmapped d = dom;
      return distDom;
    }
  }

  proc chpl__distributed(d: _distribution, ranges: range(?) ...?rank) {
    return chpl__distributed(d, chpl__buildDomainExpr((...ranges)));
  }

  //
  // Array-view utility functions
  //
  proc chpl__isArrayView(arr) param {
    const value = if isArray(arr) then arr._value else arr;

    param isSlice      = value.isSliceArrayView();
    param isRankChange = value.isRankChangeArrayView();
    param isReindex    = value.isReindexArrayView();

    return isSlice || isRankChange || isReindex;
  }

  //
  // Returns a domain with a rank equivalent to chpl__getActualArray(arr).rank.
  // This domain is no larger than the innermost array's domain. It represents
  // the 'active' indices that the top-level ArrayView works with. For example:
  //
  //   var A : [1..10, 1..10];
  //   var B => A[1, 1..10];
  //   writeln(chpl__getViewDom(B)); // {1..1, 1..10}
  //
  // TODO: Can this be written to accept a full-fledge array OR a BaseArr?
  //
  proc chpl__getViewDom(arr: []) {
    if chpl__isArrayView(arr._value) then return arr._value._getViewDom();
    else return arr.domain;
  }

  //
  // Returns the innermost array class (e.g., a DefaultRectangular).
  //
  // 'arr' can be a full-fledged array or a BaseArr-inheriting class
  //
  proc chpl__getActualArray(arr) {
    var value = if isArray(arr) then arr._value else arr;
    var ret = if chpl__isArrayView(value) then value._getActualArray() else value;
    return ret;
  }
  //
  // End of array-view utility functions
  //

  proc chpl__isRectangularDomType(type domainType) param {
    var dom: domainType;
    return isDomainType(domainType) && isRectangularDom(dom);
  }

  proc chpl__isSparseDomType(type domainType) param {
    var dom: domainType;
    return isSparseDom(dom);
  }

  proc chpl__distributed(d: _distribution, type domainType) type {
    if !isDomainType(domainType) then
      compilerError("cannot apply 'dmapped' to the non-domain type ",
                    domainType:string);
    if chpl__isRectangularDomType(domainType) {
      var dom: domainType;
      return chpl__buildDomainRuntimeType(d, dom._value.rank, dom._value.idxType,
                                          dom._value.stridable);
    } else if chpl__isSparseDomType(domainType) {
      //
      // this "no auto destroy" pragma is necessary as of 1/20 because
      // otherwise the parentDom gets destroyed in the sparse case; see
      // sparse/bradc/CSR/sparse.chpl as an example
      //
      pragma "no auto destroy" var dom: domainType;
      return chpl__buildSparseDomainRuntimeType(d, dom._value.parentDom);
    } else {
      var dom: domainType;
      return chpl__buildDomainRuntimeType(d, dom._value.idxType, dom._value.parSafe);
    }
  }

  //
  // Support for index types
  //
  proc chpl__buildIndexType(param rank: int, type idxType) type where rank == 1 {
    var x: idxType;
    return x.type;
  }

  proc chpl__buildIndexType(param rank: int, type idxType) type where rank > 1 {
    var x: rank*idxType;
    return x.type;
  }

  proc chpl__buildIndexType(param rank: int) type
    return chpl__buildIndexType(rank, int);

  proc chpl__buildIndexType(d: domain) type
    return chpl__buildIndexType(d.rank, d._value.idxType);

  proc chpl__buildIndexType(type idxType) type where idxType == opaque
    return _OpaqueIndex;

  /* Return true if the argument ``d`` is a rectangular domain.
     Otherwise return false.  */
  proc isRectangularDom(d: domain) param {
    proc isRectangularDomClass(dc: BaseRectangularDom) param return true;
    proc isRectangularDomClass(dc) param return false;
    return isRectangularDomClass(d._value);
  }

  /* Return true if the argument ``a`` is an array with a rectangular
     domain.  Otherwise return false. */
  proc isRectangularArr(a: []) param return isRectangularDom(a.domain);

  /* Return true if ``d`` is an irregular domain; e.g. is not rectangular.
     Otherwise return false. */
  proc isIrregularDom(d: domain) param {
    return isSparseDom(d) || isAssociativeDom(d) || isOpaqueDom(d);
  }

  /* Return true if ``a`` is an array with an irregular domain; e.g. not
     rectangular. Otherwise return false. */
  proc isIrregularArr(a: []) param return isIrregularDom(a.domain);

  /* Return true if ``d`` is an associative domain. Otherwise return false. */
  proc isAssociativeDom(d: domain) param {
    proc isAssociativeDomClass(dc: BaseAssociativeDom) param return true;
    proc isAssociativeDomClass(dc) param return false;
    return isAssociativeDomClass(d._value);
  }

  /* Return true if ``a`` is an array with an associative domain. Otherwise
     return false. */
  proc isAssociativeArr(a: []) param return isAssociativeDom(a.domain);

  /* Return true if ``d`` is an associative domain defined over an enumerated
     type. Otherwise return false. */
  proc isEnumDom(d: domain) param {
    return isAssociativeDom(d) && isEnumType(d._value.idxType);
  }

  /* Return true if ``a`` is an array with an enumerated domain. Otherwise
     return false. */
  proc isEnumArr(a: []) param return isEnumDom(a.domain);

  /* Return true if ``d`` is an opaque domain. Otherwise return false. */
  proc isOpaqueDom(d: domain) param {
    proc isOpaqueDomClass(dc: BaseOpaqueDom) param return true;
    proc isOpaqueDomClass(dc) param return false;
    return isOpaqueDomClass(d._value);
  }

  /* Return true if ``d`` is a sparse domain. Otherwise return false. */
  proc isSparseDom(d: domain) param {
    proc isSparseDomClass(dc: BaseSparseDom) param return true;
    proc isSparseDomClass(dc) param return false;
    return isSparseDomClass(d._value);
  }

  /* Return true if ``a`` is an array with a sparse domain. Otherwise
     return false. */
  proc isSparseArr(a: []) param return isSparseDom(a.domain);

  //
  // Support for distributions
  //
  pragma "no doc"
  pragma "syntactic distribution"
  record dmap { }

  proc chpl__buildDistType(type t) type where t: BaseDist {
    var x: t;
    var y = _newDistribution(x);
    return y.type;
  }

  proc chpl__buildDistType(type t) {
    compilerError("illegal domain map type specifier - must be a subclass of BaseDist");
  }

  proc chpl__buildDistValue(x) where x: BaseDist {
    return _newDistribution(x);
  }

  proc chpl__buildDistValue(x) {
    compilerError("illegal domain map value specifier - must be a subclass of BaseDist");
  }

  //
  // Distribution wrapper record
  //
  pragma "distribution"
  pragma "ignore noinit"
  pragma "no doc"
  record _distribution {
    var _pid:int;  // only used when privatized
    var _instance; // generic, but an instance of a subclass of BaseDist
    var _unowned:bool; // 'true' for the result of 'getDistribution',
                       // in which case, the record destructor should
                       // not attempt to delete the _instance.

    inline proc _value {
      if _isPrivatized(_instance) {
        return chpl_getPrivatizedCopy(_instance.type, _pid);
      } else {
        return _instance;
      }
    }

    inline proc _do_destroy() {
      if ! _unowned && ! _instance.singleton() {
        on _instance {
          // Count the number of domains that refer to this distribution.
          // and mark the distribution to be freed when that number reaches 0.
          // If the number is 0, .remove() returns the distribution
          // that should be freed.
          var distToFree = _instance.remove();
          if distToFree != nil {
            _delete_dist(distToFree, _isPrivatized(_instance));
          }
        }
      }
    }

    proc deinit() {
      _do_destroy();
    }

    proc clone() {
      return _newDistribution(_value.dsiClone());
    }

    proc newRectangularDom(param rank: int, type idxType, param stridable: bool) {
      var x = _value.dsiNewRectangularDom(rank, idxType, stridable);
      if x.linksDistribution() {
        _value.add_dom(x);
      }
      return x;
    }

    proc newAssociativeDom(type idxType, param parSafe: bool=true) {
      var x = _value.dsiNewAssociativeDom(idxType, parSafe);
      if x.linksDistribution() {
        _value.add_dom(x);
      }
      return x;
    }

    proc newAssociativeDom(type idxType, param parSafe: bool=true)
    where isEnumType(idxType) {
      var x = _value.dsiNewAssociativeDom(idxType, parSafe);
      if x.linksDistribution() {
        _value.add_dom(x);
      }
      const enumTuple = chpl_enum_enumerate(idxType);
      for param i in 1..enumTuple.size do
        x.dsiAdd(enumTuple(i));
      return x;
    }

    proc newOpaqueDom(type idxType, param parSafe: bool=true) {
      var x = _value.dsiNewOpaqueDom(idxType, parSafe);
      if x.linksDistribution() {
        _value.add_dom(x);
      }
      return x;
    }

    proc newSparseDom(param rank: int, type idxType, dom: domain) {
      var x = _value.dsiNewSparseDom(rank, idxType, dom);
      if x.linksDistribution() {
        _value.add_dom(x);
      }
      return x;
    }

    proc idxToLocale(ind) return _value.dsiIndexToLocale(ind);

    proc readWriteThis(f) {
      f <~> _value;
    }

    proc displayRepresentation() { _value.dsiDisplayRepresentation(); }

    /*
       Returns an array of locales over which this distribution was declared.
    */
    proc targetLocales() {
      return _value.dsiTargetLocales();
    }
  }  // record _distribution

  inline proc ==(d1: _distribution(?), d2: _distribution(?)) {
    if (d1._value == d2._value) then
      return true;
    return d1._value.dsiEqualDMaps(d2._value);
  }

  inline proc !=(d1: _distribution(?), d2: _distribution(?)) {
    if (d1._value == d2._value) then
      return false;
    return !d1._value.dsiEqualDMaps(d2._value);
  }

  // The following method is called by the compiler to determine the default
  // value of a given type.
  /* Need new <alias>() for this to function
  proc _defaultOf(type t) where t:_distribution {
    var ret: t = noinit;
    type valType = __primitive("query type field", t, "_valueType");
    var typeInstance = new <valType>();
    ret = chpl__buildDistValue(typeInstance);
    return ret;
  }
  */ /* */

  // This alternative declaration of Sort.defaultComparator
  // prevents transitive use of module Sort.
  proc chpl_defaultComparator() {
    use Sort;
    return defaultComparator;
  }


  //
  // Domain wrapper record.
  //
  pragma "domain"
  pragma "has runtime type"
  pragma "ignore noinit"
  record _domain {
    var _pid:int; // only used when privatized
    var _instance; // generic, but an instance of a subclass of BaseDom
    var _unowned:bool; // 'true' for the result of 'getDomain'
                       // in which case, the record destructor should
                       // not attempt to delete the _instance.
    var _promotionType: index(rank, _value.idxType);

    inline proc _value {
      if _isPrivatized(_instance) {
        return chpl_getPrivatizedCopy(_instance.type, _pid);
      } else {
        return _instance;
      }
    }

    proc _do_destroy () {
      if ! _unowned {
        on _instance {
          // Count the number of arrays that refer to this domain,
          // and mark the domain to be freed when that number reaches 0.
          // Additionally, if the number is 0, remove the domain from
          // the distribution and possibly get the distribution to free.
          const inst = _instance;
          var (domToFree, distToRemove) = inst.remove();
          var distToFree:BaseDist = nil;
          if distToRemove != nil {
            distToFree = distToRemove.remove();
          }
          if domToFree != nil then
            _delete_dom(inst, _isPrivatized(inst));
          if distToFree != nil then
            _delete_dist(distToFree, _isPrivatized(inst.dist));
        }
      }
    }
    proc deinit () {
      _do_destroy();
    }

    /* Return the domain map that implements this domain */
    proc dist return _getDistribution(_value.dist);

    /* Return the number of dimensions in this domain */
    proc rank param {
      if isRectangularDom(this) || isSparseDom(this) then
        return _value.rank;
      else
        return 1;
    }

    /* Return the type of the indices of this domain */
    proc idxType type {
      if isOpaqueDom(this) then
        compilerError("opaque domains do not currently support .idxType");
      return _value.idxType;
    }

    /* Return true if this is a stridable domain */
    proc stridable param where isRectangularDom(this) {
      return _value.stridable;
    }

    pragma "no doc"
    proc stridable param where isSparseDom(this) {
      compilerError("sparse domains do not currently support .stridable");
    }

    pragma "no doc"
    proc stridable param where isOpaqueDom(this) {
      compilerError("opaque domains do not support .stridable");
    }

    pragma "no doc"
    proc stridable param where isEnumDom(this) {
      compilerError("enumerated domains do not support .stridable");
    }

    pragma "no doc"
    proc stridable param where isAssociativeDom(this) {
      compilerError("associative domains do not support .stridable");
    }

    pragma "no doc"
    inline proc these() {
      return _value.these();
    }

    // see comments for the same method in _array
    //
    // domain slicing by domain
    pragma "no doc"
    proc this(d: domain) {
      if d.rank == rank then
        return this((...d.getIndices()));
      else
        compilerError("slicing a domain with a domain of a different rank");
    }

    // domain slicing by tuple of ranges
    pragma "no doc"
    proc this(ranges: range(?) ...rank) {
      param stridable = _value.stridable || chpl__anyStridable(ranges);
      var r: rank*range(_value.idxType,
                        BoundedRangeType.bounded,
                        stridable);

      for param i in 1..rank {
        r(i) = _value.dsiDim(i)(ranges(i));
      }
      var d = _value.dsiBuildRectangularDom(rank, _value.idxType, stridable, r);
      // Since we've created a new domain, the distribution needs to
      // live at least as long as this new domain.
      if d.linksDistribution() then
        d.dist.add_dom(d);
      return _newDomain(d);
    }

    // domain rank change
    pragma "no doc"
    proc this(args ...rank) where _validRankChangeArgs(args, _value.idxType) {
      var ranges = _getRankChangeRanges(args);
      param newRank = ranges.size,
            stridable = chpl__anyStridable(ranges) || this.stridable;
      var newRanges: newRank*range(idxType=_value.idxType, stridable=stridable);
      var newDistVal = _value.dist.dsiCreateRankChangeDist(newRank, args);
      var sameDist = (newDistVal == _value.dist);
      var newDist = if sameDist then
                       _getDistribution(newDistVal)
                    else
                       _newDistribution(newDistVal);
      if ! sameDist && ! _value.dist.trackDomains() {
        // Otherwise, we don't have a way for the var d below
        // to extend the lifetime of the distribution...
        halt("Distribution must use trackDomains or be singleton");
      }
      var j = 1;
      var makeEmpty = false;

      for param i in 1..rank {
        if !isCollapsedDimension(args(i)) {
          newRanges(j) = dim(i)(args(i));
          j += 1;
        } else {
          if !dim(i).member(args(i)) then
            makeEmpty = true;
        }
      }
      if makeEmpty {
        for param i in 1..newRank {
          newRanges(i) = 1..0;
        }
      }
      var d = {(...newRanges)} dmapped newDist;
      return d;
    }

    // anything that is not covered by the above
    pragma "no doc"
    proc this(args ...?numArgs) {
      if numArgs == rank {
        // Doing this just to get a better compiler error
        var ranges = _getRankChangeRanges(args);
        compilerError("invalid argument types for domain slicing");
      } else
        compilerError("a domain slice requires either a single domain argument or exactly one argument per domain dimension");
    }

    /*
       Returns a tuple of ranges describing the bounds of a rectangular domain.
       For a sparse domain, returns the bounds of the parent domain.
     */
    proc dims() return _value.dsiDims();

    /*
       Returns a range representing the boundary of this
       domain in a particular dimension.
     */
    proc dim(d : int) return _value.dsiDim(d);

    pragma "no doc"
    proc dim(param d : int) return _value.dsiDim(d);

    pragma "no doc"
    iter dimIter(param d, ind) {
      for i in _value.dimIter(d, ind) do yield i;
    }

   /* Returns a tuple of integers describing the size of each dimension.
      For a sparse domain, returns the shape of the parent domain.*/
    proc shape where isRectangularDom(this) || isSparseDom(this) {
      var s: rank*(int);
      for (i, r) in zip(1..s.size, dims()) do
        s(i) = r.size;
      return s;
    }

    pragma "no doc"
    /* Associative and Opaque domains assumed to be 1-D. */
    proc shape where isAssociativeDom(this) || isOpaqueDom(this) {
      var s: (int,);
      s[1] = size;
      return s;
    }

    pragma "no doc"
    /* Unsupported case */
    proc shape {
      compilerError(".shape not supported on this domain");
    }

    pragma "no doc"
    pragma "no copy return"
    proc buildArray(type eltType) {
      var x = _value.dsiBuildArray(eltType);
      pragma "dont disable remote value forwarding"
      proc help() {
        _value.add_arr(x);
      }
      help();

      chpl_incRefCountsForDomainsInArrayEltTypes(x, x.eltType);

      return _newArray(x);
    }
    /* Remove all indices from this domain, leaving it empty */
    proc clear() {
      _value.dsiClear();
    }

    pragma "no doc"
    proc create() {
      if _value.idxType != _OpaqueIndex then
        compilerError("domain.create() only applies to opaque domains");
      return _value.dsiCreate();
    }

    /* Add index ``i`` to this domain. This method is also available
       as the ``+=`` operator.
     */
    proc add(i) {
      return _value.dsiAdd(i);
    }

    pragma "no doc"
    proc bulkAdd(inds: [] _value.idxType, dataSorted=false,
        isUnique=false, preserveInds=true) where isSparseDom(this) && _value.rank==1 {

      if inds.size == 0 then return 0;

      return _value.dsiBulkAdd(inds, dataSorted, isUnique, preserveInds);
    }

    /*
       Adds indices in ``inds`` to this domain in bulk.

       For sparse domains, an operation equivalent to this method is available
       with the ``+=`` operator, where the right-hand-side is an array. However,
       in that case, default values will be used for the flags ``dataSorted``,
       ``isUnique``, and ``preserveInds``. This method is available because in
       some cases, expensive operations can be avoided by setting those flags.
       To do so, ``bulkAdd`` must be called explicitly (instead of ``+=``).

       .. note::

         Right now, this method and the corresponding ``+=`` operator are
         only available for sparse domains. In the future, we expect that
         these methods will be available for all irregular domains.

       :arg inds: Indices to be added. ``inds`` can be an array of
                  ``rank*idxType`` or an array of ``idxType`` for
                  1-D domains.

       :arg dataSorted: ``true`` if data in ``inds`` is sorted.
       :type dataSorted: bool

       :arg isUnique: ``true`` if data in ``inds`` has no duplicates.
       :type isUnique: bool

       :arg preserveInds: ``true`` if data in ``inds`` needs to be preserved.
       :type preserveInds: bool

       :returns: Number of indices added to the domain
       :rtype: int
    */
    proc bulkAdd(inds: [] _value.rank*_value.idxType, dataSorted=false,
        isUnique=false, preserveInds=true) where isSparseDom(this) && _value.rank>1 {

      if inds.size == 0 then return 0;

      return _value.dsiBulkAdd(inds, dataSorted, isUnique, preserveInds);
    }

    /* Remove index ``i`` from this domain */
    proc remove(i) {
      return _value.dsiRemove(i);
    }

    /* Request space for a particular number of values in an
       domain.

       Currently only applies to associative domains.
     */
    proc requestCapacity(i) {

      if i < 0 {
        halt("domain.requestCapacity can only be invoked on sizes >= 0");
      }

      if !isAssociativeDom(this) then
        compilerError("domain.requestCapacity only applies to associative domains");

      _value.dsiRequestCapacity(i);
    }

    /* Return the number of indices in this domain */
    proc size return numIndices;
    /* Return the number of indices in this domain */
    proc numIndices return _value.dsiNumIndices;
    /* Return the lowest index in this domain */
    proc low return _value.dsiLow;
    /* Return the highest index in this domain */
    proc high return _value.dsiHigh;
    /* Return the stride of the indices in this domain */
    proc stride return _value.dsiStride;
    /* Return the alignment of the indices in this domain */
    proc alignment return _value.dsiAlignment;
    /* Return the first index in this domain */
    proc first return _value.dsiFirst;
    /* Return the last index in this domain */
    proc last return _value.dsiLast;
    /* Return the low index in this domain factoring in alignment */
    proc alignedLow return _value.dsiAlignedLow;
    /* Return the high index in this domain factoring in alignment */
    proc alignedHigh return _value.dsiAlignedHigh;

    pragma "no doc"
    proc member(i: rank*_value.idxType) {
      if isRectangularDom(this) || isSparseDom(this) then
        return _value.dsiMember(_makeIndexTuple(rank, i));
      else
        return _value.dsiMember(i(1));
    }
    /* Return true if ``i`` is a member of this domain. Otherwise
       return false. */
    proc member(i: _value.idxType ...rank) {
      return member(i);
    }

    pragma "no doc"
    pragma "reference to const when const this"
    pragma "new alias fn"
    proc newAlias() {
      var x = _value;
      pragma "no copy"
      var ret = _getDomain(x);
      return ret;
    }

    /* Returns true if this domain is a subset of ``super``. Otherwise
       returns false. */
    proc isSubset(super : domain) {
      if !isAssociativeDom(this) {
        if isRectangularDom(this) then
          compilerError("isSubset not supported on rectangular domains");
        else if isOpaqueDom(this) then
          compilerError("isSubset not supported on opaque domains");
        else if isSparseDom(this) then
          compilerError("isSubset not supported on sparse domains");
        else
          compilerError("isSubset not supported on this domain type");
      }
      if super.type != this.type then
        compilerError("isSubset called with different associative domain types");

      return && reduce forall i in this do super.member(i);
    }

    /* Returns true if this domain is a superset of ``sub``. Otherwise
       returns false. */
    proc isSuper(sub : domain) {
      if !isAssociativeDom(this) {
        if isRectangularDom(this) then
          compilerError("isSuper not supported on rectangular domains");
        else if isOpaqueDom(this) then
          compilerError("isSuper not supported on opaque domains");
        else if isSparseDom(this) then
          compilerError("isSuper not supported on sparse domains");
        else
          compilerError("isSuper not supported on the domain type ", this.type);
      }
      if sub.type != this.type then
        compilerError("isSuper called with different associative domain types");

      return && reduce forall i in sub do this.member(i);
    }

    // 1/5/10: do we want to support order() and position()?
    pragma "no doc"
    proc indexOrder(i) return _value.dsiIndexOrder(_makeIndexTuple(rank, i));

    pragma "no doc"
    proc position(i) {
      var ind = _makeIndexTuple(rank, i), pos: rank*_value.idxType;
      for d in 1..rank do
        pos(d) = _value.dsiDim(d).indexOrder(ind(d));
      return pos;
    }

    pragma "no doc"
    proc expand(off: rank*_value.idxType) where !isRectangularDom(this) {
      if isAssociativeDom(this) then
        compilerError("expand not supported on associative domains");
      else if isOpaqueDom(this) then
        compilerError("expand not supported on opaque domains");
      else if isSparseDom(this) then
        compilerError("expand not supported on sparse domains");
      else
        compilerError("expand not supported on this domain type");
    }

    pragma "no doc"
    proc expand(off: _value.idxType ...rank) return expand(off);

    /* Returns a new domain that is the current domain expanded by
       ``off(d)`` in dimension ``d`` if ``off(d)`` is positive or
       contracted by ``off(d)`` in dimension ``d`` if ``off(d)``
       is negative. */
    proc expand(off: rank*_value.idxType) {
      var ranges = dims();
      for i in 1..rank do {
        ranges(i) = ranges(i).expand(off(i));
        if (ranges(i).low > ranges(i).high) {
          halt("***Error: Degenerate dimension created in dimension ", i, "***");
        }
      }

      var d = _value.dsiBuildRectangularDom(rank, _value.idxType,
                                           _value.stridable, ranges);
      // Since we've created a new domain, the distribution needs to
      // live at least as long as this new domain.
      if d.linksDistribution() then
        d.dist.add_dom(d);

      return _newDomain(d);
    }

    /* Returns a new domain that is the current domain expanded by
       ``off`` in all dimensions if ``off`` is positive or contracted
       by ``off`` in all dimensions if ``off`` is negative. */
    proc expand(off: _value.idxType) where rank > 1 {
      var ranges = dims();
      for i in 1..rank do
        ranges(i) = dim(i).expand(off);
      var d = _value.dsiBuildRectangularDom(rank, _value.idxType,
                                           _value.stridable, ranges);
      // Since we've created a new domain, the distribution needs to
      // live at least as long as this new domain.
      if d.linksDistribution() then
        d.dist.add_dom(d);
      return _newDomain(d);
    }

    pragma "no doc"
    proc exterior(off: rank*_value.idxType) where !isRectangularDom(this) {
      if isAssociativeDom(this) then
        compilerError("exterior not supported on associative domains");
      else if isOpaqueDom(this) then
        compilerError("exterior not supported on opaque domains");
      else if isSparseDom(this) then
        compilerError("exterior not supported on sparse domains");
      else
        compilerError("exterior not supported on this domain type");
    }

    pragma "no doc"
    proc exterior(off: _value.idxType ...rank) return exterior(off);

    /* Returns a new domain that is the exterior portion of the
       current domain with ``off(d)`` indices for each dimension ``d``.
       If ``off(d)`` is negative, compute the exterior from the low
       bound of the dimension; if positive, compute the exterior
       from the high bound. */
    proc exterior(off: rank*_value.idxType) {
      var ranges = dims();
      for i in 1..rank do
        ranges(i) = dim(i).exterior(off(i));
      var d = _value.dsiBuildRectangularDom(rank, _value.idxType,
                                           _value.stridable, ranges);
      // Since we've created a new domain, the distribution needs to
      // live at least as long as this new domain.
      if d.linksDistribution() then
        d.dist.add_dom(d);
      return _newDomain(d);
    }

    /* Returns a new domain that is the exterior portion of the
       current domain with ``off`` indices for each dimension.
       If ``off`` is negative, compute the exterior from the low
       bound of the dimension; if positive, compute the exterior
       from the high bound. */
    proc exterior(off:_value.idxType) where rank != 1 {
      var offTup: rank*_value.idxType;
      for i in 1..rank do
        offTup(i) = off;
      return exterior(offTup);
    }

    pragma "no doc"
    proc interior(off: rank*_value.idxType) where !isRectangularDom(this) {
      if isAssociativeDom(this) then
        compilerError("interior not supported on associative domains");
      else if isOpaqueDom(this) then
        compilerError("interior not supported on opaque domains");
      else if isSparseDom(this) then
        compilerError("interior not supported on sparse domains");
      else
        compilerError("interior not supported on this domain type");
    }

    pragma "no doc"
    proc interior(off: _value.idxType ...rank) return interior(off);

    /* Returns a new domain that is the interior portion of the
       current domain with ``off(d)`` indices for each dimension
       ``d``. If ``off(d)`` is negative, compute the interior from
       the low bound of the dimension; if positive, compute the
       interior from the high bound. */
    proc interior(off: rank*_value.idxType) {
      var ranges = dims();
      for i in 1..rank do {
        if ((off(i) > 0) && (dim(i).high+1-off(i) < dim(i).low) ||
            (off(i) < 0) && (dim(i).low-1-off(i) > dim(i).high)) {
          halt("***Error: Argument to 'interior' function out of range in dimension ", i, "***");
        }
        ranges(i) = _value.dsiDim(i).interior(off(i));
      }
      var d = _value.dsiBuildRectangularDom(rank, _value.idxType,
                                           _value.stridable, ranges);
      // Since we've created a new domain, the distribution needs to
      // live at least as long as this new domain.
      if d.linksDistribution() then
        d.dist.add_dom(d);
      return _newDomain(d);
    }

    /* Returns a new domain that is the interior portion of the
       current domain with ``off`` indices for each dimension.
       If ``off`` is negative, compute the interior from the low
       bound of the dimension; if positive, compute the interior
       from the high bound. */
    proc interior(off: _value.idxType) where rank != 1 {
      var offTup: rank*_value.idxType;
      for i in 1..rank do
        offTup(i) = off;
      return interior(offTup);
    }

    //
    // NOTE: We eventually want to support translate on other domain types
    //
    pragma "no doc"
    proc translate(off) where !isRectangularDom(this) {
      if isAssociativeDom(this) then
        compilerError("translate not supported on associative domains");
      else if isOpaqueDom(this) then
        compilerError("translate not supported on opaque domains");
      else if isSparseDom(this) then
        compilerError("translate not supported on sparse domains");
      else
        compilerError("translate not supported on this domain type");
    }

    //
    // Notice that the type of the offset does not have to match the
    // index type.  This is handled in the range.translate().
    //
    pragma "no doc"
    proc translate(off: ?t ...rank) return translate(off);

    /* Returns a new domain that is the current domain translated by
       ``off(d)`` in each dimension ``d``. */
    proc translate(off) where isTuple(off) {
      if off.size != rank then
        compilerError("the domain and offset arguments of translate() must be of the same rank");
      var ranges = dims();
      for i in 1..rank do
        ranges(i) = _value.dsiDim(i).translate(off(i));
      var d = _value.dsiBuildRectangularDom(rank, _value.idxType,
                                           _value.stridable, ranges);
      // Since we've created a new domain, the distribution needs to
      // live at least as long as this new domain.
      if d.linksDistribution() then
        d.dist.add_dom(d);
      return _newDomain(d);
     }

    /* Returns a new domain that is the current domain translated by
       ``off`` in each dimension. */
     proc translate(off) where rank != 1 && !isTuple(off) {
       var offTup: rank*off.type;
       for i in 1..rank do
         offTup(i) = off;
       return translate(offTup);
     }

    //
    // intended for internal use only:
    //
    proc chpl__unTranslate(off: _value.idxType ...rank) return chpl__unTranslate(off);
    proc chpl__unTranslate(off: rank*_value.idxType) {
      var ranges = dims();
      for i in 1..rank do
        ranges(i) = dim(i).chpl__unTranslate(off(i));
      var d = _value.dsiBuildRectangularDom(rank, _value.idxType,
                                           _value.stridable, ranges);
      // Since we've created a new domain, the distribution needs to
      // live at least as long as this new domain.
      if d.linksDistribution() then
        d.dist.add_dom(d);
      return _newDomain(d);
    }

    pragma "no doc"
    proc setIndices(x) {
      _value.dsiSetIndices(x);
      if _isPrivatized(_instance) {
        _reprivatize(_value);
      }
    }

    pragma "no doc"
    proc getIndices()
      return _value.dsiGetIndices();

    pragma "no doc"
    proc writeThis(f) {
      _value.dsiSerialWrite(f);
    }

    pragma "no doc"
    proc readThis(f) {
      _value.dsiSerialRead(f);
    }

    pragma "no doc"
    proc localSlice(r: range(?)... rank) where _value.type: DefaultRectangularDom {
      if (_value.locale != here) then
        halt("Attempting to take a local slice of a domain on locale ",
             _value.locale.id, " from locale ", here.id);
      return this((...r));
    }

    pragma "no doc"
    proc localSlice(r: range(?)... rank) {
      return _value.dsiLocalSlice(chpl__anyStridable(r), r);
    }

    pragma "no doc"
    proc localSlice(d: domain) {
      return localSlice((...d.getIndices()));
    }

    // associative array interface
    /* Yield the domain indices in sorted order */
    iter sorted(comparator:?t = chpl_defaultComparator()) {
      for i in _value.dsiSorted(comparator) {
        yield i;
      }
    }

    pragma "no doc"
    proc displayRepresentation() { _value.dsiDisplayRepresentation(); }

    pragma "no doc"
    proc defaultSparseDist {
      // For now, this function just returns the same distribution
      // as the dense one. That works for:
      //  * sparse subdomains of defaultDist arrays (they use defaultDist)
      //  * sparse subdomains of Block distributed arrays (they use Block)
      // However, it is likely that DSI implementations will need to be
      // able to further customize this behavior. In particular, we
      // could add e.g. dsiDefaultSparseDist to the DSI interface
      // and have this function use _value.dsiDefaultSparseDist()
      // (or perhaps _value.dist.dsiDefaultSparseDist() ).
      return _getDistribution(_value.dist);
    }

    /* Cast a rectangular domain to another rectangular domain type.
       If the old type is stridable and the new type is not stridable,
       ensure that the stride was 1.
     */
    proc safeCast(type t)
      where chpl__isRectangularDomType(t) && isRectangularDom(this) {
      const tmpD: t;
      if tmpD.rank != this.rank then
        compilerError("rank mismatch in cast");
      if tmpD.idxType != this.idxType then
        compilerError("idxType mismatch in cast");
      if tmpD.stridable == this.stridable then
        return this;
      else if !tmpD.stridable && this.stridable {
        const inds = this.getIndices();
        var unstridableInds: rank*range(tmpD.idxType, stridable=false);

        for param dim in 1..inds.size {
          if inds(dim).stride != 1 then
            halt("non-stridable domain assigned non-unit stride in dimension ", dim);
          unstridableInds(dim) = inds(dim).safeCast(range(tmpD.idxType,
                                                          stridable=false));
        }
        tmpD.setIndices(unstridableInds);
        return tmpD;
      } else /* if tmpD.stridable && !this.stridable */ {
        tmpD = this;
        return tmpD;
      }
    }

    /*
       Returns an array of locales over which this domain has been distributed.
    */
    proc targetLocales() {
      return _value.dsiTargetLocales();
    }

    /* Return true if the local subdomain can be represented as a single
       domain. Otherwise return false. */
    proc hasSingleLocalSubdomain() param {
      return _value.dsiHasSingleLocalSubdomain();
    }

    /* Return the subdomain that is local to the current locale */
    proc localSubdomain() {
      if !_value.dsiHasSingleLocalSubdomain() then
        compilerError("Domain's local domain is not a single domain");
      return _value.dsiLocalSubdomain();
    }

    /* Yield the subdomains that are local to the current locale */
    iter localSubdomains() {
      if _value.dsiHasSingleLocalSubdomain() then
        yield _value.dsiLocalSubdomain();
      else
        for d in _value.dsiLocalSubdomains() do yield d;
    }
  }  // record _domain

  /* Cast a rectangular domain to a new rectangular domain type.  If the old
     type was stridable and the new type is not stridable then assume the
     stride was 1 without checking.

     For example:
     {1..10 by 2}:domain(stridable=false)

     results in the domain '{1..10}'
   */
  pragma "no doc"
  proc _cast(type t, d: domain) where chpl__isRectangularDomType(t) && isRectangularDom(d) {
    const tmpD: t;
    if tmpD.rank != d.rank then
      compilerError("rank mismatch in cast");
    if tmpD.idxType != d.idxType then
      compilerError("idxType mismatch in cast");

    if tmpD.stridable == d.stridable then
      return d;
    else if !tmpD.stridable && d.stridable {
      var inds = d.getIndices();
      var unstridableInds: d.rank*range(tmpD.idxType, stridable=false);

      for param i in 1..tmpD.rank {
        unstridableInds(i) = inds(i):range(tmpD.idxType, stridable=false);
      }
      tmpD.setIndices(unstridableInds);
      return tmpD;
    } else /* if tmpD.stridable && !d.stridable */ {
      tmpD = d;
      return tmpD;
    }
  }

  proc chpl_countDomHelp(dom, counts) {
    var ranges = dom.dims();
    for param i in 1..dom.rank do
      ranges(i) = ranges(i) # counts(i);
    return dom[(...ranges)];
  }

  proc #(dom: domain, counts: integral) where isRectangularDom(dom) && dom.rank == 1 {
    return chpl_countDomHelp(dom, (counts,));
  }

  proc #(dom: domain, counts) where isRectangularDom(dom) && isTuple(counts) {
    if (counts.size != dom.rank) then
      compilerError("the domain and tuple arguments of # must have the same rank");
    return chpl_countDomHelp(dom, counts);
  }

  proc #(arr: [], counts: integral) where isRectangularArr(arr) && arr.rank == 1 {
    return arr[arr.domain#counts];
  }

  proc #(arr: [], counts) where isRectangularArr(arr) && isTuple(counts) {
    if (counts.size != arr.rank) then
      compilerError("the domain and array arguments of # must have the same rank");
    return arr[arr.domain#counts];
  }

  proc +(d: domain, i: index(d)) {
    if isRectangularDom(d) then
      compilerError("Cannot add indices to a rectangular domain");
    else
      compilerError("Cannot add indices to this domain type");
  }

  proc +(i, d: domain) where i: index(d) {
    if isRectangularDom(d) then
      compilerError("Cannot add indices to a rectangular domain");
    else
      compilerError("Cannot add indices to this domain type");
  }

  proc +(d: domain, i: index(d)) where isIrregularDom(d) {
    d.add(i);
    return d;
  }

  proc +(i, d: domain) where i:index(d) && isIrregularDom(d) {
    d.add(i);
    return d;
  }

  proc +(d1: domain, d2: domain) where
                                   (d1.type == d2.type) &&
                                   (isIrregularDom(d1) && isIrregularDom(d2)) {
    var d3: d1.type;
    // These should eventually become forall loops
    for e in d1 do d3.add(e);
    for e in d2 do d3.add(e);
    return d3;
  }

  proc +(d1: domain, d2: domain) {
    if (isRectangularDom(d1) || isRectangularDom(d2)) then
      compilerError("Cannot add indices to a rectangular domain");
    else
      compilerError("Cannot add indices to this domain type");
  }

  proc -(d: domain, i: index(d)) {
    if isRectangularDom(d) then
      compilerError("Cannot remove indices from a rectangular domain");
    else
      compilerError("Cannot remove indices from this domain type");
  }

  proc -(d: domain, i: index(d)) where isIrregularDom(d) {
    d.remove(i);
    return d;
  }

  proc -(d1: domain, d2: domain) where
                                   (d1.type == d2.type) &&
                                   (isSparseDom(d1) || isOpaqueDom(d1)) {
    var d3: d1.type;
    // These should eventually become forall loops
    for e in d1 do d3.add(e);
    for e in d2 do d3.remove(e);
    return d3;
  }

  proc -(d1: domain, d2: domain) {
    if (isRectangularDom(d1) || isRectangularDom(d2)) then
      compilerError("Cannot remove indices from a rectangular domain");
    else
      compilerError("Cannot remove indices from this domain type");
  }

  inline proc ==(d1: domain, d2: domain) where isRectangularDom(d1) &&
                                                        isRectangularDom(d2) {
    if d1._value.rank != d2._value.rank then return false;
    if d1._value == d2._value then return true;
    for param i in 1..d1._value.rank do
      if (d1.dim(i) != d2.dim(i)) then return false;
    return true;
  }

  inline proc !=(d1: domain, d2: domain) where isRectangularDom(d1) &&
                                                        isRectangularDom(d2) {
    if d1._value.rank != d2._value.rank then return true;
    if d1._value == d2._value then return false;
    for param i in 1..d1._value.rank do
      if (d1.dim(i) != d2.dim(i)) then return true;
    return false;
  }

  inline proc ==(d1: domain, d2: domain) where (isAssociativeDom(d1) &&
                                                         isAssociativeDom(d2)) {
    if d1._value == d2._value then return true;
    if d1.numIndices != d2.numIndices then return false;
    for idx in d1 do
      if !d2.member(idx) then return false;
    return true;
  }

  inline proc !=(d1: domain, d2: domain) where (isAssociativeDom(d1) &&
                                                         isAssociativeDom(d2)) {
    if d1._value == d2._value then return false;
    if d1.numIndices != d2.numIndices then return true;
    for idx in d1 do
      if !d2.member(idx) then return true;
    return false;
  }

  inline proc ==(d1: domain, d2: domain) where (isSparseDom(d1) &&
                                                         isSparseDom(d2)) {
    if d1._value == d2._value then return true;
    if d1.numIndices != d2.numIndices then return false;
    if d1._value.parentDom != d2._value.parentDom then return false;
    for idx in d1 do
      if !d2.member(idx) then return false;
    return true;
  }

  inline proc !=(d1: domain, d2: domain) where (isSparseDom(d1) &&
                                                         isSparseDom(d2)) {
    if d1._value == d2._value then return false;
    if d1.numIndices != d2.numIndices then return true;
    if d1._value.parentDom != d2._value.parentDom then return true;
    for idx in d1 do
      if !d2.member(idx) then return true;
    return false;
  }

  // any combinations not handled by the above

  inline proc ==(d1: domain, d2: domain) param {
    return false;
  }

  inline proc !=(d1: domain, d2: domain) param {
    return true;
  }

  pragma "no doc"
  proc shouldReturnRvalueByConstRef(type t) param {
    if !PODValAccess then return true;
    if isPODType(t) then return false;
    return true;
  }

  // Array wrapper record
  pragma "array"
  pragma "has runtime type"
  pragma "ignore noinit"
  pragma "default intent is ref if modified"
  record _array {
    var _pid:int;  // only used when privatized
    var _instance; // generic, but an instance of a subclass of BaseArr
    var _unowned:bool;
    var _promotionType: _value.eltType;

    inline proc _value {
      if _isPrivatized(_instance) {
        return chpl_getPrivatizedCopy(_instance.type, _pid);
      } else {
        return _instance;
      }
    }

    inline proc _do_destroy() {
      if ! _unowned {
        on _instance {
          var (arrToFree, domToRemove) = _instance.remove();
          var domToFree:BaseDom = nil;
          var distToRemove:BaseDist = nil;
          var distToFree:BaseDist = nil;
          // The dead code to access the fields of _instance are left in the
          // generated code with --baseline on. This means that these
          // statements cannot come after the _delete_arr call.
          param domIsPrivatized  = _isPrivatized(_instance.dom);
          param distIsPrivatized = _isPrivatized(_instance.dom.dist);
          // Store the instance's dom class before the instance is destroyed
          const instanceDom = _instance.dom;
          if domToRemove != nil {
            // remove that domain
            (domToFree, distToRemove) = domToRemove.remove();
          }
          if distToRemove != nil {
            distToFree = distToRemove.remove();
          }
          if arrToFree != nil then
            _delete_arr(_instance, _isPrivatized(_instance));
          if domToFree != nil then
            _delete_dom(instanceDom, domIsPrivatized);
          if distToFree != nil then
            _delete_dist(distToFree, distIsPrivatized);
        }
      }
    }

    proc deinit() {
      _do_destroy();
    }

    /* The type of elements contained in the array */
    proc eltType type return _value.eltType;
    /* The type of indices used in the array's domain */
    proc idxType type return _value.idxType;
    proc _dom return _getDomain(_value.dom);
    /* The number of dimensions in the array */
    proc rank param return this.domain.rank;

    // array element access
    // When 'this' is 'const', so is the returned l-value.
    pragma "no doc" // ref version
    pragma "reference to const when const this"
    pragma "removable array access"
    inline proc ref this(i: rank*_value.dom.idxType) ref {
      if isRectangularArr(this) || isSparseArr(this) then
        return _value.dsiAccess(i);
      else
        return _value.dsiAccess(i(1));
    }
    pragma "no doc" // value version, for POD types
    inline proc const this(i: rank*_value.dom.idxType)
    where !shouldReturnRvalueByConstRef(_value.eltType)
    {
      if isRectangularArr(this) || isSparseArr(this) then
        return _value.dsiAccess(i);
      else
        return _value.dsiAccess(i(1));
    }
    pragma "no doc" // const ref version, for not-POD types
    inline proc const this(i: rank*_value.dom.idxType) const ref
    where shouldReturnRvalueByConstRef(_value.eltType)
    {
      if isRectangularArr(this) || isSparseArr(this) then
        return _value.dsiAccess(i);
      else
        return _value.dsiAccess(i(1));
    }



    pragma "no doc" // ref version
    pragma "reference to const when const this"
    pragma "removable array access"
    inline proc ref this(i: _value.dom.idxType ...rank) ref
      return this(i);

    pragma "no doc" // value version, for POD types
    inline proc const this(i: _value.dom.idxType ...rank)
    where !shouldReturnRvalueByConstRef(_value.eltType)
      return this(i);

    pragma "no doc" // const ref version, for not-POD types
    inline proc const this(i: _value.dom.idxType ...rank) const ref
    where shouldReturnRvalueByConstRef(_value.eltType)
      return this(i);


    pragma "no doc" // ref version
    pragma "reference to const when const this"
    inline proc ref localAccess(i: rank*_value.dom.idxType) ref
    {
      if isRectangularArr(this) || isSparseArr(this) then
        return _value.dsiLocalAccess(i);
      else
        return _value.dsiLocalAccess(i(1));
    }
    pragma "no doc" // value version, for POD types
    inline proc const localAccess(i: rank*_value.dom.idxType)
    where !shouldReturnRvalueByConstRef(_value.eltType)
    {
      if isRectangularArr(this) || isSparseArr(this) then
        return _value.dsiLocalAccess(i);
      else
        return _value.dsiLocalAccess(i(1));
    }
    pragma "no doc" // const ref version, for not-POD types
    inline proc const localAccess(i: rank*_value.dom.idxType) const ref
    where shouldReturnRvalueByConstRef(_value.eltType)
    {
      if isRectangularArr(this) || isSparseArr(this) then
        return _value.dsiLocalAccess(i);
      else
        return _value.dsiLocalAccess(i(1));
    }



    pragma "no doc" // ref version
    pragma "reference to const when const this"
    inline proc localAccess(i: _value.dom.idxType ...rank) ref
      return localAccess(i);

    pragma "no doc" // value version, for POD types
    inline proc localAccess(i: _value.dom.idxType ...rank)
    where !shouldReturnRvalueByConstRef(_value.eltType)
      return localAccess(i);

    pragma "no doc" // const ref version, for not-POD types
    inline proc localAccess(i: _value.dom.idxType ...rank) const ref
    where shouldReturnRvalueByConstRef(_value.eltType)
      return localAccess(i);


    // array slicing by a domain
    //
    // requires dense domain implementation that returns a tuple of
    // ranges via the getIndices() method; domain indexing is difficult
    // in the domain case because it has to be implemented on a
    // domain-by-domain basis; this is not terribly difficult in the
    // dense case because we can represent a domain by a tuple of
    // ranges, but in the sparse case, is there a general representation?
    //
    pragma "no doc"
    pragma "reference to const when const this"
    pragma "fn returns aliasing array"
    proc this(d: domain) {
      if d.rank == rank then
        return this((...d.getIndices()));
      else
        compilerError("slicing an array with a domain of a different rank");
    }

    pragma "no doc"
    proc checkSlice(ranges: range(?) ...rank) {
      for param i in 1.._value.dom.rank do
        if !_value.dom.dsiDim(i).boundsCheck(ranges(i)) then
          halt("array slice out of bounds in dimension ", i, ": ", ranges(i));
    }

    // array slicing by a tuple of ranges
    pragma "no doc"
    pragma "reference to const when const this"
    pragma "fn returns aliasing array"
    proc this(ranges: range(?) ...rank) {
      if boundsChecking then
        checkSlice((... ranges));

      pragma "no auto destroy" var d = _dom((...ranges));
      d._value._free_when_no_arrs = true;

      //
      // If this is already a slice array view, we can short-circuit
      // down to the underlying array.
      //
      const (arr, arrpid) = if (_value.isSliceArrayView())
                              then (this._value.arr, this._value._ArrPid)
                              else (this._value, this._pid);

      var a = new ArrayViewSliceArr(eltType=this.eltType,
                                    _DomPid=d._pid,
                                    dom=d._instance,
                                    _ArrPid=arrpid,
                                    _ArrInstance=arr);

      // this doesn't need to lock since we just created the domain d
      d._value.add_arr(a, locking=false);
      return _newArray(a);
    }

    // array rank change
    pragma "no doc"
    pragma "reference to const when const this"
    pragma "fn returns aliasing array"
    proc this(args ...rank) where _validRankChangeArgs(args, _value.dom.idxType) {
      if boundsChecking then
        checkRankChange(args);
      var newD = _dom((...args));
      var ranges = _getRankChangeRanges(newD.dims());
      //
      // TODO: Currently, the domain created to represent the
      // rank-change domain is non-distributed.  Ultimately, we need
      // to create a domain view class that supports a rank-change
      // view on a higher-dimensional domain as in the original array
      // view attempt.
      //
      pragma "no auto destroy" var d = {(...ranges)};
      d._value._free_when_no_arrs = true;

      //
      // Compute which dimensions are collapsed and what the index
      // (idx) is in the event that it is.  These will be stored in
      // the array view to convert from lower-D indices to higher-.
      //
      var collapsedDim: rank*bool;
      var idx: rank*idxType;

      for param i in 1..rank {
        if (isRange(args(i))) {
          collapsedDim(i) = false;
        } else {
          collapsedDim(i) = true;
          idx(i) = args(i);
        }
      }

      // TODO: With additional effort, we could collapse rank changes of
      // rank-change array views to a single array view, similar to what
      // we do for slices.
      const (arr, arrpid)  = (this._value, this._pid);

      var a = new ArrayViewRankChangeArr(eltType=this.eltType,
                                         _DomPid = d._pid,
                                         dom = d._instance,
                                         _ArrPid=arrpid,
                                         _ArrInstance=arr,
                                         collapsedDim=collapsedDim,
                                         idx=idx);

      // this doesn't need to lock since we just created the domain d
      d._value.add_arr(a, locking=false);
      return _newArray(a);
    }

    pragma "no doc"
    proc checkRankChange(args) {
      for param i in 1..args.size do
        if !_value.dom.dsiDim(i).boundsCheck(args(i)) then
          halt("array slice out of bounds in dimension ", i, ": ", args(i));
    }

    // Special cases of local slices for DefaultRectangularArrs because
    // we can't take an alias of the ddata class within that class
    pragma "no doc"
    pragma "reference to const when const this"
    pragma "fn returns aliasing array"
    proc localSlice(r: range(?)... rank) where _value.type: DefaultRectangularArr {
      if boundsChecking then
        checkSlice((...r));
      var dom = _dom((...r));
      return chpl__localSliceDefaultArithArrHelp(dom);
    }

    pragma "no doc"
    pragma "reference to const when const this"
    pragma "fn returns aliasing array"
    proc localSlice(d: domain) where _value.type: DefaultRectangularArr {
      if boundsChecking then
        checkSlice((...d.getIndices()));

      return chpl__localSliceDefaultArithArrHelp(d);
    }

    pragma "no copy return"
    proc chpl__localSliceDefaultArithArrHelp(d: domain) {
      if (_value.locale != here) then
        halt("Attempting to take a local slice of an array on locale ",
             _value.locale.id, " from locale ", here.id);
      return this(d);
    }
    pragma "no doc"
    pragma "reference to const when const this"
    pragma "fn returns aliasing array"
    proc localSlice(r: range(?)... rank) {
      if boundsChecking then
        checkSlice((...r));
      return _value.dsiLocalSlice(r);
    }

    pragma "no doc"
    pragma "reference to const when const this"
    pragma "fn returns aliasing array"
    proc localSlice(d: domain) {
      return localSlice((...d.getIndices()));
    }

    pragma "no doc"
    inline proc these() {
      return _value.these();
    }

    // 1/5/10: do we need this since it always returns domain.numIndices?
    /* Return the number of elements in the array */
    proc numElements return _value.dom.dsiNumIndices;
    /* Return the number of elements in the array */
    proc size return numElements;

    pragma "no doc"
    pragma "reference to const when const this"
    pragma "new alias fn"
    pragma "fn returns aliasing array"
    proc newAlias() {
      var x = _value;
      pragma "no copy"
      var ret = _getArray(x);
      return ret;
    }

    //
    // This routine determines whether an actual array argument
    // ('this')'s domain is appropriate for a formal array argument
    // that specifies a domain ('formalDom').  It does this using a
    // mix of static checks (do the ranks match, are the domain map
    // types the same if the formal isn't the default dist?) and
    // runtime checks (are the domains' index sets the same; are
    // the domain maps/distributions equivalent?)
    //
    // The 'runtimeChecks' argument indicates whether or not runtime
    // checks should be performed and is set based on the value of
    // the --no-formal-domain-checks flag.
    //
    inline proc chpl_checkArrArgDoms(formalDom: domain, param runtimeChecks: bool) {
      //
      // It's a compile-time error if the ranks don't match
      //
      if (formalDom.rank != this.domain.rank) then
        compilerError("Rank mismatch passing array argument: expected " +
                      formalDom.rank + " but got " + this.domain.rank, errorDepth=2);

      //
      // If the formal domain specifies a domain map other than the
      // default one, then we're putting a constraint on the domain
      // map of the actual that's being passed in.  If it's the
      // default, we take that as an indication that the routine is
      // generic w.r.t. domain map for now (though we may wish to
      // change this in the future when we have better syntax for
      // indicating a generic domain map)..
      //
      if (formalDom.dist._value.type != DefaultDist) {
        //
        // First, at compile-time, check that the domain's types are
        // the same:
        //
        if (formalDom.type != this.domain.type) then
          compilerError("Domain type mismatch in passing array argument", errorDepth=2);

        //
        // Then, at run-time, check that the domain map's values are
        // the same (do this only if the runtime checks argument is true).
        //
        if (runtimeChecks && formalDom.dist != this.domain.dist) then
          halt("Domain map mismatch passing array argument:\n",
               "  Formal domain map is: ", formalDom.dist, "\n",
               "  Actual domain map is: ", this.domain.dist);
      }

      //
      // If we pass those checks, verify at runtime that the index
      // sets of the formal and actual match (do this only if the
      // runtime checks argument is true).
      //
      if (runtimeChecks && formalDom != this.domain) then
        halt("Domain mismatch passing array argument:\n",
             "  Formal domain is: ", formalDom, "\n",
             "  Actual domain is: ", this.domain);
    }

    pragma "no doc"
    pragma "fn returns aliasing array"
    proc reindex(d: domain)
      where isRectangularDom(this.domain) && isRectangularDom(d)
    {
      if rank != d.rank then
        compilerError("rank mismatch: cannot reindex() from " + rank +
                      " dimension(s) to " + d.rank);

      for param i in 1..rank do
        if d.dim(i).length != _value.dom.dsiDim(i).length then
          halt("extent in dimension ", i, " does not match actual");

      //
      // TODO: Currently, the domain created to represent the
      // rank-change domain is non-distributed.  Ultimately, we need
      // to create a domain view class that supports a rank-change
      // view on a higher-dimensional domain as in the original array
      // view attempt.
      //
      pragma "no auto destroy" var newDom = {(...d.dims())};
      newDom._value._free_when_no_arrs = true;

      // TODO: With additional effort, we could collapse rank changes of
      // rank-change array views to a single array view, similar to what
      // we do for slices.
      const (arr, arrpid) = (this._value, this._pid);

      var x = new ArrayViewReindexArr(eltType=this.eltType,
                                      _DomPid = newDom._pid,
                                      dom = newDom._instance,
                                      _ArrPid=arrpid,
                                      _ArrInstance=arr);
      // this doesn't need to lock since we just created the domain d
      newDom._value.add_arr(x, locking=false);
      return _newArray(x);
    }

    // reindex for all non-rectangular domain types.
    // See above for the rectangular version.
    pragma "no doc"
    pragma "fn returns aliasing array"
    proc reindex(d:domain) {
      compilerError("Reindexing non-rectangular arrays is not permitted.");
    }

    pragma "no doc"
    proc writeThis(f) {
      _value.dsiSerialWrite(f);
    }

    pragma "no doc"
    proc readThis(f) {
      _value.dsiSerialRead(f);
    }

    proc IRV where !isSparseArr(this) {
      compilerError("only sparse arrays have an IRV");
    }

    // sparse array interface
    /* Return the Implicitly Represented Value for sparse arrays */
    proc IRV ref where isSparseArr(this) {
      return _value.IRV;
    }

    /* Yield the array elements in sorted order. */
    iter sorted(comparator:?t = chpl_defaultComparator()) {
      use Reflection;
      if canResolveMethod(_value, "dsiSorted", comparator) {
        for i in _value.dsiSorted(comparator) {
          yield i;
        }
      } else if canResolveMethod(_value, "dsiSorted") {
        compilerError(_value.type:string + " does not support dsiSorted(comparator)");
      } else {
        use Sort;
        var copy = this;
        sort(copy, comparator=comparator);
        for ind in copy do
          yield ind;
      }
    }

    pragma "no doc"
    proc displayRepresentation() { _value.dsiDisplayRepresentation(); }

    /*
       Returns an array of locales over which this array has been distributed.
    */
    //
    // TODO: Is it really appropriate that the array should provide
    // this dsi routine rather than having this call forward to the
    // domain[.dist] here?  Do any of the array implementations do
    // anything other than that with it?
    //
    proc targetLocales() {
      return _value.dsiTargetLocales();
    }

    /* Return true if the local subdomain can be represented as a single
       domain. Otherwise return false. */
    proc hasSingleLocalSubdomain() param {
      return _value.dsiHasSingleLocalSubdomain();
    }

    /* Return the subdomain that is local to the current locale */
    proc localSubdomain() {
      if !_value.dsiHasSingleLocalSubdomain() then
        compilerError("Array's local domain is not a single domain");
      return _value.dsiLocalSubdomain();
    }

    /* Yield the subdomains that are local to the current locale */
    iter localSubdomains() {
      if _value.dsiHasSingleLocalSubdomain() then
        yield _value.dsiLocalSubdomain();
      else
        for d in _value.dsiLocalSubdomains() do yield d;
    }

    proc chpl__isDense1DArray() param {
      return isRectangularArr(this) &&
             this.rank == 1 &&
             !this._value.stridable;
    }

    inline proc chpl__assertSingleArrayDomain(fnName: string) {
      if this.domain._value._arrs.length != 1 then
        halt("cannot call " + fnName +
             " on an array defined over a domain with multiple arrays");
    }

    /* The following methods are intended to provide a list or vector style
       interface to 1D unstridable rectangular arrays.  They are only intended
       for use on arrays that have a 1:1 correspondence with their domains.
       All methods here that modify the array's domain assert that this 1:1
       property holds.

       These are currently not parallel safe, and cannot safely be called by
       multiple tasks simultaneously on the same array.
     */

    /* Return true if the array has no elements */
    proc isEmpty(): bool {
      return this.numElements == 0;
    }

    /* Return the first value in the array */
    // The return type used here is currently not pretty in the generated
    // documentation. Don't document it for now.
    pragma "no doc"
    proc head(): this._value.eltType {
      return this[this.domain.alignedLow];
    }

    /* Return the last value in the array */
    // The return type used here is currently not pretty in the generated
    // documentation. Don't document it for now.
    pragma "no doc"
    proc tail(): this._value.eltType {
      return this[this.domain.alignedHigh];
    }

    /* Return a range that is grown or shrunk from r to accommodate 'r2' */
    pragma "no doc"
    inline proc resizeAllocRange(r: range, r2: range,
                                 factor=arrayAsVecGrowthFactor,
                                 param direction=1, param grow=1) {
      // This should only be called for 1-dimensional arrays
      const lo = r.low,
            hi = r.high,
            size = hi - lo + 1;
      if grow > 0 {
        const newSize = max(size+1, (size*factor):int); // Always grow by at least 1.
        if direction > 0 {
          return lo..#newSize;
        } else {
          return ..hi#-newSize;
        }
      } else {
        const newSize = min(size-1, (size/factor):int);
        if direction > 0 {
          var newRange = lo..#newSize;
          if newRange.high < r2.high {
            // not able to take enough spaces off the high end.  Take them
            // off the low end instead.
            const spaceNeeded = r2.high - newRange.high;
            newRange = (newRange.low+spaceNeeded)..r2.high;
          }
          return newRange;
        } else {
          var newRange = ..hi # -newSize;
          if newRange.low > r2.low {
            // not able to take enough spaces off the low end.  Take them
            // off the high end instead.
            const spaceNeeded = newRange.low - r2.low;
            newRange = r2.low..(newRange.high-spaceNeeded);
          }
          return newRange;
        }
      }
    }

    /* Add element ``val`` to the back of the array, extending the array's
       domain by one. If the domain was ``{1..5}`` it will become ``{1..6}``.

       The array must be a rectangular 1-D array; its domain must be
       non-stridable and not shared with other arrays.
     */
    proc push_back(val: this.eltType) {
      if (!chpl__isDense1DArray()) then
        compilerError("push_back() is only supported on dense 1D arrays");

      chpl__assertSingleArrayDomain("push_back");
      const lo = this.domain.low,
            hi = this.domain.high+1;
      const newRange = lo..hi;
      on this._value {
        if !this._value.dataAllocRange.member(hi) {
          /* The new index is not in the allocated space.  We'll need to
             realloc it. */
          if this._value.dataAllocRange.length < this.domain.numIndices {
            /* if dataAllocRange has fewer indices than this.domain it must not
               be set correctly.  Set it to match this.domain to start.
             */
            this._value.dataAllocRange = this.domain.low..this.domain.high;
          }
          const oldRng = this._value.dataAllocRange;
          const nextAllocRange = resizeAllocRange(this._value.dataAllocRange, newRange);
          if debugArrayAsVec then
            writeln("push_back reallocate: ",
                    oldRng, " => ", nextAllocRange,
                    " (", newRange, ")");
          this._value.dsiReallocate({nextAllocRange});
          // note: dsiReallocate sets _value.dataAllocRange = nextAllocRange
        }
        this.domain.setIndices((newRange,));
        this._value.dsiPostReallocate();
      }
      this[hi] = val;
    }

    /* Remove the last element from the array, reducing the size of the
       domain by one. If the domain was ``{1..5}`` it will become ``{1..4}``

       The array must be a rectangular 1-D array; its domain must be
       non-stridable and not shared with other arrays.
     */
    proc pop_back() {
      if (!chpl__isDense1DArray()) then
        compilerError("pop_back() is only supported on dense 1D arrays");

      chpl__assertSingleArrayDomain("pop_back");

      if boundsChecking && isEmpty() then
        halt("pop_back called on empty array");

      const lo = this.domain.low,
            hi = this.domain.high-1;
      const newRange = lo..hi;
      on this._value {
        if this._value.dataAllocRange.length < this.domain.numIndices {
          this._value.dataAllocRange = this.domain.low..this.domain.high;
        }
        if newRange.length < (this._value.dataAllocRange.length / (arrayAsVecGrowthFactor*arrayAsVecGrowthFactor)):int {
          const oldRng = this._value.dataAllocRange;
          const nextAllocRange = resizeAllocRange(this._value.dataAllocRange, newRange, grow=-1);
          if debugArrayAsVec then
            writeln("pop_back reallocate: ",
                    oldRng, " => ", nextAllocRange,
                    " (", newRange, ")");
          this._value.dsiReallocate({nextAllocRange});
          // note: dsiReallocate sets _value.dataAllocRange = nextAllocRange
        }
        this.domain.setIndices((newRange,));
        this._value.dsiPostReallocate();
      }
    }

    /* Add element ``val`` to the front of the array, extending the array's
       domain by one. If the domain was ``{1..5}`` it will become ``{0..5}``.

       The array must be a rectangular 1-D array; its domain must be
       non-stridable and not shared with other arrays.
     */
    proc push_front(val: this.eltType) {
      if (!chpl__isDense1DArray()) then
        compilerError("push_front() is only supported on dense 1D arrays");
      chpl__assertSingleArrayDomain("push_front");
      const lo = this.domain.low-1,
            hi = this.domain.high;
      const newRange = lo..hi;
      on this._value {
        if !this._value.dataAllocRange.member(lo) {
          if this._value.dataAllocRange.length < this.domain.numIndices {
            this._value.dataAllocRange = this.domain.low..this.domain.high;
          }
          const oldRng = this._value.dataAllocRange;
          const nextAllocRange = resizeAllocRange(this._value.dataAllocRange, newRange, direction=-1);
          if debugArrayAsVec then
            writeln("push_front reallocate: ",
                    oldRng, " => ", nextAllocRange,
                    " (", newRange, ")");
          this._value.dsiReallocate({nextAllocRange});
          // note: dsiReallocate sets _value.dataAllocRange = nextAllocRange
        }
        this.domain.setIndices((newRange,));
        this._value.dsiPostReallocate();
      }
      this[lo] = val;
    }

    /* Remove the first element of the array reducing the size of the
       domain by one.  If the domain was ``{1..5}`` it will become ``{2..5}``.

       The array must be a rectangular 1-D array; its domain must be
       non-stridable and not shared with other arrays.
     */
    proc pop_front() {
      if (!chpl__isDense1DArray()) then
        compilerError("pop_front() is only supported on dense 1D arrays");
      chpl__assertSingleArrayDomain("pop_front");

      if boundsChecking && isEmpty() then
        halt("pop_front called on empty array");

      const lo = this.domain.low+1,
            hi = this.domain.high;
      const newRange = lo..hi;
      on this._value {
        if this._value.dataAllocRange.length < this.domain.numIndices {
          this._value.dataAllocRange = this.domain.low..this.domain.high;
        }
        if newRange.length < (this._value.dataAllocRange.length / (arrayAsVecGrowthFactor*arrayAsVecGrowthFactor)):int {
          const oldRng = this._value.dataAllocRange;
          const nextAllocRange = resizeAllocRange(this._value.dataAllocRange, newRange, direction=-1, grow=-1);
          if debugArrayAsVec then
            writeln("pop_front reallocate: ",
                    oldRng, " => ", nextAllocRange,
                    " (", newRange, ")");
          this._value.dsiReallocate({nextAllocRange});
          // note: dsiReallocate sets _value.dataAllocRange = nextAllocRange
        }
        this.domain.setIndices((newRange,));
        this._value.dsiPostReallocate();
      }
    }

    /* Insert element ``val`` into the array at index ``pos``. Shift the array
       elements above ``pos`` up one index. If the domain was ``{1..5}`` it will
       become ``{1..6}``.

       The array must be a rectangular 1-D array; its domain must be
       non-stridable and not shared with other arrays.
     */
    proc insert(pos: this.idxType, val: this.eltType) {
      if (!chpl__isDense1DArray()) then
        compilerError("insert() is only supported on dense 1D arrays");

      chpl__assertSingleArrayDomain("insert");
      const lo = this.domain.low,
            hi = this.domain.high+1;
      const newRange = lo..hi;

      if boundsChecking && !newRange.member(pos) then
        halt("insert at position " + pos + " out of bounds");

      on this._value {
        if !this._value.dataAllocRange.member(hi) {
          if this._value.dataAllocRange.length < this.domain.numIndices {
            this._value.dataAllocRange = this.domain.low..this.domain.high;
          }
          const nextAllocRange = resizeAllocRange(this._value.dataAllocRange, newRange);
          this._value.dsiReallocate({nextAllocRange});
          // note: dsiReallocate sets _value.dataAllocRange = nextAllocRange
        }
        this.domain.setIndices((newRange,));
        this._value.dsiPostReallocate();
      }
      for i in pos..hi-1 by -1 do this[i+1] = this[i];
      this[pos] = val;
    }

    /* Remove the element at index ``pos`` from the array and shift the array
       elements above ``pos`` down one index. If the domain was ``{1..5}``
       it will become ``{1..4}``.

       The array must be a rectangular 1-D array; its domain must be
       non-stridable and not shared with other arrays.
     */
    proc remove(pos: this.idxType) {
      if (!chpl__isDense1DArray()) then
        compilerError("remove() is only supported on dense 1D arrays");
      chpl__assertSingleArrayDomain("remove");

      if boundsChecking && !this.domain.member(pos) then
        halt("remove at position " + pos + " out of bounds");

      const lo = this.domain.low,
            hi = this.domain.high-1;
      const newRange = lo..hi;
      for i in pos..hi {
        this[i] = this[i+1];
      }
      on this._value {
        if this._value.dataAllocRange.length < this.domain.numIndices {
          this._value.dataAllocRange = this.domain.low..this.domain.high;
        }
        if newRange.length < (this._value.dataAllocRange.length / (arrayAsVecGrowthFactor*arrayAsVecGrowthFactor)):int {
          const nextAllocRange = resizeAllocRange(this._value.dataAllocRange, newRange, grow=-1);
          this._value.dsiReallocate({nextAllocRange});
          // note: dsiReallocate sets _value.dataAllocRange = nextAllocRange
        }
        this.domain.setIndices((newRange,));
        this._value.dsiPostReallocate();
      }
    }

    /* Remove ``count`` elements from the array starting at index ``pos`` and
       shift elements above ``pos+count`` down by ``count`` indices.

       The array must be a rectangular 1-D array; its domain must be
       non-stridable and not shared with other arrays.
     */
    proc remove(pos: this.idxType, count: this.idxType) {
      if (!chpl__isDense1DArray()) then
        compilerError("remove() is only supported on dense 1D arrays");
      chpl__assertSingleArrayDomain("remove count");
      const lo = this.domain.low,
            hi = this.domain.high-count;
      if boundsChecking && pos+count-1 > this.domain.high then
        halt("remove at position ", pos+count-1, " out of bounds");
      if boundsChecking && pos < lo then
        halt("remove at position ", pos, " out of bounds");

      const newRange = lo..hi;
      for i in pos..hi {
        this[i] = this[i+count];
      }
      on this._value {
        if this._value.dataAllocRange.length < this.domain.numIndices {
          this._value.dataAllocRange = this.domain.low..this.domain.high;
        }
        if newRange.length < (this._value.dataAllocRange.length / (arrayAsVecGrowthFactor*arrayAsVecGrowthFactor)):int {
          const nextAllocRange = resizeAllocRange(this._value.dataAllocRange, newRange, grow=-1);
          this._value.dsiReallocate({nextAllocRange});
          // note: dsiReallocate sets _value.dataAllocRange = nextAllocRange
        }
        this.domain.setIndices((newRange,));
        this._value.dsiPostReallocate();
      }
    }

    /* Remove the elements at the indices in the ``pos`` range and shift the
       array elements down by ``pos.size`` elements. If the domain was
       ``{1..5}`` and this is called with ``2..3`` as an argument, the new
       domain would be ``{1..3}`` and the array would contain the elements
       formerly at positions 1, 4, and 5.

       The array must be a rectangular 1-D array; its domain must be
       non-stridable and not shared with other arrays.
     */
    proc remove(pos: range(this.idxType, stridable=false)) {
      if (!chpl__isDense1DArray()) then
        compilerError("remove() is only supported on dense 1D arrays");
      chpl__assertSingleArrayDomain("remove range");
      remove(pos.low, pos.size);
    }

    /* Reverse the order of the values in the array. */
    proc reverse() {
      if (!chpl__isDense1DArray()) then
        compilerError("reverse() is only supported on dense 1D arrays");
      const lo = this.domain.low,
            mid = this.domain.size / 2,
            hi = this.domain.high;
      for i in 0..#mid {
        this[lo + i] <=> this[hi - i];
      }
    }

    /* Remove all elements from the array leaving the domain empty. If the
       domain was ``{5..10}`` it will become ``{5..4}``.

       The array must be a rectangular 1-D array; its domain must be
       non-stridable and not shared with other arrays.
     */
    proc clear() {
      if (!chpl__isDense1DArray()) then
        compilerError("clear() is only supported on dense 1D arrays");
      chpl__assertSingleArrayDomain("clear");
      const lo = this.domain.low,
            hi = this.domain.low-1;
      assert(hi < lo, "overflow occurred subtracting 1 from low bound in clear");
      const newRange = lo..hi;
      on this._value {
        this._value.dsiReallocate({newRange});
        this.domain.setIndices((newRange,));
        this._value.dsiPostReallocate();
      }
    }

    /* Return a tuple containing ``true`` and the index of the first
       instance of ``val`` in the array, or if ``val`` is not found, a
       tuple containing ``false`` and an unspecified value is returned.
     */
    proc find(val: this.eltType): (bool, index(this.domain)) {
      for i in this.domain {
        if this[i] == val then return (true, i);
      }
      var arbInd: index(this.domain);
      return (false, arbInd);
    }

    /* Return the number of times ``val`` occurs in the array. */
    proc count(val: this.eltType): int {
      var total: int = 0;
      for i in this do if i == val then total += 1;
      return total;
    }

   /* Returns a tuple of integers describing the size of each dimension.
      For a sparse array, returns the shape of the parent domain.*/
    proc shape {
      return this.domain.shape;
    }

  }  // record _array

  //
  // A helper function to check array equality (== on arrays promotes
  // to an array of booleans)
  //
  /* Return true if all this array is the same size and shape
     as argument ``that`` and all elements of this array are
     equal to the corresponding element in ``that``. Otherwise
     return false. */
  proc _array.equals(that: _array) {
    //
    // quick path for identical arrays
    //
    if this._value == that._value then
      return true;
    //
    // quick path for rank mismatches
    //
    if this.rank != that.rank then
      return false;

    if this.numElements != that.numElements then
      return false;

    //
    // check that size/shape are the same to permit legal zippering
    //
    if isRectangularDom(this.domain) && isRectangularDom(that.domain) {
      for d in 1..this.rank do
        if this.domain.dim(d).size != that.domain.dim(d).size then
          return false;
    }
    //
    // if all the above tests match, see if zippered equality is
    // true everywhere
    //
    return && reduce (this == that);
  }

  // The same as the built-in _cast, except accepts a param arg.
  pragma "no doc"
  proc _cast(type t, param arg) where t: _array {
    var result: t;
    // The would-be param version of proc =, inlined.
    chpl__transferArray(result, arg);
    return result;
  }


  //
  // isXxxType, isXxxValue
  //

  /* Return true if ``t`` is a domain map type. Otherwise return false. */
  proc isDmapType(type t) param {
    proc isDmapHelp(type t: _distribution) param  return true;
    proc isDmapHelp(type t)                param  return false;
    return isDmapHelp(t);
  }

  pragma "no doc"
  proc isDmapValue(e: _distribution) param  return true;
  /* Return true if ``e`` is a domain map. Otherwise return false. */
  proc isDmapValue(e)                param  return false;

  /* Return true if ``t`` is a domain type. Otherwise return false. */
  proc isDomainType(type t) param {
    proc isDomainHelp(type t: _domain) param  return true;
    proc isDomainHelp(type t)          param  return false;
    return isDomainHelp(t);
  }

  pragma "no doc"
  proc isDomainValue(e: domain) param  return true;
  /* Return true if ``e`` is a domain. Otherwise return false. */
  proc isDomainValue(e)         param  return false;

  /* Return true if ``t`` is an array type. Otherwise return false. */
  proc isArrayType(type t) param {
    proc isArrayHelp(type t: _array) param  return true;
    proc isArrayHelp(type t)         param  return false;
    return isArrayHelp(t);
  }

  pragma "no doc"
  proc isArrayValue(e: []) param  return true;
  /* Return true if ``e`` is an array. Otherwise return false. */
  proc isArrayValue(e)     param  return false;

//
//     The following functions define set operations on associative arrays.
//

  // promotion for associative array addition doesn't really make sense. instead,
  // we really just want a union
  proc +(a :_array, b: _array) where (a._value.type == b._value.type) && isAssociativeArr(a) {
    return a | b;
  }

  proc +=(ref a :_array, b: _array) where (a._value.type == b._value.type) && isAssociativeArr(a) {
    a.chpl__assertSingleArrayDomain("+=");
    a |= b;
  }

  proc |(a :_array, b: _array) where (a._value.type == b._value.type) && isAssociativeArr(a) {
    var newDom = a.domain | b.domain;
    var ret : [newDom] a.eltType;
    serial !newDom._value.parSafe {
      forall (k,v) in zip(a.domain, a) do ret[k] = v;
      forall (k,v) in zip(b.domain, b) do ret[k] = v;
    }
    return ret;
  }

  proc |=(ref a :_array, b: _array) where (a._value.type == b._value.type) && isAssociativeArr(a) {
    a.chpl__assertSingleArrayDomain("|=");
    serial !a.domain._value.parSafe {
      forall i in b.domain do a.domain.add(i);
      forall (k,v) in zip(b.domain, b) do a[k] = v;
    }
  }

  proc &(a :_array, b: _array) where (a._value.type == b._value.type) && isAssociativeArr(a) {
    var newDom = a.domain & b.domain;
    var ret : [newDom] a.eltType;

    serial !newDom._value.parSafe do
      forall k in newDom do ret[k] = a[k];
    return ret;
  }

  proc &=(ref a :_array, b: _array) where (a._value.type == b._value.type) && isAssociativeArr(a) {
    a.chpl__assertSingleArrayDomain("&=");
    serial !a.domain._value.parSafe {
      forall k in a.domain {
        if !b.domain.member(k) then a.domain.remove(k);
      }
    }
  }

  proc -(a :_array, b: _array) where (a._value.type == b._value.type) && isAssociativeArr(a) {
    var newDom = a.domain - b.domain;
    var ret : [newDom] a.eltType;

    serial !newDom._value.parSafe do
      forall k in newDom do ret[k] = a[k];

    return ret;
  }

  proc -=(ref a :_array, b: _array) where (a._value.type == b._value.type) && isAssociativeArr(a) {
    a.chpl__assertSingleArrayDomain("-=");
    serial !a.domain._value.parSafe do
      forall k in a.domain do
        if b.domain.member(k) then a.domain.remove(k);
  }


  proc ^(a :_array, b: _array) where (a._value.type == b._value.type) && isAssociativeArr(a) {
    var newDom = a.domain ^ b.domain;
    var ret : [newDom] a.eltType;

    serial !newDom._value.parSafe {
      forall k in a.domain do
        if !b.domain.member(k) then ret[k] = a[k];
      forall k in b.domain do
        if !a.domain.member(k) then ret[k] = b[k];
    }

    return ret;
  }

  proc ^=(ref a :_array, b: _array) where (a._value.type == b._value.type) && isAssociativeArr(a) {
    a.chpl__assertSingleArrayDomain("^=");
    serial !a.domain._value.parSafe {
      forall k in b.domain {
        if a.domain.member(k) then a.domain.remove(k);
        else a.domain.add(k);
      }
      forall k in b.domain {
        if a.domain.member(k) then a[k] = b[k];
      }
    }
  }

  proc -(a :domain, b :domain) where (a.type == b.type) && isAssociativeDom(a) {
    var newDom : a.type;
    serial !newDom._value.parSafe do
      forall e in a do
        if !b.member(e) then newDom.add(e);
    return newDom;
  }

  /*
     We remove elements in the RHS domain from those in the LHS domain only if
     they exist. If an element in the RHS is not present in the LHS, no error
     occurs.
  */
  proc -=(ref a :domain, b :domain) where (a.type == b.type) && isAssociativeDom(a) {
    for e in b do
      if a.member(e) then
        a.remove(e);
  }

  proc |(a :domain, b: domain) where (a.type == b.type) && isAssociativeDom(a) {
    return a + b;
  }

  proc |=(ref a :domain, b: domain) where (a.type == b.type) && isAssociativeDom(a) {
    for e in b do
      a.add(e);
  }

  proc +=(ref a :domain, b: domain) where (a.type == b.type) && isAssociativeDom(a) {
    a |= b;
  }

  /*
     We remove elements in the RHS domain from those in the LHS domain only if
     they exist. If an element in the RHS is not present in the LHS, no error
     occurs.
  */
  proc &(a :domain, b: domain) where (a.type == b.type) && isAssociativeDom(a) {
    var newDom : a.type;

    serial !newDom._value.parSafe do
      forall k in a with (ref newDom) do // no race - in 'serial'
        if b.member(k) then newDom += k;
    return newDom;
  }

  proc &=(ref a :domain, b: domain) where (a.type == b.type) && isAssociativeDom(a) {
    for e in a do
      if !b.member(e) then
        a.remove(e);
  }

  proc ^(a :domain, b: domain) where (a.type == b.type) && isAssociativeDom(a) {
    var newDom : a.type;

    serial !newDom._value.parSafe {
      forall k in a do
        if !b.member(k) then newDom.add(k);
      forall k in b do
        if !a.member(k) then newDom.add(k);
    }

    return newDom;
  }

  /*
     We remove elements in the RHS domain from those in the LHS domain only if
     they exist. If an element in the RHS is not present in the LHS, it is
     added to the LHS.
  */
  proc ^=(ref a :domain, b: domain) where (a.type == b.type) && isAssociativeDom(a) {
    for e in a do
      if b.member(e) then
        a.remove(e);
      else
        a.add(e);
  }
  //
  // Helper functions
  //

  pragma "no doc"
  proc isCollapsedDimension(r: range(?e,?b,?s,?a)) param return false;
  pragma "no doc"
  proc isCollapsedDimension(r) param return true;


  // computes || reduction over stridable of ranges
  proc chpl__anyStridable(ranges, param d: int = 1) param {
    for param i in 1..ranges.size do
      if ranges(i).stridable then
        return true;
    return false;
  }

  // given a tuple args, returns true if the tuple contains only
  // integers and ranges; that is, it is a valid argument list for rank
  // change
  proc _validRankChangeArgs(args, type idxType) param {
    proc _isRange(type idxType, r: range(?)) param return true;
    proc _isRange(type idxType, x) param return false;

    proc _validRankChangeArg(type idxType, r: range(?)) param return true;
    proc _validRankChangeArg(type idxType, i: idxType) param return true;
    proc _validRankChangeArg(type idxType, x) param return false;

    /*
    proc help(param dim: int) param {
      if !_validRankChangeArg(idxType, args(dim)) then
        return false;
      else if dim < args.size then
        return help(dim+1);
      else
        return true;
    }*/

    proc allValid() param {
      for param dim in 1.. args.size {
        if !_validRankChangeArg(idxType, args(dim)) then
          return false;
      }
      return true;
    }
    proc oneRange() param {
      for param dim in 1.. args.size {
        if _isRange(idxType, args(dim)) then
          return true;
      }
      return false;
    }

    return allValid() && oneRange();
    //return help(1);
  }

  proc _getRankChangeRanges(args) {
    proc _tupleize(x) {
      var y: 1*x.type;
      y(1) = x;
      return y;
    }
    proc collectRanges(param dim: int) {
      if dim > args.size then
        compilerError("domain slice requires a range in at least one dimension");
      if isRange(args(dim)) then
        return collectRanges(dim+1, _tupleize(args(dim)));
      else
        return collectRanges(dim+1);
    }
    proc collectRanges(param dim: int, x: _tuple) {
      if dim > args.size {
        return x;
      } else if dim < args.size {
        if isRange(args(dim)) then
          return collectRanges(dim+1, ((...x), args(dim)));
        else
          return collectRanges(dim+1, x);
      } else {
        if isRange(args(dim)) then
          return ((...x), args(dim));
        else
          return x;
      }
    }
    return collectRanges(1);
  }

  //
  // Assignment of domains and arrays
  //
  proc =(ref a: _distribution, b: _distribution) {
    if a._value == nil {
      __primitive("move", a, chpl__autoCopy(b.clone()));
    } else if a._value._doms.length == 0 {
      if a._value.type != b._value.type then
        compilerError("type mismatch in distribution assignment");
      if a._value == b._value {
        // do nothing
      } else
        a._value.dsiAssign(b._value);
      if _isPrivatized(a._instance) then
        _reprivatize(a._value);
    } else {
      halt("assignment to distributions with declared domains is not yet supported");
    }
  }

  proc =(ref a: domain, b: domain) {
    if a.rank != b.rank then
      compilerError("rank mismatch in domain assignment");
    if a.idxType != b.idxType then
      compilerError("index type mismatch in domain assignment");
    if isRectangularDom(a) && isRectangularDom(b) then
      if !a.stridable && b.stridable then
        compilerError("cannot assign from a stridable domain to an unstridable domain without an explicit cast");

    if !isIrregularDom(a) && !isIrregularDom(b) {
      for e in a._instance._arrs do {
        on e do e.dsiReallocate(b);
      }
      a.setIndices(b.getIndices());
      for e in a._instance._arrs do {
        on e do e.dsiPostReallocate();
      }
    } else {
      //
      // BLC: It's tempting to do a clear + add here, but because
      // we need to preserve array values that are in the intersection
      // between the old and new index sets, we use the following
      // instead.
      //
      // TODO: These should eventually become forall loops, hence the
      // warning
      //
      // NOTE: For the current implementation of associative domains,
      // the domain iteration is parallelized, but modification
      // of the underlying data structures (in particular, the _resize()
      // operation on the table) is not thread-safe.  Something more
      // intelligent will likely be needed before it is worth it to
      // parallelize whole-domain assignment for associative arrays.
      //

//      disabled for testing for the same reason
//      as the array version: it can be called from autoCopy/initCopy.
//      compilerWarning("whole-domain assignment has been serialized (see note in $CHPL_HOME/STATUS)");
      for i in a._value.dsiIndsIterSafeForRemoving() {
        if !b.member(i) {
          a.remove(i);
        }
      }
      for i in b {
        if !a.member(i) {
          a.add(i);
        }
      }
    }
  }

  proc =(ref a: domain, b: _tuple) {
    a.clear();
    for ind in 1..b.size {
      a.add(b(ind));
    }
  }

  proc =(ref d: domain, r: range(?)) {
    d = {r};
  }

  //
  // Return true if t is a tuple of ranges that is legal to assign to
  // rectangular domain d
  //
  proc chpl__isLegalRectTupDomAssign(d, t) param {
    proc isRangeTuple(a) param {
      proc peelArgs(first, rest...) param {
        return if rest.size > 1 then
                 isRange(first) && peelArgs((...rest))
               else
                 isRange(first) && isRange(rest(1));
      }
      proc peelArgs(first) param return isRange(first);

      return if !isTuple(a) then false else peelArgs((...a));
    }

    proc strideSafe(d, rt, param dim: int=1) param {
      return if dim == d.rank then
               d.dim(dim).stridable || !rt(dim).stridable
             else
               (d.dim(dim).stridable || !rt(dim).stridable) && strideSafe(d, rt, dim+1);
    }
    return isRangeTuple(t) && d.rank == t.size && strideSafe(d, t);
  }

  proc =(ref d: domain, rt: _tuple) where chpl__isLegalRectTupDomAssign(d, rt) {
    d = {(...rt)};
  }

  proc =(ref a: domain, b) {  // b is iteratable
    if isRectangularDom(a) then
      compilerError("Illegal assignment to a rectangular domain");
    a.clear();
    for ind in b {
      a.add(ind);
    }
  }

  proc chpl__serializeAssignment(a: [], b) param {
    if a.rank != 1 && isRange(b) then
      return true;

    // Sparse and Opaque arrays do not yet support parallel iteration.  We
    // could let them fall through, but then we get multiple warnings for a
    // single assignment statement which feels like overkill
    //
    if ((!isRectangularArr(a) && !isAssociativeArr(a) && !isSparseArr(a)) ||
        (isArray(b) &&
         !isRectangularArr(b) && !isAssociativeArr(b) && !isSparseArr(b))) then
      return true;
    return false;
  }

  // This must be a param function
  proc chpl__compatibleForBulkTransfer(a:[], b:[]) param {
    if a.eltType != b.eltType then return false;
    if !chpl__supportedDataTypeForBulkTransfer(a.eltType) then return false;
    if a._value.type != b._value.type then return false;
    if !a._value.dsiSupportsBulkTransfer() then return false;
    return true;
  }

  proc chpl__compatibleForBulkTransferStride(a:[], b:[]) param {
    if a.eltType != b.eltType then return false;
    if !chpl__supportedDataTypeForBulkTransfer(a.eltType) then return false;
    if !chpl__supportedDataTypeForBulkTransfer(b.eltType) then return false;
    if !a._value.dsiSupportsBulkTransferInterface() then return false;
    if !b._value.dsiSupportsBulkTransferInterface() then return false;
    return true;
  }

  // This must be a param function
  proc chpl__supportedDataTypeForBulkTransfer(type t) param {
    var x:t;
    return chpl__supportedDataTypeForBulkTransfer(x);
  }
  proc chpl__supportedDataTypeForBulkTransfer(x: string) param return false;
  proc chpl__supportedDataTypeForBulkTransfer(x: sync) param return false;
  proc chpl__supportedDataTypeForBulkTransfer(x: single) param return false;
  proc chpl__supportedDataTypeForBulkTransfer(x: domain) param return false;
  proc chpl__supportedDataTypeForBulkTransfer(x: []) param return false;
  proc chpl__supportedDataTypeForBulkTransfer(x: _distribution) param return true;
  proc chpl__supportedDataTypeForBulkTransfer(x: ?t) param where isComplexType(t) return true;
  proc chpl__supportedDataTypeForBulkTransfer(x: ?t) param where isRecordType(t) || isTupleType(t) {
    // TODO: The current implementations of isPODType and
    //       supportedDataTypeForBulkTransfer do not completely align. I'm
    //       leaving it as future work to enable bulk transfer for other types
    //       that are POD. In the long run it seems like we should be able to
    //       have only one method for supportedDataType that just calls
    //       isPODType.

    // We can bulk transfer any record or tuple that is 'Plain Old Data' ie. a
    // bag of bits
    return isPODType(t);
  }
  proc chpl__supportedDataTypeForBulkTransfer(x: ?t) param where isUnionType(t) return false;
  proc chpl__supportedDataTypeForBulkTransfer(x: object) param return false;
  proc chpl__supportedDataTypeForBulkTransfer(x) param return true;

  proc chpl__useBulkTransfer(a:[], b:[]) {
    //if debugDefaultDistBulkTransfer then writeln("chpl__useBulkTransfer");

    // constraints specific to a particular domain map array type
    if !a._value.doiCanBulkTransfer(chpl__getViewDom(a)) then return false;
    if !b._value.doiCanBulkTransfer(chpl__getViewDom(b)) then return false;
    if !a._value.doiUseBulkTransfer(b) then return false;

    return true;
  }

  //NOTE: This function also checks for equal lengths in all dimensions,
  //as the previous one (chpl__useBulkTransfer) so depending on the order they
  //are called, this can be factored out.
  proc chpl__useBulkTransferStride(a:[], b:[]) {
    //if debugDefaultDistBulkTransfer then writeln("chpl__useBulkTransferStride");

    // constraints specific to a particular domain map array type
    if !a._value.doiCanBulkTransferStride(chpl__getViewDom(a)) then return false;
    if !b._value.doiCanBulkTransferStride(chpl__getViewDom(b)) then return false;
    if !a._value.doiUseBulkTransferStride(b) then return false;

    return true;
  }

  inline proc chpl__bulkTransferHelper(a, b) {
    if a._value.isDefaultRectangular() {
      if b._value.isDefaultRectangular() {
        // implemented in DefaultRectangular
        a._value.doiBulkTransferStride(b, chpl__getViewDom(a));
      }
      else
        // b's domain map must implement this
        b._value.doiBulkTransferToDR(a, chpl__getViewDom(b));
    } else {
      if b._value.isDefaultRectangular() then
        // a's domain map must implement this
        a._value.doiBulkTransferFromDR(b, chpl__getViewDom(a));
      else
        // a's domain map must implement this,
        // possibly using b._value.doiBulkTransferToDR()
        a._value.doiBulkTransferFrom(b, chpl__getViewDom(a));
    }
 }

  pragma "no doc"
  proc checkArrayShapesUponAssignment(a: [], b: []) {
    if isRectangularArr(a) && isRectangularArr(b) {
      const aDims = a._value.dom.dsiDims(),
            bDims = b._value.dom.dsiDims();
      compilerAssert(aDims.size == bDims.size);
      for param i in 1..aDims.size {
        if aDims(i).length != bDims(i).length then
          halt("assigning between arrays of different shapes in dimension ",
               i, ": ", aDims(i).length, " vs. ", bDims(i).length);
      }
    } else {
      // may not have dsiDims(), so can't check them as above
      // todo: compilerError if one is rectangular and the other isn't?
    }
  }

  inline proc =(ref a: [], b:[]) {
    if a.rank != b.rank then
      compilerError("rank mismatch in array assignment");

    if b._value == nil then
      // This happens e.g. for 'new' on a record with an array field whose
      // default initializer is a forall expr. E.g. arrayInClassRecord.chpl.
      return;

    if a._value == b._value {
      // Do nothing for A = A but we could generate a warning here
      // since it is probably unintended. We need this check here in order
      // to avoid memcpy(x,x) which happens inside doiBulkTransfer.
      return;
    }

    if a.size == 0 && b.size == 0 then
      // Do nothing for zero-length assignments
      return;

    if boundsChecking then
      checkArrayShapesUponAssignment(a, b);

    // try bulk transfer
    if !chpl__serializeAssignment(a, b) then
      // Do bulk transfer.
      chpl__bulkTransferArray(a, b);
    else
      // Do non-bulk transfer.
      chpl__transferArray(a, b);
  }

  inline proc chpl__bulkTransferArray(ref a: [], const ref b) {
    if (useBulkTransfer &&
        chpl__compatibleForBulkTransfer(a, b) &&
        chpl__useBulkTransfer(a, b))
    {
      a._value.doiBulkTransfer(b, chpl__getViewDom(a));
    }
    else if (useBulkTransferStride &&
        chpl__compatibleForBulkTransferStride(a, b) &&
        chpl__useBulkTransferStride(a, b))
    {
      chpl__bulkTransferHelper(a, b);
    }
    else {
      if debugBulkTransfer {
        chpl_debug_writeln("proc =(a:[],b): bulk transfer did not happen");
      }
      chpl__transferArray(a, b);
    }
  }

  inline proc chpl__transferArray(ref a: [], const ref b) {
    if (a.eltType == b.type ||
        _isPrimitiveType(a.eltType) && _isPrimitiveType(b.type)) {
      forall aa in a do
        aa = b;
    } else if chpl__serializeAssignment(a, b) {
// commenting this out to remove testing noise.
// this is always printed out if it's on, because chpl__transferArray
// is now called from array auto-copy.
//      compilerWarning("whole array assignment has been serialized (see note in $CHPL_HOME/STATUS)");
      for (aa,bb) in zip(a,b) do
        aa = bb;
    } else if chpl__tryToken { // try to parallelize using leader and follower iterators
      forall (aa,bb) in zip(a,b) do
        aa = bb;
    } else {
      for (aa,bb) in zip(a,b) do
        aa = bb;
    }
  }

  // assigning from a param
  inline proc chpl__transferArray(a: [], param b) {
    forall aa in a do
      aa = b;
  }

  inline proc =(ref a: [], b:domain) {
    if a.rank != b.rank then
      compilerError("rank mismatch in array assignment");
    chpl__transferArray(a, b);
  }

  inline proc =(ref a: [], b) /* b is not an array nor a domain nor a tuple */ {
    chpl__transferArray(a, b);
  }

/* Does not work: compiler expects assignments to have 2 formals,
   whereas the below becomes a 1-argument function after resolution.
  inline proc =(ref a: [], param b) {
    chpl__transferArray(a, b);
  }
*/

  inline proc =(ref a: [], b: _tuple) where isEnumArr(a) {
    if b.size != a.numElements then
      halt("tuple array initializer size mismatch");
    for (i,j) in zip(chpl_enumerate(index(a.domain)), 1..) {
      a(i) = b(j);
    }
  }

  proc =(ref a: [], b: _tuple) where isRectangularArr(a) {
    proc chpl__tupleInit(j, param rank: int, b: _tuple) {
      type idxType = a.domain.idxType,
           strType = chpl__signedType(idxType);

      const stride = a.domain.dim(a.rank-rank+1).stride,
            start = a.domain.dim(a.rank-rank+1).first;

      if rank == 1 {
        for param i in 1..b.size {
          j(a.rank-rank+1) = (start:strType + ((i-1)*stride)): idxType;
          a(j) = b(i);
        }
      } else {
        for param i in 1..b.size {
          j(a.rank-rank+1) = (start:strType + ((i-1)*stride)): idxType;
          chpl__tupleInit(j, rank-1, b(i));
        }
      }
    }
    var j: a.rank*a.domain.idxType;
    chpl__tupleInit(j, a.rank, b);
  }

  proc _desync(type t) type where isSyncType(t) || isSingleType(t) {
    var x: t;
    return x.valType;
  }

  proc _desync(type t) type {
    return t;
  }

  proc =(ref a: [], b: _desync(a.eltType)) {
    forall e in a do
      e = b;
  }

  /*
   * The following procedure is effectively equivalent to:
   *
  inline proc chpl_by(a:domain, b) { ... }
   *
   * because the parser renames the routine since 'by' is a keyword.
   */
  proc by(a: domain, b) {
    var r: a.rank*range(a._value.idxType,
                      BoundedRangeType.bounded,
                      true);
    var t = _makeIndexTuple(a.rank, b, expand=true);
    for param i in 1..a.rank do
      r(i) = a.dim(i) by t(i);
    var d = a._value.dsiBuildRectangularDom(a.rank, a._value.idxType, true, r);
    if d.linksDistribution() then
      d.dist.add_dom(d);
    return _newDomain(d);
  }

  /*
   * The following procedure is effectively equivalent to:
   *
  inline proc chpl_align(a:domain, b) { ... }
   *
   * because the parser renames the routine since 'align' is a keyword.
   */
  proc align(a: domain, b) {
    var r: a.rank*range(a._value.idxType,
                      BoundedRangeType.bounded,
                      a.stridable);
    var t = _makeIndexTuple(a.rank, b, expand=true);
    for param i in 1..a.rank do
      r(i) = a.dim(i) align t(i);
    var d = a._value.dsiBuildRectangularDom(a.rank, a._value.idxType, a.stridable, r);
    if d.linksDistribution() then
      d.dist.add_dom(d);
    return _newDomain(d);
  }

  //
  // index for all opaque domains
  //
  pragma "no doc"
  record _OpaqueIndex {
    var node:int = 0;
    var i:uint = 0;
  }
  pragma "no doc"
  pragma "locale private"
  var _OpaqueIndexNext: atomic uint;

  //
  // Swap operator for arrays
  //
  inline proc <=>(x: [], y: []) {
    forall (a,b) in zip(x, y) do
      a <=> b;
  }

  /* Returns a copy of the array ``A`` containing the same values but
     in the shape of the domain ``D``. The number of indices in the
     domain must equal the number of elements in the array. The
     elements of ``A`` are copied into the new array using the
     default iteration orders over ``D`` and ``A``.  */
  proc reshape(A: [], D: domain) {
    if !isRectangularDom(D) then
      compilerError("reshape(A,D) is meaningful only when D is a rectangular domain; got D: ", D.type:string);
    if A.size != D.size then
      halt("reshape(A,D) is invoked when A has ", A.size,
           " elements, but D has ", D.size, " indices");
    var B: [D] A.eltType;
    for (i,a) in zip(D,A) do
      B(i) = a;
    return B;
  }

  pragma "no doc"
  iter linearize(Xs) {
    for x in Xs do yield x;
  }

  pragma "init copy fn"
  proc chpl__initCopy(a: _distribution) {
    pragma "no copy" var b = a.clone();
    return b;
    // You'd think we could just write
    //   return a.clone();
    // but that makes an infinite loop.
  }

  pragma "init copy fn"
  proc chpl__initCopy(const ref a: domain) {
    var b: a.type;
    if isRectangularDom(a) && isRectangularDom(b) {
      b.setIndices(a.getIndices());
    } else {
      // TODO : update to use forall loop
      for i in a do
        b.add(i);
    }
    return b;
  }

  pragma "auto copy fn" proc chpl__autoCopy(const ref x: domain) {
    pragma "no copy" var b = chpl__initCopy(x);
    return b;
  }

  // This implementation of arrays and domains can create aliases
  // of domains and arrays. Additionally, array aliases are possible
  // in the language with the => operator.
  //
  // A call to the chpl__unalias function is added by the compiler when a user
  // variable is initialized from an expression that would normally not require
  // a copy.
  //
  // For example, if we have
  //   var A:[1..10] int;
  //   var B = A[1..3];
  // then B is initialized with a slice of A. But since B is a new
  // variable, it needs to be a new 3-element array with distinct storage.
  // Since the slice is implemented as a function call, without chpl__unalias,
  // B would just be initialized to the result of the function call -
  // meaning that B would not refer to distinct array elements.
  pragma "unalias fn"
  inline proc chpl__unalias(x: domain) {
    if x._unowned {
      // We could add an autoDestroy here, but it wouldn't do anything for
      // an unowned domain.
      pragma "no auto destroy" var ret = x;
      return ret;
    } else {
      pragma "no copy" var ret = x;
      return ret;
    }
  }

  pragma "init copy fn"
  proc chpl__initCopy(const ref a: []) {
    var b : [a._dom] a.eltType;

    // Try bulk transfer.
    if !chpl__serializeAssignment(b, a) {
      chpl__bulkTransferArray(b, a);
      return b;
    }

    chpl__transferArray(b, a);
    return b;
  }

  pragma "auto copy fn" proc chpl__autoCopy(const ref x: []) {
    pragma "no copy" var b = chpl__initCopy(x);
    return b;
  }

  // Used to implement the copy-out language semantics
  // Relies on the return types being different to detect an ArrayView at
  // compile-time
  pragma "no copy return"
  inline proc chpl__unref(x: []) where chpl__isArrayView(x._value) {
    // intended to call initCopy
    pragma "no auto destroy" var ret = x;
    return ret;
  }

  // Intended to return whatever it gets without copying
  pragma "no copy return"
  inline proc chpl__unref(x: []) {
    pragma "no copy" var ret = x;
    return ret;
  }


  // see comment on chpl__unalias for domains
  pragma "unalias fn"
  inline proc chpl__unalias(x: []) {
    param isview = (x._value.isSliceArrayView() ||
                    x._value.isRankChangeArrayView() ||
                    x._value.isReindexArrayView());
    const isalias = x._unowned;

    if isview || isalias {
      // Intended to call chpl__initCopy
      pragma "no auto destroy" var ret = x;
      // Since chpl__unalias replaces a initCopy(auto/initCopy()) the
      // inner value needs to be auto-destroyed.
      // TODO: Should this be inserted by the compiler?
      chpl__autoDestroy(x);
      return ret;
    } else {
      // Just return a bit-copy/shallow-copy of 'x'
      pragma "no copy" var ret = x;
      return ret;
    }
  }

  //
  // Noakes 2015/11/05
  //
  // This function is invoked to implement for expressions and
  // forall expressions. An iterator is invoked that generates
  // the elements of the resulting array.
  //
  // Although it appears to be a copy constructor, it is in fact
  // an Array constructor.  It appears to me that this implementation
  // it due to an artifact in the interaction between normalize and
  // function resolution; the former inserts calls to initCopy() without
  // understanding the types involved.  This in turn leads to some
  // confusion for the compiler is resolved by the liberal use of
  // pragmas.
  //

  pragma "init copy fn"
  proc chpl__initCopy(ir: _iteratorRecord) {

    // The use of an explicit initCopy() is required
    // to support nested for/forall expressions.
    iter _ir_copy_recursive(ir) {
      for e in ir {
        pragma "no copy"
        var ee = chpl__initCopy(e);

        yield ee;
      }
    }

    pragma "no copy"
    var irc  = _ir_copy_recursive(ir);

    var i    = 1;
    var size = 4;

    pragma "insert auto destroy"
    var D    = {1..size};

    // note that _getIterator is called in order to copy the iterator
    // class since for arrays we need to iterate once to get the
    // element type (at least for now); this also means that if this
    // iterator has side effects, we will see them; a better way to
    // handle this may be to get the static type (not initialize the
    // array) and use a primitive to set the array's element; that may
    // also handle skyline arrays
    var A: [D] iteratorIndexType(irc);

    for e in irc {
      // The resulting array grows dynamically
      if i > size {
        size = 2 * size;
        D    = { 1 .. size };
      }

      A(i) = e;
      i    = i + 1;
    }

    D = { 1 .. i - 1 };

    return A;
  }

  /* ================================================
     Set Operations on Associative Domains and Arrays
     ================================================

     Associative domains and arrays support a number of operators for
     set manipulations.

   */
}
