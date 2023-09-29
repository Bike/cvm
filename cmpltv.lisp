(defpackage #:cvm.compile-file
  (:use #:cl)
  (:local-nicknames (#:cmp #:cvm.compile))
  (:shadow #:compile-file #:macroexpand-1 #:macroexpand)
  (:export #:with-constants
           #:ensure-constant #:add-constant #:find-constant-index)
  (:export #:instruction #:creator #:vcreator #:effect)
  (:export #:write-bytecode #:encode)
  (:export #:compile-stream #:compile-file)
  ;; introspection
  (:export #:load-bytecode-stream #:load-bytecode)
  (:export #:write-fasl #:save-fasl)
  (:export #:concatenate-fasls #:concatenate-fasl-files))

(in-package #:cvm.compile-file)

;;; For this first version, I'm going to track permanency but not do anything
;;; with it - cutting out transients can be later, since I think it will need
;;; more coordination with the compiler.

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Debugging
;;;

(defvar *debug-compiler* nil)

(defmacro dbgprint (message &rest args)
  `(when *debug-compiler*
     (let ((*print-level* 2) (*print-length* 1) (*print-circle* t))
       (format *error-output* ,(concatenate 'string "~&; " message "~%")
               ,@args))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Initial processing level: Reflects only the necessary recursion
;;; structure, not necessarily the eventual underlying representation.
;;; We collect a sequence of specialized "instructions" that, when executed,
;;; will create and initialize the LTV table.

(defclass instruction () ())
;;; An instruction that allocates or otherwise creates an object.
;;; The object may be fully initialized or may require further initialization.
(defclass creator (instruction)
  (;; T if the object outlasts loading (e.g. is referred to directly in code)
   ;; otherwise NIL
   (%permanency :initform nil :accessor permanency :type boolean)
   (%index :initform nil :initarg :index :accessor index
           :type (or null (integer 0)))))
;;; A creator for which a prototype value (which the eventual LTV will be
;;; similar to) is available.
(defclass vcreator (creator)
  ((%prototype :initarg :prototype :reader prototype)))

(defmethod print-object ((object creator) stream)
  (print-unreadable-object (object stream :type t)
    (format stream "~a ~d"
            (if (permanency object) :permanent :transient)
            (index object))))

(defmethod print-object ((object vcreator) stream)
  (print-unreadable-object (object stream :type t)
    (if (slot-boundp object '%prototype)
        (prin1 (prototype object) stream)
        (write-string "[no prototype]" stream))
    (format stream " ~a ~d"
            (if (permanency object) :permanent :transient)
            (index object))))

;;; An instruction that performs some action for effect. This can include
;;; initialization as well as arbitrary side effects (as from make-load-form).
(defclass effect (instruction) ())

(defun permanentize (creator) (setf (permanency creator) t) creator)

;;;

;;; TODO: Abbreviate with list/dotted list, but make sure
;;; coalescence is still really possible.
(defclass cons-creator (vcreator) ())

(defclass rplaca-init (effect)
  ((%cons :initarg :cons :reader rplac-cons :type cons-creator)
   (%value :initarg :value :reader rplac-value :type creator)))

(defclass rplacd-init (effect)
  ((%cons :initarg :cons :reader rplac-cons :type cons-creator)
   (%value :initarg :value :reader rplac-value :type creator)))

;;; dimensions and element-type are encoded with the array since
;;; they shouldn't really need to be coalesced.
(defclass array-creator (vcreator)
  ((%dimensions :initarg :dimensions :reader dimensions)
   (%packing-info :initarg :packing-info :reader packing-info)
   (%uaet-code :initarg :uaet-code :reader uaet-code)))

;; row-major.
(defclass setf-aref (effect)
  ((%array :initarg :array :reader setf-aref-array :type array-creator)
   (%index :initarg :index :reader setf-aref-index :type (integer 0))
   (%value :initarg :value :reader setf-aref-value :type creator)))

(defclass hash-table-creator (vcreator)
  (;; used in disltv
   (%test :initarg :test :reader hash-table-creator-test :type symbol)
   (%count :initarg :count :reader hash-table-creator-count
           :type (integer 0))))

(defclass setf-gethash (effect)
  ((%hash-table :initarg :hash-table :reader setf-gethash-hash-table
                :type hash-table-creator)
   (%key :initarg :key :reader setf-gethash-key :type creator)
   (%value :initarg :value :reader setf-gethash-value :type creator)))

(defclass symbol-creator (vcreator)
  (;; Is there actually a point to trying to coalesce symbol names?
   (%name :initarg :name :reader symbol-creator-name :type creator)))

(defclass interned-symbol-creator (symbol-creator)
  ((%package :initarg :package :reader symbol-creator-package :type creator)))

(defclass package-creator (vcreator)
  (;; Is there actually a point to trying to coalesce package names?
   ;; Also, some symbols (CL, KEYWORD) could probably be dumped without
   ;; a general package reference.
   (%name :initarg :name :reader package-creator-name :type creator)))

(defclass number-creator (vcreator) ())
(defclass sb64-creator (number-creator) ())
(defclass bignum-creator (number-creator) ())
(defclass ratio-creator (number-creator)
  ((%numerator :initarg :numerator :reader ratio-creator-numerator
               :type creator)
   (%denominator :initarg :denominator :reader ratio-creator-denominator
                 :type creator)))
(defclass complex-creator (number-creator)
  ((%realpart :initarg :realpart :reader complex-creator-realpart
              :type creator)
   (%imagpart :initarg :imagpart :reader complex-creator-imagpart
              :type creator)))
(defclass single-float-creator (number-creator) ())
(defclass double-float-creator (number-creator) ())

(defclass character-creator (vcreator) ())

;;; FIXME: Trying to coalesce all this stuff might be pointless.
;;; But maybe not - lots of stuff probably shares a type, I guess.
(defclass pathname-creator (vcreator)
  ((%host :initarg :host :reader pathname-creator-host :type creator)
   (%device :initarg :device :reader pathname-creator-device :type creator)
   (%directory :initarg :directory :reader pathname-creator-directory
               :type creator)
   (%name :initarg :name :reader pathname-creator-name :type creator)
   (%type :initarg :type :reader pathname-creator-type :type creator)
   (%version :initarg :version :reader pathname-creator-version :type creator)))

(defclass fdefinition-lookup (creator)
  ((%name :initarg :name :reader name :type creator)))

;;; Look up the "cell" for a function binding - something that the VM's
;;; FDEFINITION instruction can get an actual function out of.
;;; The nature of this cell is implementation-dependent.
;;; In a simple implementation, the "cell" can just be the function name,
;;; and the FDEFINITION instruction just does CL:FDEFINITION.
(defclass fcell-lookup (creator)
  ((%name :initarg :name :reader name :type creator)))

;;; Look up the "cell" for special variable binding. This is used by the
;;; SPECIAL-BIND, SYMBOL-VALUE, and SYMBOL-VALUE-SET VM instructions
;;; as a lookup key for the binding, as well as for establishing new
;;; local bindings.
;;; The nature of this cell is implementation-dependent.
;;; In a simple implementation, the "cell" can just be the symbol itself,
;;; and the SYMBOL-VALUE instruction just does CL:SYMBOL-VALUE, etc.
(defclass vcell-lookup (creator)
  ((%name :initarg :name :reader name :type creator)))

(defclass general-creator (vcreator)
  (;; Reference to a function designator to call to allocate the object,
   ;; e.g. a function made of the first return value from make-load-form.
   ;; The function returns the new value as its primary.
   ;; Other values are ignored.
   ;; FIXME: Maybe should be a definite function, but this would require
   ;; an FDEFINITION instruction.
   (%function :initarg :function :reader general-function
              :type creator)
   ;; List of arguments (creators) to be passed to the function.
   (%arguments :initarg :arguments :reader general-arguments :type list)))

(defclass general-initializer (effect)
  (;; Reference to a function designator to call to initialize the object,
   ;; e.g. a function made of the second return value from make-load-form.
   ;; The function's return values are ignored.
   (%function :initarg :function :reader general-function
              :type creator)
   ;; List of arguments (creators) to be passed to the function.
   (%arguments :initarg :arguments :reader general-arguments :type list)))

;;; Created from certain make-load-form results.
(defclass class-creator (vcreator)
  ((%name :initarg :name :reader class-creator-name)))

(defclass singleton-creator (vcreator) ())

(defclass load-time-value-creator (creator)
  (;; Reference to a function to call to evaluate the load form.
   ;; It's called with no arguments and returns the value.
   (%function :initarg :function :reader load-time-value-creator-function
              :type creator)
   ;; Boolean indicating whether the LTV is read-only. Unused for now.
   (%read-only-p :initarg :read-only-p :type boolean
                 :reader load-time-value-creator-read-only-p)
   ;; The original form, for debugging/display
   (%form :initarg :form :reader load-time-value-creator-form)
   ;; The info object, for similarity checking
   (%info :initarg :info :reader load-time-value-creator-info)
   ;; If something's referenced directly from load-time-value, it's permanent.
   (%permanency :initform t)))

(defclass init-object-array (instruction)
  ((%count :initarg :count :reader init-object-array-count)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Attributes are bonus, possibly implementation-defined stuff also in the file.
;;; Based closely on Java attributes, the loader has to ignore any it doesn't
;;; understand, so it's verboten for attributes to do anything semantically
;;; important in general. And, attributes include inline information about their
;;; size, so they can be skipped if not understood.
;;; Unlike Java attributes, our attributes are instructions in the normal
;;; sequence. This is so that, for example, functions can be annotated with
;;; source or other debug information before they are called.

(defclass attribute (effect)
  (;; Creator for the name of the attribute, a string.
   ;; FIXME: Do this more cleanly.
   (%name :reader name :type creator)))

#+clasp
(defclass spi-attr (attribute)
  ((%name :initarg :name
          :initform (ensure-constant "clasp:source-pos-info"))
   (%function :initarg :function :reader spi-attr-function :type creator)
   (%pathname :initarg :pathname :reader spi-attr-pathname :type creator)
   (%lineno :initarg :lineno :reader lineno :type (unsigned-byte 64))
   (%column :initarg :column :reader column :type (unsigned-byte 64))
   (%filepos :initarg :filepos :reader filepos :type (unsigned-byte 64))))

;;;

;;; Return true iff the value is similar to the existing creator.
(defgeneric similarp (creator value)
  (:method (creator value) (declare (ignore creator value)) nil))

(defmethod similarp ((creator vcreator) value)
  (eql (prototype creator) value))

(defmethod similarp ((creator load-time-value-creator) ltvi)
  (eql (load-time-value-creator-info creator) ltvi))

;;; EQL hash table from objects to creators.
(defvar *coalesce*)

;;; Another EQL hash table for out-of-band objects that are also "coalesced".
;;; So far this means cfunctions, modules, fcells, and vcells.
;;; This a separate variable because perverse code could use an out-of-band
;;; object in band (e.g. compiling a literal module) and we don't want to
;;; confuse those things.
(defvar *oob-coalesce*)

;;; For function cells. EQUAL since function names can be lists.
(defvar *fcell-coalesce*)
;;; And variable cells.
(defvar *vcell-coalesce*)

;; Look up a value in the existing instructions.
;; On success returns the creator, otherwise NIL.
;; Could be extended with coalescence relations or made more efficient,
;; for example by multiple tables discriminated by type.
(defun %find-constant (value)
  (values (gethash value *coalesce*))
  #+(or)
  (find-if (lambda (c) (and (typep c 'creator) (similarp c value)))
           sequence))

(defun find-oob (value)
  (values (gethash value *oob-coalesce*)))

(defun find-fcell (name) (values (gethash name *fcell-coalesce*)))
(defun find-vcell (name) (values (gethash name *vcell-coalesce*)))

;;; List of instructions to be executed by the loader.
;;; In reverse.
(defvar *instructions*)

;;; Stack of objects we are in the middle of computing creation forms for.
;;; This is used to detect circular dependencies.
;;; We only do this for MAKE-LOAD-FORM because we assume our own
;;; computations never recurse inappropriately. If they do, it's a bug,
;;; rather than the user's problem.
(defvar *creating*)

(defmacro with-constants ((&key) &body body)
  `(let ((*instructions* nil) (*creating* nil)
         (*coalesce* (make-hash-table))
         (*oob-coalesce* (make-hash-table))
         (*fcell-coalesce* (make-hash-table :test #'equal))
         (*vcell-coalesce* (make-hash-table)))
     ,@body))

(defun find-constant (value)
  (%find-constant value #+(or) *instructions*))

(defun find-constant-index (value)
  (let ((creator (%find-constant value)))
    (if creator
        (index creator)
        nil)))

(defun add-instruction (instruction)
  (push instruction *instructions*)
  instruction)

(defun add-creator (value instruction)
  (setf (gethash value *coalesce*) instruction)
  (add-instruction instruction))

(defun add-oob (key instruction)
  (setf (gethash key *oob-coalesce*) instruction)
  (add-instruction instruction))

(defun add-fcell (key instruction)
  (setf (gethash key *fcell-coalesce*) instruction)
  (add-instruction instruction))

(defun add-vcell (key instruction)
  (setf (gethash key *vcell-coalesce*) instruction)
  (add-instruction instruction))

(defgeneric add-constant (value))

(defun ensure-constant (value &key permanent)
  (let ((creator (or (find-constant value) (add-constant value))))
    (when permanent (permanentize creator))
    creator))

;;; Given a form, get a constant handle to a function that at load time will
;;; have the effect of evaluating the form in a null lexical environment.
(defun add-form (form &optional env)
  ;; PROGN so that (declare ...) expressions for example correctly cause errors.
  (add-function (bytecode-cf-compile-lexpr `(lambda () (progn ,form)) env)))

(defmethod add-constant ((value cons))
  (let ((cons (add-creator
               value (make-instance 'cons-creator :prototype value))))
    (add-instruction (make-instance 'rplaca-init
                       :cons cons :value (ensure-constant (car value))))
    (add-instruction (make-instance 'rplacd-init
                       :cons cons :value (ensure-constant (cdr value))))
    cons))

(defmethod add-constant ((value array))
  (let* ((uaet (array-element-type value))
         (info (array-packing-info value))
         (info-type (first info))
         (uaet-code (find-uaet-code uaet))
         (arr (add-creator
               value
               (make-instance 'array-creator
                 :prototype value :dimensions (array-dimensions value)
                 :packing-info info :uaet-code uaet-code))))
    (when (eq info-type t) ; general - dump setf-arefs for elements.
      ;; (we have to separate initialization here in case the array
      ;;  contains itself. packed arrays can't contain themselves)
      (loop for i below (array-total-size value)
            do (add-instruction
                (make-instance 'setf-aref
                  :array arr :index i
                  :value (ensure-constant (row-major-aref value i))))))
    arr))

(defmethod add-constant ((value hash-table))
  (let ((ht (add-creator
             value
             (make-instance 'hash-table-creator :prototype value
                            :test (hash-table-test value)
                            :count (hash-table-count value)))))
    (maphash (lambda (k v)
               (add-instruction
                (make-instance 'setf-gethash
                  :hash-table ht
                  :key (ensure-constant k) :value (ensure-constant v))))
             value)
    ht))

(defmethod add-constant ((value symbol))
  (add-creator
   value
   (let ((package (symbol-package value)))
     (if package
         (make-instance 'interned-symbol-creator
           :prototype value
           :name (ensure-constant (symbol-name value))
           :package (ensure-constant package))
         (make-instance 'symbol-creator
           :prototype value
           :name (ensure-constant (symbol-name value)))))))

(defmethod add-constant ((value (eql nil)))
  (add-creator value (make-instance 'singleton-creator :prototype value)))
(defmethod add-constant ((value (eql t)))
  (add-creator value (make-instance 'singleton-creator :prototype value)))

(defmethod add-constant ((value package))
  (add-creator value
               (make-instance 'package-creator
                 :prototype value
                 :name (ensure-constant (package-name value)))))

(defmethod add-constant ((value integer))
  (add-creator
   value
   (etypecase value
     ;; TODO? Could have different opcodes for smaller integers.
     ((signed-byte 64) (make-instance 'sb64-creator :prototype value))
     (integer (make-instance 'bignum-creator :prototype value)))))

(defmethod add-constant ((value float))
  (add-creator
   value
   (etypecase value
     (double-float (make-instance 'double-float-creator :prototype value))
     (single-float (make-instance 'single-float-creator :prototype value)))))

(defmethod add-constant ((value ratio))
  ;; In most cases it's probably pointless to try to coalesce the numerator
  ;; and denominator. It would probably be smarter to have a small ratio
  ;; where the number is embedded versus a large ratio where they're indirect.
  (add-creator
   value
   (make-instance 'ratio-creator :prototype value
                  :numerator (ensure-constant (numerator value))
                  :denominator (ensure-constant (denominator value)))))

(defmethod add-constant ((value complex))
  ;; Similar considerations to ratios here.
  (add-creator
   value
   (make-instance 'complex-creator :prototype value
                  :realpart (ensure-constant (realpart value))
                  :imagpart (ensure-constant (imagpart value)))))

(defmethod add-constant ((value character))
  (add-creator value (make-instance 'character-creator :prototype value)))

(defmethod add-constant ((value pathname))
  (add-creator
   value
   (make-instance 'pathname-creator
     :prototype value
     :host (ensure-constant (pathname-host value))
     :device (ensure-constant (pathname-device value))
     :directory (ensure-constant (pathname-directory value))
     :name (ensure-constant (pathname-name value))
     :type (ensure-constant (pathname-type value))
     :version (ensure-constant (pathname-version value)))))

(define-condition circular-dependency (error)
  ((%path :initarg :path :reader path))
  (:report (lambda (condition stream)
             (format stream "~s circular dependency detected:~%~t~{~s~^ ~}"
                     'make-load-form (path condition)))))

(defconstant +max-call-args+ (ash 1 16))

(defun function-form-p (form)
  (and (consp form) (eq (car form) 'cl:function)
       (consp (cdr form)) (null (cddr form))))

(defun lambda-expression-p (form)
  (and (consp form) (eq (car form) 'cl:lambda)))

;;; Return true iff the proper list FORM represents a call to a global
;;; function with all constant or #' arguments (and not too many).
(defun call-with-dumpable-arguments-p (form &optional env)
  (declare (ignorable env))
  (and (symbolp (car form))
       (fboundp (car form))
       (not (macro-function (car form)))
       (not (special-operator-p (car form)))
       (< (length (rest form)) +max-call-args+)
       (every (lambda (f) (or (constantp f #+(or) env)
                              (function-form-p f)
                              (lambda-expression-p f)))
              (rest form))))

(defun f-dumpable-form-creator (env)
  (lambda (form)
    (cond ((lambda-expression-p form)
           (add-function (bytecode-cf-compile-lexpr form env)))
          ((not (function-form-p form)) ; must be a constant
           (ensure-constant (eval form)
                            #+(or)(ext:constant-form-value form env)))
          ((and (consp (second form)) (eq (caadr form) 'cl:lambda))
           ;; #'(lambda ...)
           (add-function (bytecode-cf-compile-lexpr (second form) env)))
          (t
           ;; #'function-name
           (add-instruction
            (make-instance 'fdefinition-lookup
              :name (ensure-constant (second form))))))))

;; from cleavir
(defun proper-list-p (object)
  (typecase object
    (null t)
    (cons (let ((slow object)
                (fast (cdr object)))
            (declare (type cons slow))
            (tagbody
             again
               (unless (consp fast)
                 (return-from proper-list-p
                   (if (null fast) t nil)))
               (when (eq fast slow)
                 (return-from proper-list-p nil))
               (setq fast (cdr fast))
               (unless (consp fast)
                 (return-from proper-list-p
                   (if (null fast) t nil)))
               (setq fast (cdr fast))
               (setq slow (cdr slow))
               (go again))))
    (t nil)))

;;; Make a possibly-special creator based on an MLF creation form.
(defun creation-form-creator (value form &optional env)
  (let ((*creating* (cons value *creating*)))
    (flet ((default ()
             (make-instance 'general-creator
               :prototype value
               :function (add-form form env) :arguments ())))
      (cond ((not (proper-list-p form)) (default))
            ;; (find-class 'something)
            ((and (eq (car form) 'cl:find-class)
                  (= (length form) 2)
                  (constantp (second form) #+(or)env))
             (make-instance 'class-creator
               :prototype value
               :name (ensure-constant
                      (eval (second form))
                      #+(or)(ext:constant-form-value (second form) env))))
            ;; (foo 'bar 'baz)
            ((call-with-dumpable-arguments-p form)
             (make-instance 'general-creator
               :prototype value
               :function (add-instruction
                          (make-instance 'fdefinition-lookup
                            :name (ensure-constant (car form))))
               :arguments (mapcar (f-dumpable-form-creator env) (rest form))))
            (t (default))))))

;;; Make a possibly-special initializer.
(defun add-initializer-form (form &optional env)
  (flet ((default ()
           (add-instruction
            (make-instance 'general-initializer
              :function (add-form form env) :arguments ()))))
    (cond ((constantp form #+(or) env) nil) ; do nothing (good for e.g. defun's return)
          ((not (proper-list-p form)) (default))
          ((call-with-dumpable-arguments-p form env)
           (let ((cre (f-dumpable-form-creator env)))
             (if (eq (car form) 'cl:funcall)
                 ;; cut off the funcall - general-initializer does the call itself.
                 ;; this commonly arises from e.g. (funcall #'(setf fdefinition ...)
                 (add-instruction
                  (make-instance 'general-initializer
                    :function (funcall cre (second form))
                    :arguments (mapcar cre (cddr form))))
                 (add-instruction
                  (make-instance 'general-initializer
                    :function (add-instruction
                               (make-instance 'fdefinition-lookup
                                 :name (ensure-constant (car form))))
                    :arguments (mapcar cre (rest form)))))))
           (t (default)))))

(defmethod add-constant ((value t))
  (when (member value *creating*)
    (error 'circular-dependency :path *creating*))
  (multiple-value-bind (create initialize) (make-load-form value)
    (prog1
        (add-creator value (creation-form-creator value create))
      (add-initializer-form initialize))))

;;; Loop over the instructions, assigning indices to the creators such that
;;; the permanent objects come first. This only affects their position in the
;;; similar vector, not the order the instructions must be executed in.
;;; The instructions must be in forward order, i.e. reversed from how they're
;;; pushed in above. (FIXME: The reversal is too awkward.)
;;; This could probably be done in one pass somehow?
(defun assign-indices (instructions)
  (let ((next-index 0))
    ;; Assign permanents early in the vector.
    (map nil (lambda (inst)
               (when (and (typep inst 'creator) (permanency inst)
                          (not (index inst)))
                 (setf (index inst) next-index next-index (1+ next-index))))
         instructions)
    ;; Assign impermanents to the rest.
    (map nil (lambda (inst)
               (when (and (typep inst 'creator) (not (permanency inst))
                          (not (index inst)))
                 (setf (index inst) next-index next-index (1+ next-index))))
         instructions))
  (values))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Bytecode
;;;
;;; "bytecode" is actually a little strong. This "bytecode" consists of a
;;; sequence of "instructions" that must be executed sequentially.
;;; There's no other control flow. There is no data structure involved other
;;; than the array of constants being produced (so e.g. no operand stack).
;;; All multibyte values are big-endian. All indices are one byte, or two
;;; bytes, or etc. powers of two based on how many constants there are. E.g. if
;;; there are 200 constants indices will be one byte, but if there are 300
;;; indices will be two bytes.
;;; Instruction set is copied from Clasp for now. "sind" in the below means an
;;; index that the allocated object will be stored into. This may need some
;;; review later.
;;; Operations are as follows:
(defparameter +ops+
  '((nil 65 sind)
    (t 66 sind)
    (ratio 67)
    (complex 68)
    (cons 69 sind)
    (rplaca 70 ind1 ind2) ; (setf (car [ind1]) [ind2])
    (rplacd 71 ind1 ind2)
    (make-array 74 sind rank . dims)
    (setf-row-major-aref 75 arrayind rmindex valueind)
    (make-hash-table 76 sind test count)
    ((setf gethash) 77 htind keyind valueind)
    (make-sb64 78 sind sb64)
    (find-package 79 sind nameind)
    (make-bignum 80 sind size . words)
    (make-symbol 81)
    (intern 82 sind packageind nameind)
    (make-character 83 sind ub32)
    (make-pathname 85)
    (make-bytecode-function 87)
    (make-bytecode-module 88)
    (setf-literals 89)
    (make-single-float 90 sind ub32)
    (make-double-float 91 sind ub64)
    (funcall-create 93 sind find nargs . args)
    (funcall-initialize 94 find nargs . args)
    (fdefinition 95 find nameind)
    (fcell 96 find nameind)
    (vcell 97 vind nameind)
    (find-class 98 sind cnind)
    (init-object-array 99 ub64)        
    (attribute 255 name nbytes . data)))

;;; STREAM is a ub8 stream.
(defgeneric encode (instruction stream))

;; how many bytes are needed to represent an index?
(defvar *index-bytes*)

;;; Write an n-byte integer to a ub8 stream, big-endian.
(defun write-b (int n stream)
  ;; write-sequence is better for this, but I don't think we can really
  ;; use it without consing or touching memory generally.
  (loop for i from (* (1- n) 8) downto 0 by 8
        for byte = (ldb (byte 8 i) int)
        do (write-byte byte stream)))

(defun write-b64 (word stream) (write-b word 8 stream))
(defun write-b32 (word stream) (write-b word 4 stream))
(defun write-b16 (word stream) (write-b word 2 stream))

(defconstant +magic+ #x8d7498b1) ; randomly chosen bytes.

(defun write-magic (stream) (write-b32 +magic+ stream))

(defparameter *major-version* 0)
(defparameter *minor-version* 11)

(defun write-version (stream)
  (write-b16 *major-version* stream)
  (write-b16 *minor-version* stream))

;; Used in disltv as well.
(defun write-bytecode (instructions stream)
  (let* ((nobjs (count-if (lambda (i) (typep i 'creator)) instructions))
         ;; Next highest power of two bytes, roughly
         (*index-bytes* (ash 1 (1- (ceiling (integer-length nobjs) 8))))
         ;; 1+ for the init-object-array.
         (ninsts (1+ (length instructions))))
    (assign-indices instructions)
    (dbgprint "Instructions:~{~&~a~}" instructions)
    (write-magic stream)
    (write-version stream)
    (write-b64 ninsts stream)
    (encode (make-instance 'init-object-array :count nobjs) stream)
    (map nil (lambda (inst) (encode inst stream)) instructions)))

(defun %write-bytecode (stream)
  ;; lol efficiency with the reverse
  (write-bytecode (reverse *instructions*) stream))

(defun opcode (mnemonic)
  (let ((inst (assoc mnemonic +ops+ :test #'equal)))
    (if inst
        (second inst)
        (error "unknown mnemonic ~a" mnemonic))))

(defun write-mnemonic (mnemonic stream) (write-byte (opcode mnemonic) stream))

(defun write-index (creator stream)
  (let ((position (index creator)))
    (ecase *index-bytes*
      ((1) (write-byte position stream))
      ((2) (write-b16 position stream))
      ((4) (write-b32 position stream))
      ((8) (write-b64 position stream)))))

(defmethod encode ((inst cons-creator) stream)
  (write-mnemonic 'cons stream)
  (write-index inst stream))

(defmethod encode ((inst rplaca-init) stream)
  (write-mnemonic 'rplaca stream)
  (write-index (rplac-cons inst) stream)
  (write-index (rplac-value inst) stream))

(defmethod encode ((inst rplacd-init) stream)
  (write-mnemonic 'rplacd stream)
  (write-index (rplac-cons inst) stream)
  (write-index (rplac-value inst) stream))

(defun write-dimensions (dimensions stream)
  (let ((rank (length dimensions)))
    (unless (< rank 256)
      (error "Can't dump an array of ~d dimensions" rank))
    (write-byte rank stream))
  ;; Only two bytes for now. Might want different opcodes for larger
  ;; (or smaller?) dimensions.
  (unless (< (reduce #'* dimensions) 65536)
    (error "Can't dump an array with ~d elements" (reduce #'* dimensions)))
  (dolist (dim dimensions)
    (write-b16 dim stream)))

(defmacro write-sub-byte (array stream nbits)
  (let ((perbyte (floor 8 nbits))
        (a (gensym "ARRAY")) (s (gensym "STREAM")))
    `(let* ((,a ,array) (,s ,stream) (total-size (array-total-size ,a)))
       (multiple-value-bind (full-bytes remainder) (floor total-size 8)
         (loop for byteindex below full-bytes
               for index = (* ,perbyte byteindex)
               for byte = (logior
                           ,@(loop for i below perbyte
                                   for shift = (- 8 (* i nbits) nbits)
                                   for rma = `(row-major-aref ,a (+ index ,i))
                                   collect `(ash ,rma ,shift)))
               do (write-byte byte ,s))
         ;; write remainder
         (let* ((index (* ,nbits full-bytes))
                (byte 0))
           (loop for i below remainder
                 for shift = (- 8 (* i ,nbits) ,nbits)
                 for rma = (row-major-aref ,a (+ index i))
                 do (setf (ldb (byte ,nbits shift) byte) rma))
           (write-byte byte ,s))))))

(defmethod encode ((inst array-creator) stream)
  (write-mnemonic 'make-array stream)
  (write-index inst stream)
  (write-byte (uaet-code inst) stream)
  (let* ((packing-info (packing-info inst))
         (dims (dimensions inst))
         (packing-type (first packing-info))
         (packing-code (second packing-info)))
    (write-byte packing-code stream)
    (write-dimensions dims stream)
    (macrolet ((dump (&rest forms)
                 `(loop with arr = (prototype inst)
                        for i below (array-total-size arr)
                        for elem = (row-major-aref arr i)
                        do ,@forms)))
      (cond ((equal packing-type 'nil)) ; just need dims
            ((equal packing-type 'base-char)
             (dump (write-byte (char-code elem) stream)))
            ((equal packing-type 'character)
             ;; TODO: UTF-8
             (dump (write-b32 (char-code elem) stream)))
            ((equal packing-type 'single-float)
             (dump (write-b32 (ieee-floats:encode-float32 elem) stream)))
            ((equal packing-type 'double-float)
             (dump (write-b64 (ieee-floats:encode-float64 elem) stream)))
            ((equal packing-type '(complex single-float))
             (dump (write-b32 (ieee-floats:encode-float32 (realpart elem))
                              stream)
                   (write-b32 (ieee-floats:encode-float32 (imagpart elem))
                              stream)))
            ((equal packing-type '(complex double-float))
             (dump (write-b64 (ieee-floats:encode-float64 (realpart elem))
                              stream)
                   (write-b64 (ieee-floats:encode-float64 (imagpart elem))
                              stream)))
            ((equal packing-type 'bit)
             (write-sub-byte (prototype inst) stream 1))
            ((equal packing-type '(unsigned-byte 2))
             (write-sub-byte (prototype inst) stream 2))
            ((equal packing-type '(unsigned-byte 4))
             (write-sub-byte (prototype inst) stream 4))
            ((equal packing-type '(unsigned-byte 8))
             (write-sequence (prototype inst) stream))
            ((equal packing-type '(unsigned-byte 16))
             (dump (write-b16 elem stream)))
            ((equal packing-type '(unsigned-byte 32))
             (dump (write-b32 elem stream)))
            ((equal packing-type '(unsigned-byte 64))
             (dump (write-b64 elem stream)))
            ((equal packing-type '(signed-byte 8))
             (dump (write-byte (ldb (byte 8 0) elem) stream)))
            ((equal packing-type '(signed-byte 16))
             (dump (write-b16 elem stream)))
            ((equal packing-type '(signed-byte 32))
             (dump (write-b32 elem stream)))
            ((equal packing-type '(signed-byte 64))
             (dump (write-b64 elem stream)))
            ;; TODO: Signed bytes
            ((equal packing-type 't)) ; handled by setf-aref instructions
            (t (error "BUG: Unknown packing-type ~s" packing-type))))))

(defmethod encode ((inst setf-aref) stream)
  (write-mnemonic 'setf-row-major-aref stream)
  (write-index (setf-aref-array inst) stream)
  (write-b16 (setf-aref-index inst) stream)
  (write-index (setf-aref-value inst) stream))

;;; Arrays are encoded with two codes: One for the packing, and one
;;; for the element type. The latter is in place so that, hopefully,
;;; arrays can be dumped portably. These two codes do not necessarily
;;; coincide: for example a general (T) array full of ub8s could be
;;; encoded as ub8s but still be loaded as a general array.
;;; (This is not done right now.)
;;; FIXME: Not sure how to deal with nonportable element types, such
;;; as clasp's vec3 arrays, or sbcl's ub7 etc. For now the similarity
;;; of arrays is weaker than the language standard mandates.
;;; The portability concern is that, for example, Clasp will have
;;; array element type of ext:byte8 instead of (unsigned-byte 8). In
;;; that case we want to dump as (unsigned-byte 8) and Clasp's loader
;;; will upgrade to ext:byte8 no problem.
;;; TODO: For version 1, put more thought into these IDs.
(defvar +array-packing-infos+
  '((nil                    #b00000000)
    (base-char              #b10000000)
    (character              #b11000000)
    ;;(short-float          #b10100000) ; i.e. binary16
    (single-float           #b00100000) ; binary32
    (double-float           #b01100000) ; binary64
    ;;(long-float           #b11100000) ; binary128?
    ;;((complex short...)   #b10110000)
    ((complex single-float) #b00110000)
    ((complex double-float) #b01110000)
    ;;((complex long...)    #b11110000)
    (bit                    #b00000001) ; (2^(code-1)) bits
    ((unsigned-byte 2)      #b00000010)
    ((unsigned-byte 4)      #b00000011)
    ((unsigned-byte 8)      #b00000100)
    ((unsigned-byte 16)     #b00000101)
    ((unsigned-byte 32)     #b00000110)
    ((unsigned-byte 64)     #b00000111)
    ;;((unsigned-byte 128) ??)
    ((signed-byte 8)        #b10000100)
    ((signed-byte 16)       #b10000101)
    ((signed-byte 32)       #b10000110)
    ((signed-byte 64)       #b10000111)
    (t                      #b11111111)))

(defun %uaet-info (uaet)
  (dolist (info +array-packing-infos+)
    (when (subtypep uaet (first info))
      (return-from %uaet-info info)))
  ;; subtypep not doing so well. default to general.
  (assoc t +array-packing-infos+))

(defun find-uaet-code (uaet) (second (%uaet-info uaet)))

(defun array-packing-info (array)
  ;; TODO? As mentioned above, we could pack arrays more efficiently
  ;; than suggested by their element type. Iterating over every array
  ;; checking might be a little too slow though?
  ;; Also wouldn't work for NIL arrays, but who's dumping NIL arrays?
  (%uaet-info (array-element-type array)))

(defmethod encode ((inst hash-table-creator) stream)
  (let* ((ht (prototype inst))
         ;; TODO: Custom hash-table tests.
         ;; NOTE that for non-custom hash table tests, the standard
         ;; guarantees that hash-table-test returns a symbol.
         (testcode (ecase (hash-table-test ht)
                     ((eq) #b00)
                     ((eql) #b01)
                     ((equal) #b10)
                     ((equalp) #b11)))
         ;; For now, only allow counts up to #xffff.
         ;; Since the count is just a hint, bigger hash tables can still
         ;; be dumped okay.
         ;; efficiency NOTE: The size passed to make-hash-table really
         ;; specifies a capacity, so for example if we have an HT with 56
         ;; entries, make a 56-entry similar hash table, and start filling it
         ;; up, it might be rehashed and resized during initialization as it
         ;; reaches the rehash threshold. I am not sure how to deal with this
         ;; in a portable fashion. (we could just invert a provided rehash-size?)
         (count (max (hash-table-count ht) #xffff)))
    (write-mnemonic 'make-hash-table stream)
    (write-index inst stream)
    (write-byte testcode stream)
    (write-b16 count stream)))

(defmethod encode ((inst setf-gethash) stream)
  (write-mnemonic '(setf gethash) stream)
  (write-index (setf-gethash-hash-table inst) stream)
  (write-index (setf-gethash-key inst) stream)
  (write-index (setf-gethash-value inst) stream))

(defmethod encode ((inst singleton-creator) stream)
  (ecase (prototype inst)
    ((nil) (write-mnemonic 'nil stream))
    ((t) (write-mnemonic 't stream)))
  (write-index inst stream))

(defmethod encode ((inst symbol-creator) stream)
  (write-mnemonic 'make-symbol stream)
  (write-index inst stream)
  (write-index (symbol-creator-name inst) stream))

(defmethod encode ((inst interned-symbol-creator) stream)
  (write-mnemonic 'intern stream)
  (write-index inst stream)
  (write-index (symbol-creator-package inst) stream)
  (write-index (symbol-creator-name inst) stream))

(defmethod encode ((inst package-creator) stream)
  (write-mnemonic 'find-package stream)
  (write-index inst stream)
  (write-index (package-creator-name inst) stream))

(defmethod encode ((inst character-creator) stream)
  (write-mnemonic 'make-character stream)
  (write-index inst stream)
  (write-b32 (char-code (prototype inst)) stream))

(defmethod encode ((inst pathname-creator) stream)
  (write-mnemonic 'make-pathname stream)
  (write-index inst stream)
  (write-index (pathname-creator-host inst) stream)
  (write-index (pathname-creator-device inst) stream)
  (write-index (pathname-creator-directory inst) stream)
  (write-index (pathname-creator-name inst) stream)
  (write-index (pathname-creator-type inst) stream)
  (write-index (pathname-creator-version inst) stream))

(defmethod encode ((inst sb64-creator) stream)
  (write-mnemonic 'make-sb64 stream)
  (write-index inst stream)
  (write-b64 (prototype inst) stream))

(defmethod encode ((inst bignum-creator) stream)
  ;; uses sign-magnitude representation.
  (write-mnemonic 'make-bignum stream)
  (write-index inst stream)
  (let* ((number (prototype inst))
         (anumber (abs number))
         (nwords (ceiling (integer-length anumber) 64))
         (negp (minusp number)))
    (write-b64 (if negp (- nwords) nwords) stream)
    (loop for i from nwords above 0
          for pos = (* (1- i) 64)
          for word = (ldb (byte 64 pos) anumber)
          do (write-b64 word stream))))

(defmethod encode ((inst single-float-creator) stream)
  (write-mnemonic 'make-single-float stream)
  (write-index inst stream)
  (write-b32 (ieee-floats:encode-float32 (prototype inst)) stream))

(defmethod encode ((inst double-float-creator) stream)
  (write-mnemonic 'make-double-float stream)
  (write-index inst stream)
  (write-b64 (ieee-floats:encode-float64 (prototype inst)) stream))

(defmethod encode ((inst ratio-creator) stream)
  (write-mnemonic 'ratio stream)
  (write-index inst stream)
  (write-index (ratio-creator-numerator inst) stream)
  (write-index (ratio-creator-denominator inst) stream))

(defmethod encode ((inst complex-creator) stream)
  (write-mnemonic 'complex stream)
  (write-index inst stream)
  (write-index (complex-creator-realpart inst) stream)
  (write-index (complex-creator-imagpart inst) stream))

(defmethod encode ((inst fdefinition-lookup) stream)
  (write-mnemonic 'fdefinition stream)
  (write-index inst stream)
  (write-index (name inst) stream))

(defmethod encode ((inst fcell-lookup) stream)
  (write-mnemonic 'fcell stream)
  (write-index inst stream)
  (write-index (name inst) stream))

(defmethod encode ((inst vcell-lookup) stream)
  (write-mnemonic 'vcell stream)
  (write-index inst stream)
  (write-index (name inst) stream))

(defmethod encode ((inst general-creator) stream)
  (write-mnemonic 'funcall-create stream)
  (write-index inst stream)
  (write-index (general-function inst) stream)
  (write-b16 (length (general-arguments inst)) stream)
  (loop for arg in (general-arguments inst)
        do (write-index arg stream)))

(defmethod encode ((inst general-initializer) stream)
  (write-mnemonic 'funcall-initialize stream)
  (write-index (general-function inst) stream)
  (write-b16 (length (general-arguments inst)) stream)
  (loop for arg in (general-arguments inst)
        do (write-index arg stream)))

(defmethod encode ((inst class-creator) stream)
  (write-mnemonic 'find-class stream)
  (write-index inst stream)
  (write-index (class-creator-name inst) stream))

(defmethod encode ((inst load-time-value-creator) stream)
  (write-mnemonic 'funcall-create stream)
  (write-index inst stream)
  (write-index (load-time-value-creator-function inst) stream)
  ;; no arguments
  (write-b16 0 stream))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; File compiler
;;;   

(defun bytecode-cf-compile-lexpr (lambda-expression environment)
  (cmp:compile-into (cmp:make-cmodule) lambda-expression environment))

(defun bytecode-compile-file-form (form env)
  (add-initializer-form form env))

(defclass bytefunction-creator (creator)
  ((%cfunction :initarg :cfunction :reader cfunction)
   (%module :initarg :module :reader module)
   (%name :initarg :name :reader name :type creator)
   (%lambda-list :initarg :lambda-list :reader lambda-list :type creator)
   (%docstring :initarg :docstring :reader docstring :type creator)
   (%nlocals :initarg :nlocals :reader nlocals :type (unsigned-byte 16))
   (%nclosed :initarg :nclosed :reader nclosed :type (unsigned-byte 16))
   (%entry-point :initarg :entry-point :reader entry-point
                 :type (unsigned-byte 32))
   (%size :initarg :size :reader size :type (unsigned-byte 32))))

;;; Given a CFUNCTION, generate a creator for the eventual runtime function.
(defun add-function (value)
  (let ((inst
          (add-oob
           value
           (make-instance 'bytefunction-creator
             :cfunction value
             :module (ensure-module (cmp:cfunction-cmodule value))
             :name (ensure-constant nil #+(or) (cmp:cfunction-name value))
             :lambda-list (ensure-constant
                           nil
                           #+(or) (cmp:cfunction-lambda-list value))
             :docstring (ensure-constant nil #+(or) (cmp:cfunction-doc value))
             :nlocals (cmp:cfunction-nlocals value)
             :nclosed (length (cmp:cfunction-closed value))
             :entry-point (cmp:annotation-module-position
                           (cmp:cfunction-entry-point value))
             :size (cmp:cfunction-final-size value)))))
    #+clasp ; source info
    (let ((cspi core:*current-source-pos-info*))
      (add-instruction
       (make-instance 'spi-attr
         :function inst
         :pathname (ensure-constant
                    (core:file-scope-pathname
                     (core:file-scope
                      (core:source-pos-info-file-handle cspi))))
         :lineno (core:source-pos-info-lineno cspi)
         :column (core:source-pos-info-column cspi)
         :filepos (core:source-pos-info-filepos cspi))))
    inst))

(defmethod encode ((inst bytefunction-creator) stream)
  ;; four bytes for the entry point, two for the nlocals and nclosed,
  ;; then indices. TODO: Source info.
  (write-mnemonic 'make-bytecode-function stream)
  (write-index inst stream)
  (write-b32 (entry-point inst) stream)
  (write-b32 (size inst) stream)
  (write-b16 (nlocals inst) stream)
  (write-b16 (nclosed inst) stream)
  (write-index (module inst) stream)
  (write-index (name inst) stream)
  (write-index (lambda-list inst) stream)
  (write-index (docstring inst) stream))

(defclass bytemodule-creator (vcreator)
  ((%cmodule :initarg :cmodule :reader bytemodule-cmodule)
   (%lispcode :initform nil :initarg :lispcode :reader bytemodule-lispcode)))

(defclass setf-literals (effect)
  ((%module :initarg :module :reader setf-literals-module :type creator)
   ;; The literals are not practically coalesceable and are always a T vector,
   ;; so they're just encoded inline.
   (%literals :initarg :literals :reader setf-literals-literals
              :type simple-vector)))

(defgeneric ensure-module-literal (literal-info))

(defmethod ensure-module-literal ((info cmp:constant-info))
  (ensure-constant (cmp:constant-info-value info)))

(defun ensure-function (cfunction)
  (or (find-oob cfunction) (add-function cfunction)))

(defmethod ensure-module-literal ((info cmp:cfunction))
  (ensure-function info))

(defmethod ensure-module-literal ((info cmp:ltv-info))
  (add-instruction
   (make-instance 'load-time-value-creator
     :function (add-form (cmp:ltv-info-form info))
     :read-only-p (cmp:ltv-info-read-only-p info)
     :form (cmp:ltv-info-form info)
     :info info)))

(defun ensure-fcell (name)
  (or (find-fcell name)
      (add-fcell name
                 (make-instance 'fcell-lookup
                   :name (ensure-constant name)))))

(defmethod ensure-module-literal ((info cmp:fdefinition-info))
  (ensure-fcell (cmp:fdefinition-info-name info)))

(defun ensure-vcell (name)
  (or (find-vcell name)
      (add-vcell name
                 (make-instance 'vcell-lookup
                   :name (ensure-constant name)))))

(defmethod ensure-module-literal ((info cmp:value-cell-info))
  (ensure-vcell (cmp:value-cell-info-name info)))

(defun add-module (value)
  ;; Add the module first to prevent recursion.
  (let ((mod
          (add-oob
           value
           (make-instance 'bytemodule-creator
             :prototype value :lispcode (cmp:link value)))))
    ;; Modules can indirectly refer to themselves recursively through
    ;; cfunctions, so we need to 2stage it here.
    (add-instruction
     (make-instance 'setf-literals
       :module mod :literals (map 'simple-vector #'ensure-module-literal
                                  (cmp:cmodule-literals value))))
    mod))

(defun ensure-module (module)
  (or (find-oob module) (add-module module)))

(defmethod encode ((inst bytemodule-creator) stream)
  ;; Write instructions.
  (write-mnemonic 'make-bytecode-module stream)
  (write-index inst stream)
  (let* ((lispcode (bytemodule-lispcode inst))
         (len (length lispcode)))
    (when (> len #.(ash 1 32))
      (error "Bytecode length is ~d, too long to dump" len))
    (write-b32 len stream)
    (write-sequence lispcode stream)))

(defmethod encode ((inst setf-literals) stream)
  (write-mnemonic 'setf-literals stream)
  (write-index (setf-literals-module inst) stream)
  (let ((literals (setf-literals-literals inst)))
    (write-b16 (length literals) stream)
    (loop for creator across literals
          do (write-index creator stream))))

;;;

(defmethod encode :before ((attr attribute) stream)
  (write-mnemonic 'attribute stream)
  (write-index (name attr) stream))

#+clasp
(defmethod encode ((attr spi-attr) stream)
  ;; Write the length.
  (write-b32 (+ *index-bytes* *index-bytes* 8 8 8) stream)
  ;; And the data.
  (write-index (spi-attr-function attr) stream)
  (write-index (spi-attr-pathname attr) stream)
  (write-b64 (lineno attr) stream)
  (write-b64 (column attr) stream)
  (write-b64 (filepos attr) stream))

(defmethod encode ((init init-object-array) stream)
  (write-mnemonic 'init-object-array stream)
  (write-b64 (init-object-array-count init) stream))

;;;

(defvar *compile-time-too*)

(defun bytecode-compile-toplevel-progn (forms env)
  (dolist (form forms)
    (bytecode-compile-toplevel form env)))

(defun bytecode-compile-toplevel-eval-when (situations forms env)
  (let ((ct (or (member :compile-toplevel situations)
                (member 'cl:compile situations)))
        (lt (or (member :load-toplevel situations)
                (member 'cl:load situations)))
        (e (or (member :execute situations)
               (member 'cl:eval situations)))
        (ctt *compile-time-too*))
    ;; Following CLHS figure 3-7 pretty exactly.
    (cond ((or (and ct lt) (and lt e ctt)) ; process compile-time-too
           (let ((*compile-time-too* t))
             (bytecode-compile-toplevel-progn forms env)))
          ((or (and lt e (not ctt)) (and (not ct) lt (not e)))
           ;; process not-compile-time
           (let ((*compile-time-too* nil))
             (bytecode-compile-toplevel-progn forms env)))
          ((or (and ct (not lt)) (and (not ct) (not lt) e ctt))
           ;; evaluate
           (cmp:eval `(progn ,@forms) env))
          (t
           ;; (or (and (not ct) (not lt) e (not ctt)) (and (not ct) (not lt) (not e)))
           ;; discard
           nil))))

(defun bytecode-compile-toplevel-locally (body env)
  (multiple-value-bind (body decls) (alexandria:parse-body body)
    (let* ((new-env (cmp:add-specials (cmp:extract-specials decls) env)))
      (bytecode-compile-toplevel-progn body new-env))))

(defun bytecode-compile-toplevel-macrolet (bindings body env)
  (let ((macros nil))
    (dolist (binding bindings)
      (let* ((name (car binding)) (lambda-list (cadr binding))
             (body (cddr binding))
             (eform (ecclesia:parse-macro name lambda-list body env))
             (aenv (cmp:lexenv-for-macrolet env))
             (expander (cmp:compile eform aenv))
             (info (cmp:make-local-macro name expander)))
        (push (cons name info) macros)))
    (bytecode-compile-toplevel-locally
     body (cmp::make-lexical-environment
           env :funs (append macros (cmp:funs env))))))

(defun bytecode-compile-toplevel-symbol-macrolet (bindings body env)
  (let ((smacros
          (loop for (name expansion) in bindings
                for info = (cmp:make-symbol-macro name expansion)
                collect (cons name info))))
    (bytecode-compile-toplevel-locally
     body (cmp:make-lexical-environment
           env
           :vars (append (nreverse smacros) (cmp:vars env))))))

(defun macroexpand-1 (form &optional env)
  (typecase form
    (symbol
     (let ((info (cmp:var-info form env)))
       (if (typep info 'trucler:symbol-macro-description)
           (values (cmp:symbol-macro-expansion info form env) t)
           (values form nil))))
    ((cons symbol)
     (let ((info (cmp:fun-info (car form) env)))
       (if (typep info 'trucler:macro-description)
           (values (cmp:expand (trucler:expander info) form env) t)
           (values form nil))))
    (t (values form nil))))

(defun macroexpand (form &optional env)
  (loop with ever-expanded = nil
        do (multiple-value-bind (expansion expandedp) (macroexpand-1 form env)
             (if expandedp
                 (setf ever-expanded t form expansion)
                 (return (values form ever-expanded))))))

(defun bytecode-compile-toplevel (form &optional env)
  (let ((form (macroexpand form env)))
    (if (consp form)
        (case (car form)
          ((progn) (bytecode-compile-toplevel-progn (cdr form) env))
          ((eval-when)
           (bytecode-compile-toplevel-eval-when (cadr form) (cddr form) env))
          ((locally) (bytecode-compile-toplevel-locally (cdr form) env))
          ((macrolet)
           (bytecode-compile-toplevel-macrolet (cadr form) (cddr form) env))
          ((symbol-macrolet)
           (bytecode-compile-toplevel-symbol-macrolet (cadr form) (cddr form) env))
          (otherwise
           (when *compile-time-too* (cmp:eval form env))
           (bytecode-compile-file-form form env)))
        (progn
          (when *compile-time-too* (cmp:eval form env))
          (bytecode-compile-file-form form env)))))

;; Print information about a form for *compile-print*.
(defun describe-form (form)
  (fresh-line)
  (write-string ";   ")
  (write form :length 2 :level 2 :lines 1 :pretty nil)
  (terpri)
  (values))

;; input is a character stream. output is a ub8 stream.
(defun compile-stream (input output &key environment &allow-other-keys)
  (with-constants ()
    ;; Read and compile the forms.
    (loop with env = (cmp:coerce-to-lexenv environment)
          with eof = (gensym "EOF")
          with *compile-time-too* = nil
          #|
            with cfsdp = (core:file-scope cmp::*compile-file-source-debug-pathname*)
            with cfsdl = cmp::*compile-file-source-debug-lineno*
            with cfsdo = cmp::*compile-file-source-debug-offset*
            for core:*current-source-pos-info*
              = (core:input-stream-source-pos-info input cfsdp cfsdl cfsdo)
            |#
            for form = (read input nil eof)
            until (eq form eof)
            when *compile-print*
              do (describe-form form)
            do (bytecode-compile-toplevel form env))
      ;; Write out the FASO bytecode.
      (%write-bytecode output)))

;;; TODO?: This is not a full compile-file - it returns different values
;;; and is not good at handling errors, etc. That stuff is complicated enough
;;; that it's probably out of scope. But it's nice to have a convenience
;;; function like this for practical purposes.
(defun compile-file (input-file
                     &rest keys
                     &key (output-file nil ofp) (external-format :default)
                       ((:verbose *compile-verbose*) *compile-verbose*)
                       ((:print *compile-print*) *compile-print*)
                     &allow-other-keys)
  (let ((output-file (if ofp
                         output-file
                         (make-pathname :type "faslbc" :defaults input-file))))
    (with-open-file (in input-file :external-format external-format)
      (with-open-file (out output-file
                           :direction :output
                           :if-exists :supersede
                           :if-does-not-exist :create
                           :element-type '(unsigned-byte 8))
        (apply #'compile-stream in out keys)))
    output-file))