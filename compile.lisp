(ql:quickload '#:alexandria)

(defpackage #:compile-to-vm
  (:use #:cl)
  (:shadow #:compile #:macroexpand-1 #:macroexpand))

(in-package #:compile-to-vm)

(setq *print-circle* t)

;;; FIXME: New package
(macrolet ((defcodes (&rest names)
             `(progn
                ,@(loop for i from 0
                        for name in names
                        collect `(defconstant ,name ,i))
                (defun decode (code)
                  (nth code '(,@names))))))
  (defcodes +ref+ +const+ +closure+
    +call+ +call-receive-one+ +call-receive-fixed+
    +bind+ +set+
    +make-cell+ +cell-ref+ +cell-set+
    +make-closure+
    +return+
    +arg+
    +listify-rest-args+ +parse-key-args+
    +jump+ +jump-if+ +jump-if-arg-count<+ +jump-if-arg-count>+
    +jump-if-arg-count/=+ +jump-if-supplied+
    +invalid-arg-count+
    +entry+ +exit+ +entry-close+
    +special-bind+ +symbol-value+ +symbol-value-set+ +unbind+
    +fdefinition+
    +nil+
    +eq+))

;;;

(defun macroexpand-1 (form env) (declare (ignore env)) (values form nil))
(defun macroexpand (form env) (declare (ignore env)) (values form nil))

;;;

(defstruct label function position)

(defun emit-label (context label)
  (setf (label-position label) (length (context-assembly context)))
  (setf (label-function label) (context-function context)))

(defun assemble (context &rest values)
  (let ((assembly (context-assembly context)))
    (dolist (value values)
      (if (label-p value)
          (let ((fixup (list value (context-function context) (length assembly))))
            (push fixup (cmodule-fixups (context-module context)))
            (vector-push-extend 0 assembly))
          (vector-push-extend value assembly)))))

;;; Different kinds of things can go in the variable namespace and they can
;;; all shadow each other, so we use this structure to disambiguate.
(defstruct (var-info (:constructor make-var-info (kind data)))
  (kind (member :local :special :symbol-macro :constant))
  data)

(defun make-lexical-var-info (frame-offset)
  (make-var-info :local frame-offset))
(defun make-special-var-info () (make-var-info :special nil))
(defun make-symbol-macro-var-info (expansion)
  (make-var-info :symbol-macro expansion))
(defun make-constant-var-info (value) (make-var-info :constant value))

(defstruct (lexical-environment (:constructor make-null-lexical-environment)
                                (:constructor %make-lexical-environment)
                                (:conc-name nil))
  ;; An alist of (var . var-info) in the current environment.
  (vars nil :type list)
  ;; An alist of (tag tag-dynenv . label) in the current environment.
  (tags nil :type list)
  ;; An alist of (block block-dynenv . label) in the current environment.
  (blocks nil :type list)
  ;; An alist of (fun . fun-var) in the current environment.
  (funs nil :type list)
  ;; The current end of the frame.
  (frame-end 0 :type integer)
  ;; A list of the non-local vars in scope.
  (closure-vars nil :type list))

(defun make-lexical-environment (parent &key (vars (vars parent))
                                             (tags (tags parent))
                                             (blocks (blocks parent))
                                             (frame-end (frame-end parent))
                                             (closure-vars (closure-vars parent))
                                             (funs (funs parent)))
  (%make-lexical-environment
   :vars vars :tags tags :blocks blocks :frame-end frame-end :closure-vars closure-vars
   :funs funs))

;;; Bind each variable to a stack location, returning a new lexical
;;; environment. The max local count in the current function is also
;;; updated.
(defun bind-vars (vars env context)
  (let* ((frame-start (frame-end env))
         (var-count (length vars))
         (frame-end (+ frame-start var-count))
         (function (context-function context)))
    (setf (cfunction-nlocals function)
          (max (cfunction-nlocals function) frame-end))
    (do ((index frame-start (1+ index))
         (vars vars (rest vars))
         (new-vars (vars env)
                   (acons (first vars) (make-lexical-var-info index) new-vars)))
        ((>= index frame-end)
         (make-lexical-environment env :vars new-vars :frame-end frame-end))
      (when (constantp (first vars))
        (error "Cannot bind constant value ~a!" (first vars))))))

;;; Create a new lexical environment where the old environment's
;;; lexicals get closed over.
(defun enclose (env)
  (multiple-value-bind (lexical nonlexical)
      (loop for pair in (vars env)
            for (var . info) = pair
            ;; this is necessary because we throw things on alist style
            ;; but need to not record shadowed variables here.
            when (member var seen)
              do (progn)
            else if (eq (var-info-kind info) :local)
                   collect var into lexical
            else
              collect pair into nonlexical
            collect var into seen
            finally (return (values lexical nonlexical)))
    (make-lexical-environment
     env
     :vars nonlexical
     :frame-end 0
     :closure-vars (append lexical (closure-vars env)))))

;;; Get information about a variable.
;;; Returns two values.
;;; The first is :CLOSURE, :LOCAL, :SPECIAL, :CONSTANT, :SYMBOL-MACRO, or NIL.
;;; If the variable is lexical, the first is :CLOSURE or :LOCAL,
;;; and the second is an index into the associated data.
;;; If the variable is special, the first is :SPECIAL and the second is NIL.
;;; If the variable is a macro, the first is :SYMBOL-MACRO and the second is
;;; the expansion.
;;; If the variable is a constant, :CONSTANT and the value.
;;; If the first value is NIL, the variable is unknown, and the second
;;; value is NIL.
(defun var-info (symbol env context)
  (let ((info (cdr (assoc symbol (vars env)))))
    (cond (info (values (var-info-kind info) (var-info-data info)))
          ((member symbol (closure-vars env))
           (values :closure (closure-index symbol context)))
          ((constantp symbol nil) (values :constant (eval symbol)))
          (t (values nil nil)))))

(deftype lambda-expression () '(cons (eql lambda) (cons list list)))

(defstruct (cfunction (:constructor make-cfunction (cmodule)))
  cmodule
  (bytecode (make-array 0
                        :element-type '(signed-byte 8)
                        :fill-pointer 0 :adjustable t))
  (nlocals 0)
  (closed (make-array 0 :fill-pointer 0 :adjustable t))
  (entry-point (make-label))
  module-offset
  info)

(defstruct (cmodule (:constructor make-cmodule (literals)))
  cfunctions
  literals
  fixups)

;;; The context contains information about what the current form needs
;;; to know about what it is enclosed by.
(defstruct context receiving function)

(defun context-module (context)
  (cfunction-cmodule (context-function context)))

(defun context-assembly (context)
  (cfunction-bytecode (context-function context)))

(defun literal-index (literal context)
  (let ((literals (cmodule-literals (context-module context))))
    (or (position literal literals)
        (vector-push-extend literal literals))))

(defun closure-index (symbol context)
  (let ((closed (cfunction-closed (context-function context))))
    (or (position symbol closed)
        (vector-push-extend symbol closed))))

(defun new-context (parent &key (receiving (context-receiving parent))
                                (function (context-function parent)))
  (make-context :receiving receiving :function function))

(defun compile (lambda-expression)
  (check-type lambda-expression lambda-expression)
  (let* ((env (make-null-lexical-environment))
         (module (make-cmodule (make-array 0 :fill-pointer 0 :adjustable t))))
    (link-function (compile-lambda lambda-expression env module))))

(defun compile-form (form env context)
  (etypecase form
    (symbol (compile-symbol form env context))
    (cons (compile-cons (car form) (cdr form) env context))
    (t (compile-literal form env context))))

(defun compile-literal (form env context)
  (declare (ignore env))
  (unless (eql (context-receiving context) 0)
    (assemble context +const+ (literal-index form context))))

(defun compile-symbol (form env context)
  (multiple-value-bind (kind data) (var-info form env context)
    (cond ((eq kind :symbol-macro) (compile-form data env context))
          ;; A symbol macro could expand into something with arbitrary side
          ;; effects so we always have to compile that, but otherwise, if no
          ;; values are wanted, we want to not compile anything.
          ((eql (context-receiving context) 0))
          (t
           (ecase kind
             ((:local) (assemble context +ref+ data +cell-ref+))
             ((:special) (assemble context +symbol-value+
                           (literal-index form context)))
             ((:closure) (assemble context +closure+ data +cell-ref+))
             ((:constant) (compile-literal data env context))
             ((nil)
              (warn "Unknown variable ~a: treating as special" form)
              (assemble context +symbol-value+
                (literal-index form context))))))))

(defun compile-cons (head rest env context)
  (case head
    ((progn) (compile-progn rest env context))
    ((let) (compile-let (first rest) (rest rest) env context))
    ((flet) (compile-flet (first rest) (rest rest) env context))
    ((labels) (compile-labels (first rest) (rest rest) env context))
    ((setq) (compile-setq rest env context))
    ((if) (compile-if (first rest) (second rest) (third rest) env context))
    ((function) (compile-function (first rest) env context))
    ((tagbody) (compile-tagbody rest env context))
    ((go) (compile-go (first rest) env context))
    ((block) (compile-block (first rest) (rest rest) env context))
    ((return-from) (compile-return-from (first rest) (second rest) env context))
    ((quote) (compile-literal (first rest) env context))
    ((symbol-macrolet)
     (compile-symbol-macrolet (first rest) (rest rest) env context))
    (otherwise ; function call
     (compile-function head env (new-context context :receiving 1))
     (dolist (arg rest)
       (compile-form arg env (new-context context :receiving 1)))
     (let ((receiving (context-receiving context)))
       (cond ((eq receiving t) (assemble context +call+ (length rest)))
             ((eql receiving 1) (assemble context +call-receive-one+ (length rest)))
             (t (assemble context +call-receive-fixed+ (length rest) receiving)))))))

(defun compile-progn (forms env context)
  (do ((forms forms (rest forms)))
      ((null (rest forms))
       (compile-form (first forms) env context))
    (compile-form (first forms) env (new-context context :receiving 0))))

;;; Given some declaration expressions, return a list of all variables
;;; declared special.
(defun process-declarations (declarations)
  (loop for (_ . specifiers) in declarations
        nconc (loop for (id . stuff) in specifiers
                    when (eq id 'special)
                      append stuff)))

(defun compile-let (bindings body env context)
  (multiple-value-bind (body decls) (alexandria:parse-body body)
    ;; For specials, we do the lazy thing: treat all bindings as lexical,
    ;; then make a new environment on top of that with special bindings.
    ;; This wastes space both in making unneeded cells and in using more
    ;; lexical variables than are really needed.
    (let ((vars
            ;; Compile the values as we go.
            ;; FIXME: NLX will complicate this.
            (loop for binding in bindings
                  if (symbolp binding)
                    collect binding
                    and do (assemble context +nil+)
                  if (and (consp binding) (null (cdr binding)))
                    collect (car binding)
                    and do (assemble context +nil+)
                  if (and (consp binding) (consp (cdr binding)) (null (cddr binding)))
                    collect (car binding)
                    and do (compile-form (cadr binding) env (new-context context :receiving 1))
                  do (assemble context +make-cell+))))
      (assemble context +bind+ (length vars) (frame-end env))
      (let* (;; Note that these specials can include specials that aren't bound
             ;; here, in which case we only need to note them in the lexenv.
             (specials (process-declarations decls))
             (new-env-1 (bind-vars vars env context))
             (nbinds
               ;; Generate binding code
               (loop for var in vars
                     when (member var specials)
                       sum (let ((index
                                   (nth-value 1 (var-info var new-env-1 context))))
                             (assemble context +ref+ index +cell-ref+
                               +special-bind+ (literal-index var context))
                             1))))
        (compile-progn body (if specials
                                (make-lexical-environment
                                 new-env-1
                                 :vars (loop for var in vars
                                             for info = (make-special-var-info)
                                             collect (cons var info)))
                                new-env-1)
                       context)
        (loop repeat nbinds
              do (assemble context +unbind+))))))

(defun compile-setq (pairs env context)
  (if (null pairs)
      (unless (eql (context-receiving context) 0)
        (assemble context +nil+))
      (loop for (var valf . rest) on pairs by #'cddr
            do (compile-setq-1 var valf env
                               (if rest
                                   (new-context context :receiving 0)
                                   context)))))

(defun compile-setq-1 (var valf env context)
  (multiple-value-bind (kind data) (var-info var env context)
    (ecase kind
      ((:symbol-macro)
       (compile-form `(setf ,data ,valf) env context))
      ((:special nil)
       (when (null kind) 
         (warn "Unknown variable ~a: treating as special" var))
       (compile-form valf env (new-context context :receiving 1))
       ;; If we need to return the new value, stick it into a new local
       ;; variable, do the set, then return the lexical variable.
       ;; We can't just read from the special, since some other thread may
       ;; alter it.
       (let ((index (frame-end env)))
         (unless (eql (context-receiving context) 0)
           (assemble context +set+ index +ref+ index)
           ;; called for effect, i.e. to keep frame size correct
           (bind-vars (list var) env context))
         (assemble context +symbol-value-set+ (literal-index var context))
         (unless (eql (context-receiving context) 0)
           (assemble context +ref+ index))))
      ((:local)
       (assemble context +ref+ data)
       (compile-form valf env (new-context context :receiving 1))
       (assemble context +cell-set+)
       (unless (eql (context-receiving context) 0)
         (assemble context +ref+ data +cell-ref+)))
      ((:closure)
       (assemble context +closure+ data)
       (compile-form valf env (new-context context :receiving 1))
       ;; similar concerns to specials above.
       (let ((index (frame-end env)))
         (unless (eql (context-receiving context) 0)
           (assemble context +set+ index +ref+ index)
           (bind-vars (list var) env context))
         (assemble context +cell-set+)
         (unless (eql (context-receiving context) 0)
           (assemble context +ref+ index)))))))

(defun compile-flet (definitions body env context)
  (let ((fun-vars '())
        (funs '())
        (fun-count 0))
    (dolist (definition definitions)
      (let ((name (first definition))
            (fun-var (gensym "FLET-FUN")))
        (compile-function `(lambda ,(second definition)
                             ,@(cddr definition))
                          env (new-context context :receiving 1))
        (assemble context +make-cell+)
        (push fun-var fun-vars)
        (push (cons name fun-var) funs)
        (incf fun-count)))
    (assemble context +bind+ fun-count (frame-end env))
    (let ((env (make-lexical-environment
                (bind-vars fun-vars env context)
                :funs funs)))
      (compile-progn body env context))))

(defun compile-labels (definitions body env context)
  (let ((fun-vars '())
        (funs '())
        (fun-count 0))
    (dolist (definition definitions)
      (let ((name (first definition))
            (fun-var (gensym "LABELS-FUN")))
        (push (cons name fun-var) funs)
        (push fun-var fun-vars)
        (incf fun-count)))
    (dotimes (i fun-count)
      (assemble context +nil+ +make-cell+))
    (assemble context +bind+ fun-count (frame-end env))
    (let ((env (make-lexical-environment
                (bind-vars fun-vars env context)
                :funs funs)))
      (dolist (definition definitions)
        (reference-var (cdr (assoc (first definition) (funs env)))
                       env context)
        (compile-function `(lambda ,(second definition)
                             ,@(cddr definition))
                          env (new-context context :receiving 1))
        (assemble context +cell-set+))
      (compile-progn body env context))))

(defun compile-if (condition then else env context)
  (compile-form condition env (new-context context :receiving 1))
  (let ((then-label (make-label))
        (done-label (make-label)))
    (assemble context +jump-if+ then-label)
    (compile-form else env context)
    (assemble context +jump+ done-label)
    (emit-label context then-label)
    (compile-form then env context)
    (emit-label context done-label)))

(defun compile-function (fnameoid env context)
  (unless (eql (context-receiving context) 0)
    (if (typep fnameoid 'lambda-expression)
        (let ((cfunction (compile-lambda fnameoid env (context-module context))))
          (loop for var across (cfunction-closed cfunction)
                do (reference-var var env context))
          (assemble context +make-closure+ (literal-index cfunction context)))
        (let ((pair (assoc fnameoid (funs env))))
          (cond (pair
                 (reference-var (cdr pair) env context)
                 (assemble context +cell-ref+))
                (t
                 (assemble context +fdefinition+ (literal-index fnameoid context))))))))

;;; Deal with lambda lists. Return the new environment resulting from
;;; binding these lambda vars.
(defun compile-lambda-list (lambda-list env context)
  (multiple-value-bind (required optionals rest keys aok-p aux)
      (alexandria:parse-ordinary-lambda-list lambda-list)
    (declare (ignore aux)) ; TODO
    (let* ((function (context-function context))
           (entry-point (cfunction-entry-point function))
           (error-label (make-label))
           (min-count (length required))
           (optional-count (length optionals))
           (max-count (+ min-count optional-count))
           (entry-points (make-array (1+ (- max-count min-count))))
           (key-count (length keys))
           (more-p (or rest keys))
           (env (bind-vars required env context)))
      (when (or required (not more-p))
        (emit-label context error-label)
        (assemble context +invalid-arg-count+))
      (emit-label context entry-point)
      ;; Check that a valid number of arguments have been
      ;; supplied to this function.
      (cond ((and required (= min-count max-count) (not more-p))
             (assemble context +jump-if-arg-count/=+ min-count error-label))
            (t
             (when required
               (assemble context +jump-if-arg-count<+ min-count error-label))
             (when (not more-p)
               (assemble context +jump-if-arg-count>+ max-count error-label))))
      ;; Bind each required value on the stack with a mutable cell
      ;; containing that value.
      (loop for i from (1- min-count) downto 0 do
        (assemble context +arg+ i +make-cell+))
      (when required
        (assemble context +bind+ min-count 0))
      ;; Start defaulting optional arguments.
      (dotimes (i (length entry-points))
        (setf (aref entry-points i) (make-label)))
      (let ((index (frame-end env)))
        (loop for arg-count from min-count to (1- max-count)
              for (var defaulting-form supplied-var) in optionals
              for i from 0
              do (emit-label context (aref entry-points i))
                 ;; Default the &optional and supply the supplied-p
                 ;; var. We have to make a cell for each lexical.
                 (flet ((default (suppliedp)
                          (if suppliedp
                              (assemble context +arg+ arg-count)
                              (compile-form defaulting-form env
                                            (new-context context :receiving 1)))
                          (assemble context +make-cell+)
                          (assemble context +set+ index))
                        (supply (suppliedp)
                          (if suppliedp
                              (compile-literal t env (new-context context :receiving 1))
                              (assemble context +nil+))
                          (assemble context +make-cell+)
                          (assemble context +set+ (1+ index))))
                   (let ((next (aref entry-points (1+ i)))
                         (supplied-label (make-label)))
                     (assemble context +jump-if-arg-count<+ (1+ arg-count) supplied-label)
                     (default t)
                     (when supplied-var
                       (supply t))
                     (assemble context +jump+ next)
                     (emit-label context supplied-label)
                     (default nil)
                     (when supplied-var
                       (supply nil)))
                   (incf index (if supplied-var 2 1))
                   (setq env (bind-vars (if supplied-var
                                            (list var supplied-var)
                                            (list var))
                                        env context)))))
      (unless (= min-count max-count)
        (emit-label context (aref entry-points (- max-count min-count))))
      (when rest
        (assemble context +listify-rest-args+ max-count)
        (assemble context +make-cell+)
        (assemble context +set+ (frame-end env))
        (setq env (bind-vars (list rest) env context)))
      ;; Key handling must be done in two steps:
      ;;
      ;; 1. Parse the passed arguments from the end, binding any
      ;; supplied key vars to the passed values.
      ;;
      ;; 2. Default any unsupplied key values and set the
      ;; corresponding suppliedp var for each key.
      (when keys
        (let ((key-name (mapcar #'caar keys)))
          (assemble context +parse-key-args+
            max-count
            (if aok-p (- key-count) key-count)
            (literal-index (first key-name) context)
            (frame-end env))
          (dolist (key-name (rest key-name))
            (literal-index key-name context)))
        (setq env (bind-vars (mapcar #'cadar keys) env context))
        ;; Duplicate keys are not legal so there is no chance of
        ;; shadowing between key variables at least. Supplied variables
        ;; must be sequentially bound however.
        (do ((keys keys (rest keys))
             (key-label (make-label) next-key-label)
             (next-key-label (make-label) (make-label)))
            ((null keys)
             (emit-label context key-label))
          (emit-label context key-label)
          (destructuring-bind ((key-name key-var) defaulting-form supplied-var)
              (first keys)
            (declare (ignore key-name))
            (flet ((default (suppliedp where)
                     (if suppliedp
                         (assemble context +ref+ where)
                         (compile-form defaulting-form env
                                       (new-context context :receiving 1)))
                     (assemble context +make-cell+)
                     (assemble context +set+ where))
                   (supply (suppliedp where)
                     (if suppliedp
                         (compile-literal t env (new-context context :receiving 1))
                         (assemble context +nil+))
                     (assemble context +make-cell+)
                     (assemble context +set+ where)))
              (let ((supplied-label (make-label))
                    (var-where (nth-value 1 (var-info key-var env context)))
                    (supplied-var-where (frame-end env)))
                (assemble context +jump-if-supplied+ var-where supplied-label)
                (default nil var-where)
                (when supplied-var
                  (supply nil supplied-var-where))
                (assemble context +jump+ next-key-label)
                (emit-label context supplied-label)
                (default t var-where)
                (when supplied-var
                  (supply t supplied-var-where)))
              (when supplied-var
                (setq env (bind-vars (list supplied-var) env context)))))))
      ;;;;; TODO: DEAL WITH AUX!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! PROBABLY WITH LET*
      env)))

;;; Compile the lambda form in MODULE, returning the resulting
;;; CFUNCTION.
(defun compile-lambda (form env module)
  ;; TODO: Emit code to process lambda args.
  (let* ((lambda-list (cadr form))
         (body (cddr form))
         (function (make-cfunction module))
         (context (make-context :receiving t :function function))
         (env (enclose env)))
    (push function (cmodule-cfunctions module))
    (compile-progn body (compile-lambda-list lambda-list env context) context)
    (assemble context +return+)
    function))

;;; Push VAR's value to the stack. VAR is known to be lexical.
(defun reference-var (var env context)
  (multiple-value-bind (kind index) (var-info var env context)
    (ecase kind
      ((:local) (assemble context +ref+ index))
      ((:closure) (assemble context +closure+ index)))))

(defun go-tag-p (object) (typep object '(or symbol integer)))

(defun compile-tagbody (statements env context)
  (let ((new-tags (tags env))
        (tagbody-dynenv (gensym "TAG-DYNENV")))
    (dolist (statement statements)
      (when (go-tag-p statement)
        (push (list* statement tagbody-dynenv (make-label))
              new-tags)))
    (assemble context +entry+)
    (let ((env (make-lexical-environment
                (bind-vars (list tagbody-dynenv) env context)
                :tags new-tags)))
      ;; Bind the dynamic environment. We don't need a cell as it is
      ;; not mutable.
      (multiple-value-bind (kind index)
          (var-info tagbody-dynenv env context)
        (assert (eq kind :local))
        (assemble context +set+ index))
      ;; Compile the body, emitting the tag destination labels.
      (dolist (statement statements)
        (if (go-tag-p statement)
            (emit-label context (cddr (assoc statement (tags env))))
            (compile-form statement env (new-context context :receiving 0))))))
  (assemble context +entry-close+)
  ;; return nil if we really have to
  (unless (eql (context-receiving context) 0)
    (assemble context +nil+)))

(defun compile-go (tag env context)
  (let ((pair (assoc tag (tags env))))
    (if pair
        (destructuring-bind (tag-dynenv . tag-label) (cdr pair)
          (reference-var tag-dynenv env context)
          (assemble context +exit+ tag-label))
        (error "The GO tag ~a does not exist." tag))))

(defun compile-block (name body env context)
  (let* ((block-dynenv (gensym "BLOCK-DYNENV"))
         (env (make-lexical-environment
               (bind-vars (list block-dynenv) env context)
               :blocks (acons name (cons block-dynenv (make-label))
                              (blocks env)))))
    (assemble context +entry+)
    ;; Bind the dynamic environment. We don't need a cell as it is
    ;; not mutable.
    (multiple-value-bind (kind index)
        (var-info block-dynenv env context)
      (assert (eq kind :local))
      (assemble context +set+ index))
    (compile-progn body env context)
    (emit-label context (cddr (assoc name (blocks env))))
    (assemble context +entry-close+)))

(defun compile-return-from (name value env context)
  ;;; FIXME: We currently do the wrong thing with fixed return values!
  (compile-form value env (new-context context :receiving t))
  (let ((pair (assoc name (blocks env))))
    (if pair
        (destructuring-bind (block-dynenv . block-label) (cdr pair)
          (reference-var block-dynenv env context)
          (assemble context +exit+ block-label))
        (error "The block ~a does not exist." name))))

(defun compile-symbol-macrolet (bindings body env context)
  (let* ((smacros (loop for (symbol expansion) in bindings
                        for info = (make-symbol-macro-var-info expansion)
                        collect (cons symbol info)))
         (new-env (make-lexical-environment
                   env :vars (append smacros (vars env)))))
    (compile-progn body new-env context)))

;;;; linkage

;;; Run down the hierarchy and link the compile time representations
;;; of modules and functions together into runtime objects. Return the
;;; bytecode function corresponding to CFUNCTION.
(defun link-function (cfunction)
  (let ((cmodule (cfunction-cmodule cfunction))
        (bytecode-size 0)
        (bytecode-module (vm::make-bytecode-module)))
    ;; First, create the real function objects. determining the length
    ;; of the bytecode-module bytecode vector.
    (dolist (cfunction (cmodule-cfunctions cmodule))
      (let ((bytecode-function
              (vm::make-bytecode-function
               :module bytecode-module
               :locals-frame-size (cfunction-nlocals cfunction)
               :environment-size (length (cfunction-closed cfunction)))))
        (setf (cfunction-module-offset cfunction) bytecode-size)
        (setf (cfunction-info cfunction) bytecode-function)
        (incf bytecode-size (length (cfunction-bytecode cfunction)))))
    (let* ((cmodule-literals (cmodule-literals cmodule))
           (literal-length (length cmodule-literals))
           (bytecode (make-array bytecode-size :element-type '(signed-byte 8)))
           (literals (make-array literal-length)))
      ;; Next, fill in the module bytecode vector.
      (let ((index 0))
        (dolist (cfunction (cmodule-cfunctions cmodule))
          (let ((function-bytecode (cfunction-bytecode cfunction)))
            (dotimes (local-index (length function-bytecode))
              (setf (aref bytecode index)
                    (aref function-bytecode local-index))
              (incf index)))))
      (flet ((compute-position (function offset)
               (+ (cfunction-module-offset function) offset)))
        ;; Do label fixups in the module.
        (dolist (fixup (cmodule-fixups cmodule))
          (destructuring-bind (label function offset) fixup
            (let ((position (compute-position function offset)))
              (setf (aref bytecode position)
                    (- (compute-position (label-function label)
                                         (label-position label))
                       position)))))
        ;; Compute entry points.
        (dolist (cfunction (cmodule-cfunctions cmodule))
          (setf (vm::bytecode-function-entry-pc (cfunction-info cfunction))
                (compute-position cfunction
                                  (label-position (cfunction-entry-point cfunction))))))
      ;; Now replace the cfunctions in the cmodule literal vector with
      ;; real bytecode functions.
      (dotimes (index (length (cmodule-literals cmodule)))
        (setf (aref literals index)
              (let ((literal (aref cmodule-literals index)))
                (if (cfunction-p literal)
                    (cfunction-info literal)
                    literal))))
      (setf (vm::bytecode-module-bytecode bytecode-module) bytecode)
      (setf (vm::bytecode-module-literals bytecode-module) literals)
      (cfunction-info cfunction))))
