(defpackage #:vm
  (:use #:cl)
  (:shadow #:disassemble))

(in-package #:vm)

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
    +bind-required-args+ +bind-optional-args+
    +listify-rest-args+ +parse-key-args+
    +jump+ +jump-if+ +jump-if-supplied+
    +check-arg-count<=+ +check-arg-count>=+ +check-arg-count=+
    +push-values+ +append-values+ +pop-values+
    +mv-call+ +mv-call-receive-one+ +mv-call-receive-fixed+
    +entry+ +exit+ +entry-close+
    +catch+ +throw+ +catch-close+
    +special-bind+ +symbol-value+ +symbol-value-set+ +unbind+
    +progv+
    +fdefinition+
    +nil+
    +eq+))

;;; The VM objects we need.

(defstruct bytecode-module
  bytecode
  literals)

(defstruct bytecode-closure
  template
  env)

(defstruct bytecode-function
  module
  locals-frame-size
  environment-size
  entry-pc)

(defstruct vm
  values
  stack
  stack-top
  frame-pointer
  closure
  literals
  args
  arg-count
  pc)

(defvar *vm* nil)

(defun initialize-vm (stack-size)
  (setf *vm*
        (make-vm :stack (make-array stack-size)
                 :frame-pointer 0
                 :stack-top 0)))

(defmacro assemble (&rest codes)
  `(make-array ,(length codes) :element-type '(signed-byte 8)
                               :initial-contents (list ,@codes)))

(defun disassemble-bytecode (bytecode &key (ip 0) (ninstructions t))
  (loop with blen = (length bytecode)
        for ndis from 0
        until (or (= ip blen) (and (integerp ninstructions) (eql ndis ninstructions)))
        collect (macrolet ((fixed (n)
                             `(prog1
                                  (list op ,@(loop repeat n
                                                   collect `(aref bytecode (incf ip))))
                                (incf ip))))
                  (let ((op (decode (aref bytecode ip))))
                    (ecase op
                      ((+make-cell+ +cell-ref+ +cell-set+
                                    +return+
                                    +entry+
                                    +entry-close+ +unbind+
                                    +catch-close+
                                    +throw+
                                    +progv+
                                    +nil+ +eq+
                                    +push-values+ +pop-values+
                                    +append-values+
                                    +mv-call+
                                    +mv-call-receive-one+)
                       (fixed 0))
                      ((+ref+ +const+ +closure+
                              +listify-rest-args+
                              +call+ +call-receive-one+
                              +set+ +make-closure+
                              +check-arg-count=+ +check-arg-count<=+ +check-arg-count>=+
                              +bind-required-args+
                              +exit+ +special-bind+ +symbol-value+ +symbol-value-set+
                              +catch+
                              +fdefinition+ +mv-call-receive-fixed+)
                       (fixed 1))
                      ;; These have labels, not integers, as arguments.
                      ;; TODO: Impose labels on the disassembly.
                      ((+jump+ +jump-if+) (fixed 1))
                      ((+call-receive-fixed+ +bind+ +jump-if-supplied+)
                       (fixed 2))
                      ((+bind-optional-args+) (fixed 3))
                      ((+parse-key-args+) (fixed 4)))))))

(defun disassemble (bytecode-module)
  (disassemble-bytecode (bytecode-module-bytecode bytecode-module)))

(defstruct (cell (:constructor make-cell (value))) value)
(defstruct (unbound-marker (:constructor make-unbound-marker)))

;;; Create a native callable trmapoline.
(defun make-closure (bytecode-closure)
  (declare (type (and fixnum (integer 0))))
  (let* ((template (bytecode-closure-template bytecode-closure))
         (entry-pc (bytecode-function-entry-pc template))
         (frame-size (bytecode-function-locals-frame-size template))
         (module (bytecode-function-module template))
         (bytecode (bytecode-module-bytecode module))
         (literals (bytecode-module-literals module))
         (closure (bytecode-closure-env bytecode-closure)))
    (lambda (&rest args)
      ;; Set up the stack, then call VM.
      (let* ((vm *vm*)
             (stack (vm-stack vm))
             (original-sp (vm-stack-top vm)))
        (setf (vm-args vm) (vm-stack-top vm))
        ;; Pass the argments on the stack.
        (dolist (arg args)
          (setf (aref stack (vm-stack-top vm)) arg)
          (incf (vm-stack-top vm)))
        (setf (vm-arg-count vm) (length args))
        (incf (vm-stack-top vm) 2)
        ;; Save the previous frame pointer and pc
        (setf (aref stack (- (vm-stack-top vm) 2)) (vm-pc vm))
        (setf (aref stack (- (vm-stack-top vm) 1)) (vm-frame-pointer vm))
        (setf (vm-frame-pointer vm) (vm-stack-top vm))
        (setf (vm-pc vm) entry-pc)
        (setf (vm-stack-top vm) (+ (vm-frame-pointer vm) frame-size))
        ;; set up the stack, then call vm
        (vm bytecode closure literals frame-size)
        (setf (vm-stack-top vm) original-sp)
        (values-list (vm-values vm))))))

(defvar *trace* nil)

(defstruct dynenv)
(defstruct (entry-dynenv (:include dynenv)
                         (:constructor make-entry-dynenv (fun)))
  (fun (error "missing arg") :type function))
(defstruct (sbind-dynenv (:include dynenv)
                         (:constructor make-sbind-dynenv ())))

(defvar *dynenv* nil)

(defun vm (bytecode closure constants frame-size)
  (declare (type (simple-array (signed-byte 8) (*)) bytecode)
           (type (simple-array t (*)) closure constants)
           (optimize debug))
  (let* ((vm *vm*)
         (stack (vm-stack *vm*)))
    (declare (type (simple-array t (*)) stack))
    (symbol-macrolet ((ip (vm-pc vm))
                      (sp (vm-stack-top vm))
                      (bp (vm-frame-pointer vm)))
      (labels ((stack (index)
                 ;;(declare (optimize (safety 0))) ; avoid bounds check
                 (svref stack index))
               ((setf stack) (object index)
                 ;;(declare (optimize (safety 0)))
                 (setf (svref stack index) object))
               (spush (object)
                 (prog1 (setf (stack sp) object) (incf sp)))
               (spop () (stack (decf sp)))
               (code ()
                 ;;(declare (optimize (safety 0)))
                 (aref bytecode ip))
               (next-code ()
                 ;;(declare (optimize safety 0))
                 (aref bytecode (incf ip)))
               (constant (index)
                 ;;(declare (optimize (safety 0)))
                 (aref constants index))
               (closure (index)
                 ;;(declare (optimize (safety 0)))
                 (aref closure index))
               (gather (n)
                 (let ((result nil)) ; put the most recent value on the end
                   (loop repeat n do (push (spop) result))
                   result)))
        #+(or)
        (declare (inline stack (setf stack) spush spop
                         code next-code constant closure))
        (loop with end = (length bytecode)
              until (eql ip end)
              when *trace*
                do (fresh-line)
                   (let ((frame-end (+ bp frame-size)))
                     (prin1 (list (first (disassemble-bytecode bytecode :ip ip :ninstructions 1))
                                  bp
                                  sp
                                  (subseq stack bp frame-end)
                                  ;; We take the max for partial frames.
                                  (subseq stack frame-end (max sp frame-end)))))
              do (ecase (code)
                   ((#.+ref+) (spush (stack (+ bp (next-code)))) (incf ip))
                   ((#.+const+) (spush (constant (next-code))) (incf ip))
                   ((#.+closure+) (spush (closure (next-code))) (incf ip))
                   ((#.+call+)
                    (setf (vm-values vm)
                          (multiple-value-list
                           (let ((args (gather (next-code))))
                             (apply (the function (spop)) args))))
                    (incf ip))
                   ((#.+call-receive-one+)
                    (spush (let ((args (gather (next-code))))
                             (apply (the function (spop)) args)))
                    (incf ip))
                   ((#.+call-receive-fixed+)
                    (let ((args (gather (next-code))) (mvals (next-code))
                          (fun (the function (spop))))
                      (case mvals
                        ((0) (apply fun args))
                        (t (mapcar #'spush (subseq (multiple-value-list (apply fun args))
                                                   0 mvals)))))
                    (incf ip))
                   ((#.+bind+)
                    (loop repeat (next-code)
                          for bsp from (+ bp (next-code))
                          do (setf (stack bsp) (spop)))
                    (incf ip))
                   ((#.+set+)
                    (setf (stack (+ bp (next-code))) (spop))
                    (incf ip))
                   ((#.+make-cell+) (spush (make-cell (spop))) (incf ip))
                   ((#.+cell-ref+) (spush (cell-value (spop))) (incf ip))
                   ((#.+cell-set+)
                    (let ((val (spop))) (setf (cell-value (spop)) val))
                    (incf ip))
                   ((#.+make-closure+)
                    (spush (make-closure
                            (let ((template (constant (next-code))))
                              (make-bytecode-closure
                               :template template
                               :env (coerce (gather
                                             (bytecode-function-environment-size template))
                                            'simple-vector)))))
                    (incf ip))
                   ((#.+return+)
                    ;; Tear down the stack frame.
                    (unless (eql sp (+ bp frame-size))
                      (setf (vm-values vm) (gather (- sp (+ bp frame-size)))))
                    ;; Restore previous sp and bp and tear down the stack frame.
                    (let ((old-bp (aref stack (- bp 1))))
                      (setf (vm-pc vm) (aref stack (- bp 2)))
                      (setf sp (- bp 2))
                      (setf bp old-bp))
                    (return))
                   ((#.+jump+) (incf ip (next-code)))
                   ((#.+jump-if+)
                    (incf ip (if (spop) (next-code) 2)))
                   ((#.+check-arg-count<=+)
                    (let ((n (next-code)))
                      (unless (<= (vm-arg-count vm) n)
                        (error "Invalid number of arguments: Got ~d, need at most ~d."
                               (vm-arg-count vm) n)))
                    (incf ip))
                   ((#.+check-arg-count>=+)
                    (let ((n (next-code)))
                      (unless (>= (vm-arg-count vm) n)
                        (error "Invalid number of arguments: Got ~d, need at least ~d."
                               (vm-arg-count vm) n)))
                    (incf ip))
                   ((#.+check-arg-count=+)
                    (let ((n (next-code)))
                      (unless (= (vm-arg-count vm) n)
                        (error "Invalid number of arguments: Got ~d, need exactly ~d."
                               (vm-arg-count vm) n)))
                    (incf ip))
                   ((#.+jump-if-supplied+)
                    (incf ip (if (typep (stack (+ bp (next-code))) 'unbound-marker)
                                 2
                                 (next-code))))
                   ((#.+bind-required-args+)
                    ;; Use memcpy for this.
                    (let* ((args (vm-args vm))
                           (args-end (+ args (next-code))))
                      (do ((arg-index args (1+ arg-index))
                           (frame-slot bp (1+ frame-slot)))
                          ((>= arg-index args-end))
                        (setf (stack frame-slot) (stack arg-index))))
                    (incf ip))
                   ((#.+bind-optional-args+)
                    (let* ((args (vm-args vm))
                           (required-count (next-code))
                           (optional-start (+ args required-count))
                           (optional-count (next-code))
                           (args-end (+ args (vm-arg-count vm)))
                           (end (+ optional-start optional-count))
                           (optional-frame-offset (+ bp required-count))
                           (optional-frame-end (+ optional-frame-offset optional-count)))
                      (if (<= args-end end)
                          ;; Could be coded as memcpy in C.
                          (do ((arg-index optional-start (1+ arg-index))
                               (frame-slot optional-frame-offset (1+ frame-slot)))
                              ((>= arg-index args-end)
                               ;; memcpy or similar. (blit bit
                               ;; pattern?)
                               (do ((frame-slot frame-slot (1+ frame-slot)))
                                   ((>= frame-slot optional-frame-end))
                                 (setf (stack frame-slot) (make-unbound-marker))))
                            (setf (stack frame-slot) (stack arg-index)))
                          ;; Could also be coded as memcpy.
                          (do ((arg-index optional-start (1+ arg-index))
                               (frame-slot optional-frame-offset (1+ frame-slot)))
                              ((>= arg-index end))
                            (setf (stack frame-slot) (stack arg-index))))
                      (incf ip)))
                   ((#.+listify-rest-args+)
                    (spush (loop for index from (next-code) below (vm-arg-count vm)
                                 collect (stack (+ (vm-args vm) index))))
                    (incf ip))
                   ((#.+parse-key-args+)
                    (let* ((args (vm-args vm))
                           (end (+ args (vm-arg-count vm)))
                           (more-start (+ args (next-code)))
                           (key-count-info (next-code))
                           (key-count (abs key-count-info))
                           (key-literal-start (next-code))
                           (key-literal-end (+ key-literal-start key-count))
                           (key-frame-start (+ bp (next-code)))
                           (unknown-key-p nil)
                           (allow-other-keys-p nil))
                      ;; Initialize all key values to #<unbound-marker>
                      (loop for index from key-frame-start below (+ key-frame-start key-count)
                            do (setf (stack index) (make-unbound-marker)))
                      (when (> end more-start)
                        (do ((arg-index (- end 1) (- arg-index 2)))
                            ((< arg-index (print more-start))
                             (cond ((= arg-index (1- more-start)))
                                   ((= arg-index (- more-start 2))
                                    (error "Passed odd number of &KEY args!"))
                                   (t
                                    (error "BUG! This can't happen!"))))
                          (let ((key (stack (1- arg-index))))
                            (if (eq key :allow-other-keys)
                                (setf allow-other-keys-p (stack arg-index))
                                (loop for key-index from key-literal-start below key-literal-end
                                      for offset from key-frame-start
                                      do (when (eq (constant key-index) key)
                                           (setf (stack offset) (stack arg-index))
                                           (return))
                                      finally (setf unknown-key-p key))))))
                      (when (and (not (or (minusp key-count-info)
                                          allow-other-keys-p))
                                 unknown-key-p)
                        (error "Unknown key arg ~a!" unknown-key-p)))
                    (incf ip))
                   ((#.+entry+)
                    (let ((*dynenv* *dynenv*))
                      (incf ip)
                      (tagbody
                         (setf *dynenv*
                               (make-entry-dynenv
                                (let ((old-sp sp)
                                      (old-bp bp))
                                  (lambda ()
                                    (setf sp old-sp
                                          bp old-bp)
                                    (go loop)))))
                         (spush *dynenv*)
                       loop
                         (vm bytecode closure constants frame-size))))
                   ((#.+catch+)
                    (let ((target (+ ip (next-code) 1))
                          (tag (spop))
                          (old-sp sp)
                          (old-bp bp))
                      (incf ip)
                      (catch tag
                        (vm bytecode closure constants frame-size))
                      (setf ip target)
                      (setf sp old-sp)
                      (setf bp old-bp)))
                   ((#.+throw+) (throw (spop) (values)))
                   ((#.+catch-close+)
                    (incf ip)
                    (return))
                   ((#.+exit+)
                    (incf ip (next-code))
                    (funcall (entry-dynenv-fun (spop))))
                   ((#.+entry-close+)
                    (incf ip)
                    (return))
                   ((#.+special-bind+)
                    (let ((*dynenv* (make-sbind-dynenv)))
                      (progv (list (constant (next-code))) (list (spop))
                        (incf ip)
                        (vm bytecode closure constants frame-size))))
                   ((#.+symbol-value+)
                    (spush (symbol-value (constant (next-code))))
                    (incf ip))
                   ((#.+symbol-value-set+)
                    (setf (symbol-value (constant (next-code))) (spop))
                    (incf ip))
                   ((#.+progv+)
                    (let ((*dynenv* (make-sbind-dynenv))
                          (values (spop)))
                      (progv (spop) values
                        (print ip)
                        (incf ip)
                        (print ip)
                        (vm bytecode closure constants frame-size))))
                   ((#.+unbind+)
                    (incf ip)
                    (return))
                   ((#.+push-values+)
                    (dolist (value (vm-values vm))
                      (spush value))
                    (spush (length (vm-values vm)))
                    (incf ip))
                   ((#.+append-values+)
                    (let ((n (spop)))
                      (dolist (value (vm-values vm))
                        (spush value))
                      (spush (+ n (length (vm-values vm))))
                      (incf ip)))
                   ((#.+pop-values+)
                    (setf (vm-values vm) (gather (spop)))
                    (incf ip))
                   ((#.+mv-call+)
                    (setf (vm-values vm)
                          (multiple-value-list
                           (apply (the function (spop)) (vm-values vm))))
                    (incf ip))
                   ((#.+mv-call-receive-one+)
                    (spush (apply (the function (spop)) (vm-values vm)))
                    (incf ip))
                   ((#.+mv-call-receive-fixed+)
                    (let ((args (vm-values vm))
                          (mvals (next-code))
                          (fun (the function (spop))))
                      (case mvals
                        ((0) (apply fun args))
                        (t (mapcar #'spush (subseq (multiple-value-list (apply fun args))
                                                   0 mvals)))))
                    (incf ip))
                   ((#.+fdefinition+) (spush (fdefinition (constant (next-code)))) (incf ip))
                   ((#.+nil+) (spush nil) (incf ip))
                   ((#.+eq+) (spush (eq (spop) (spop))) (incf ip))))))))
