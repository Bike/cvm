(defpackage #:cvm.load
  (:use #:cl)
  (:local-nicknames (#:m #:cvm.machine)
                    (#:float #:ieee-floats))
  (:export #:load-bytecode))

(in-package #:cvm.load)

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
    (setf-gethash 77 htind keyind valueind)
    (make-sb64 78 sind sb64)
    (find-package 79 sind nameind)
    (make-bignum 80 sind size . words) ; size is signed
    (make-symbol 81)
    (intern 82 sind packageind nameind)
    (make-character 83 sind ub32)
    (make-pathname 85)
    (make-bytecode-function 87)
    (make-bytecode-module 88)
    (setf-literals 89 modind litsind)
    (make-single-float 90 sind ub32)
    (make-double-float 91 sind ub64)
    (funcall-create 93 sind fnind)
    (funcall-initialize 94 fnind)
    (fdefinition 95 find nameind)
    (fcell 96 find nameind)
    (vcell 97 vind nameind)
    (find-class 98 sind cnind)
    (init-object-array 99 ub64)
    (environment 100)
    (attribute 255 name nbytes . data)))

;;; Read an unsigned n-byte integer from a ub8 stream, big-endian.
(defun read-ub (n stream)
  ;; read-sequence might be better but bla bla consing
  (loop with int = 0
        repeat n
        do (setf int (logior (ash int 8) (read-byte stream)))
        finally (return int)))

(defun read-ub64 (stream) (read-ub 8 stream))
(defun read-ub32 (stream) (read-ub 4 stream))
(defun read-ub16 (stream) (read-ub 2 stream))

;;; Read a signed n-byte integer from a ub8 stream, big-endian.
(defun read-sb (n stream)
  (let ((word (read-ub n stream))
        (nbits (* n 8)))
    (declare (type (integer 1 64) nbits))
    ;; Read sign bit and make this negative if it's set.
    ;; FIXME: Do something more efficient probably.
    (- word (ash (ldb (byte 1 (1- nbits)) word) nbits))))

(defun read-sb64 (stream) (read-sb 8 stream))
(defun read-sb32 (stream) (read-sb 4 stream))
(defun read-sb16 (stream) (read-sb 2 stream))
(defun read-sb8  (stream) (read-sb 1 stream))

(defconstant +magic+ #x8d7498b1) ; randomly chosen bytes.

(defmacro verboseprint (message &rest args)
  `(when *load-verbose*
     (format t ,(concatenate 'string "~&; " message "~%") ,@args)))
(defmacro printprint (message &rest args)
  `(when *load-print*
     (format t ,(concatenate 'string "~&; " message "~%") ,@args)))

(defvar *debug-loader* nil)

(defmacro dbgprint (message &rest args)
  `(when *debug-loader*
     (format *error-output* ,(concatenate 'string "~&; " message "~%") ,@args)))

(defun load-magic (stream)
  (let ((magic (read-ub32 stream)))
    (unless (= magic +magic+)
      (error "~s is not a valid bytecode FASL: invalid magic identifier ~d"
             stream magic))
    (dbgprint "Magic number matches: ~x" magic)))

;; Bounds for major and minor version understood by this loader.
(defparameter *min-version* '(0 13))
(defparameter *max-version* '(0 13))

(defun loadable-version-p (major minor)
  (and
   ;; minimum
   (if (= major (first *min-version*))
       (>= minor (second *min-version*))
       (> major (first *min-version*)))
   ;; maximum
   (if (= major (first *max-version*))
       (<= minor (second *max-version*))
       (< major (first *max-version*)))))

(defun load-version (stream)
  (let ((major (read-ub16 stream)) (minor (read-ub16 stream)))
    (unless (loadable-version-p major minor)
      (error "Don't know how to load bytecode FASL format version ~d.~d
(This loader only understands ~d.~d to ~d.~d)"
             major minor (first *min-version*) (second *min-version*)
             (first *max-version*) (second *max-version*)))
    (dbgprint "File version ~d.~d (loader accepts ~d.~d-~d.~d)"
              major minor (first *min-version*) (second *min-version*)
              (first *max-version*) (second *max-version*))
    (values major minor)))

;; Major and minor version of the file being read.
(defvar *major*)
(defvar *minor*)

;; how many bytes are needed to represent an index?
(defvar *index-bytes*)

(defun read-index (stream)
  (ecase *index-bytes*
    ((1) (read-byte stream))
    ((2) (read-ub16 stream))
    ((4) (read-ub32 stream))
    ((8) (read-ub64 stream))))

(defun read-mnemonic (stream)
  (let* ((opcode (read-byte stream))
         (info (find opcode +ops+ :key #'second)))
    (if info
        (first info)
        (error "BUG: Unknown opcode #x~x" opcode))))

;; Constants vector we're producing.
(defvar *constants*)
(declaim (type simple-vector *constants*))

;; Bit vector that is 1 only at indices that have been initialized.
(defvar *initflags*)
(declaim (type (simple-array bit (*)) *initflags*))

;; The environment we're loading into.
(defvar *environment*)

(define-condition loader-error (file-error)
  ()
  (:default-initargs :pathname *load-pathname*))

(define-condition invalid-fasl (loader-error) ())

(define-condition uninitialized-constant (invalid-fasl)
  ((%index :initarg :index :reader offending-index))
  (:report (lambda (condition stream)
             (format stream "FASL ~s is invalid:
Tried to read constant #~d before initializing it"
                     (file-error-pathname condition)
                     (offending-index condition)))))

(define-condition index-out-of-range (invalid-fasl)
  ((%index :initarg :index :reader offending-index)
   (%nobjs :initarg :nobjs :reader nobjs))
  (:report (lambda (condition stream)
             (format stream "FASL ~s is invalid:
Tried to access constant #~d, but there are only ~d constants in the FASL."
                     (file-error-pathname condition)
                     (offending-index condition) (nobjs condition)))))

(define-condition not-all-initialized (invalid-fasl)
  ((%indices :initarg :indices :reader offending-indices))
  (:report (lambda (condition stream)
             (format stream "FASL ~s is invalid:
Did not initialize constants~{ #~d~}"
                     (file-error-pathname condition)
                     (offending-indices condition)))))

(defun check-initialization (flags)
  (when (find 0 flags)
    (error 'not-all-initialized
           :indices (loop for i from 0
                          for e across flags
                          when (zerop e) collect i)))
  (values))

(defun constant (index)
  (cond ((not (array-in-bounds-p *initflags* index))
         (error 'index-out-of-range :index index
                                    :nobjs (length *initflags*)))
        ((zerop (sbit *initflags* index))
         (error 'uninitialized-constant :index index))
        (t (aref *constants* index))))

(define-condition set-initialized-constant (invalid-fasl)
  ((%index :initarg :index :reader offending-index))
  (:report (lambda (condition stream)
             (format stream "FASL ~s is invalid:
Tried to define constant #~d, but it was already defined"
                     (file-error-pathname condition)
                     (offending-index condition)))))

(defun (setf constant) (value index)
  (cond ((not (array-in-bounds-p *initflags* index))
         (error 'index-out-of-range :index index
                                    :nobjs (length *initflags*)))
        ((zerop (sbit *initflags* index))
         (setf (aref *constants* index) value
               (sbit *initflags* index) 1))
        (t (error 'set-initialized-constant :index index))))

;; Versions 0.0-0.2: Return how many bytes were read.
;; Versions 0.3-: Return value irrelevant.
(defgeneric %load-instruction (mnemonic stream))

(defmethod %load-instruction ((mnemonic (eql 'nil)) stream)
  (let ((index (read-index stream)))
    (dbgprint " (nil ~d)" index)
    (setf (constant index) nil)))

(defmethod %load-instruction ((mnemonic (eql 't)) stream)
  (let ((index (read-index stream)))
    (dbgprint " (t ~d)" index)
    (setf (constant index) t)))

(defmethod %load-instruction ((mnemonic (eql 'cons)) stream)
  (let ((index (read-index stream)))
    (dbgprint " (cons ~d)" index)
    (setf (constant index) (cons nil nil))))

(defmethod %load-instruction ((mnemonic (eql 'rplaca)) stream)
  (let ((cons (read-index stream)) (value (read-index stream)))
    (dbgprint " (rplaca ~d ~d)" cons value)
    (setf (car (constant cons)) (constant value))))

(defmethod %load-instruction ((mnemonic (eql 'rplacd)) stream)
  (let ((cons (read-index stream)) (value (read-index stream)))
    (dbgprint " (rplacd ~d ~d)" cons value)
    (setf (cdr (constant cons)) (constant value))))

(defmacro read-sub-byte (array stream nbits)
  (let ((perbyte (floor 8 nbits))
        (a (gensym "ARRAY")) (s (gensym "STREAM")))
    `(let* ((,a ,array) (,s ,stream)
            (total-size (array-total-size ,a)))
       (multiple-value-bind (full-bytes remainder) (floor total-size 8)
         (loop for byteindex below full-bytes
               for index = (* ,perbyte byteindex)
               for byte = (read-byte ,s)
               do ,@(loop for j below perbyte
                          for bit-index
                            = (* nbits (- perbyte j 1))
                          for bits = `(ldb (byte ,nbits ,bit-index)
                                           byte)
                          for arrindex = `(+ index ,j)
                          collect `(setf (row-major-aref array ,arrindex) ,bits)))
         ;; write remainder
         (let* ((index (* ,perbyte full-bytes))
                (byte (read-byte ,s)))
           (loop for j below remainder
                 for bit-index = (* ,nbits (- ,perbyte j 1))
                 for bits = (ldb (byte ,nbits bit-index) byte)
                 do (setf (row-major-aref ,a (+ index j)) bits)))))))

(defmethod %load-instruction ((mnemonic (eql 'make-array)) stream)
  (let* ((index (read-index stream)) (uaet-code (read-byte stream))
         (uaet (decode-uaet uaet-code))
         (packing-code (read-byte stream))
         (packing-type (decode-packing packing-code))
         (rank (read-byte stream))
         (dimensions (loop repeat rank collect (read-ub16 stream)))
         (array (make-array dimensions :element-type uaet)))
    (dbgprint " (make-array ~d ~x ~x ~d)" index uaet-code packing-code rank)
    (dbgprint "  dimensions ~a" dimensions)
    (setf (constant index) array)
    (macrolet ((undump (form)
                 `(loop for i below (array-total-size array)
                        for elem = ,form
                        do (setf (row-major-aref array i) elem))))
      (cond ((equal packing-type 'nil))
            ((equal packing-type 'base-char)
             (undump (code-char (read-byte stream))))
            ((equal packing-type 'character)
             (undump (code-char (read-ub32 stream))))
            ((equal packing-type 'single-float)
             (undump (float:decode-float32 (read-ub32 stream))))
            ((equal packing-type 'double-float)
             (undump (float:decode-float64 (read-ub64 stream))))
            ((equal packing-type '(complex single-float))
             (undump
              (complex (float:decode-float32 (read-ub32 stream))
                       (float:decode-float32 (read-ub32 stream)))))
            ((equal packing-type '(complex double-float))
             (undump
              (complex (float:decode-float64 (read-ub64 stream))
                       (float:decode-float64 (read-ub64 stream)))))
            ((equal packing-type 'bit) (read-sub-byte array stream 1))
            ((equal packing-type '(unsigned-byte 2))
             (read-sub-byte array stream 2))
            ((equal packing-type '(unsigned-byte 4))
             (read-sub-byte array stream 4))
            ((equal packing-type '(unsigned-byte 8))
             (read-sequence array stream))
            ((equal packing-type '(unsigned-byte 16))
             (undump (read-ub16 stream)))
            ((equal packing-type '(unsigned-byte 32))
             (undump (read-ub32 stream)))
            ((equal packing-type '(unsigned-byte 64))
             (undump (read-ub64 stream)))
            ((equal packing-type '(signed-byte 8))
             (undump (read-sb8  stream)))
            ((equal packing-type '(signed-byte 16))
             (undump (read-sb16 stream)))
            ((equal packing-type '(signed-byte 32))
             (undump (read-sb32 stream)))
            ((equal packing-type '(signed-byte 64))
             (undump (read-sb64 stream)))
            ((equal packing-type 't)) ; setf-aref takes care of it
            (t (error "BUG: Unknown packing-type ~s" packing-type))))))

(defmethod %load-instruction ((mnemonic (eql 'setf-row-major-aref)) stream)
  (let ((index (read-index stream)) (aindex (read-ub16 stream))
        (value (read-index stream)))
    (dbgprint " ((setf row-major-aref) ~d ~d ~d" index aindex value)
    (setf (row-major-aref (constant index) aindex)
          (constant value))))

(defmethod %load-instruction ((mnemonic (eql 'make-hash-table)) stream)
  (let ((index (read-index stream)))
    (dbgprint " (make-hash-table ~d)" index)
    (let* ((testcode (read-byte stream))
           (test (ecase testcode
                   ((#b00) 'eq)
                   ((#b01) 'eql)
                   ((#b10) 'equal)
                   ((#b11) 'equalp)))
          (count (read-ub16 stream)))
      (dbgprint "  test = ~a, count = ~d" test count)
      (setf (constant index) (make-hash-table :test test :size count)))))

(defmethod %load-instruction ((mnemonic (eql 'setf-gethash)) stream)
  (let ((htind (read-index stream))
        (keyind (read-index stream)) (valind (read-index stream)))
    (dbgprint " ((setf gethash) ~d ~d ~d)" htind keyind valind)
    (setf (gethash (constant keyind) (constant htind))
          (constant valind))))

(defmethod %load-instruction ((mnemonic (eql 'make-sb64)) stream)
  (let ((index (read-index stream)) (sb64 (read-sb64 stream)))
    (dbgprint " (make-sb64 ~d ~d)" index sb64)
    (setf (constant index) sb64)))

(defmethod %load-instruction ((mnemonic (eql 'find-package)) stream)
  (let ((index (read-index stream)) (name (read-index stream)))
    (dbgprint " (find-package ~d ~d)" index name)
    (setf (constant index) (find-package (constant name)))))

(defmethod %load-instruction ((mnemonic (eql 'make-bignum)) stream)
  (let ((index (read-index stream)) (ssize (read-sb64 stream)))
    (dbgprint " (make-bignum ~d ~d)" index ssize)
    (setf (constant index)
          (let ((result 0) (size (abs ssize)) (negp (minusp ssize)))
            (loop repeat size
                  do (let ((word (read-ub64 stream)))
                       (dbgprint  "#x~8,'0x" word)
                       (setf result (logior (ash result 64) word)))
                  finally (return (if negp (- result) result)))))))

(defmethod %load-instruction ((mnemonic (eql 'make-single-float)) stream)
  (let ((index (read-index stream)) (bits (read-ub32 stream)))
    (dbgprint " (make-single-float ~d #x~4,'0x)" index bits)
    (setf (constant index) (float:decode-float32 bits))))

(defmethod %load-instruction ((mnemonic (eql 'make-double-float)) stream)
  (let ((index (read-index stream)) (bits (read-ub64 stream)))
    (dbgprint " (make-double-float ~d #x~8,'0x)" index bits)
    (setf (constant index) (float:decode-float64 bits))))

(defmethod %load-instruction ((mnemonic (eql 'ratio)) stream)
  (let ((index (read-index stream))
        (numi (read-index stream)) (deni (read-index stream)))
    (dbgprint " (ratio ~d ~d ~d)" index numi deni)
    (setf (constant index)
          ;; a little inefficient.
          (/ (constant numi) (constant deni)))))

(defmethod %load-instruction ((mnemonic (eql 'complex)) stream)
  (let ((index (read-index stream))
        (reali (read-index stream)) (imagi (read-index stream)))
    (dbgprint " (complex ~d ~d ~d)" index reali imagi)
    (setf (constant index)
          (complex (constant reali) (constant imagi)))))

(defmethod %load-instruction ((mnemonic (eql 'make-symbol)) stream)
  (let ((index (read-index stream))
        (namei (read-index stream)))
    (dbgprint " (make-symbol ~d ~d)" index namei)
    (setf (constant index) (make-symbol (constant namei)))))

(defmethod %load-instruction ((mnemonic (eql 'intern)) stream)
  (let ((index (read-index stream))
        (package (read-index stream)) (name (read-index stream)))
    (dbgprint " (intern ~d ~d ~d)" index package name)
    (setf (constant index)
          (intern (constant name) (constant package)))))

(defmethod %load-instruction ((mnemonic (eql 'make-character)) stream)
  (let* ((index (read-index stream)) (code (read-ub32 stream))
         (char (code-char code)))
    (dbgprint " (make-character ~d #x~x) ; ~c" index code char)
    (setf (constant index) char)))

(defmethod %load-instruction ((mnemonic (eql 'make-pathname)) stream)
  (let ((index (read-index stream))
        (hosti (read-index stream)) (devicei (read-index stream))
        (directoryi (read-index stream)) (namei (read-index stream))
        (typei (read-index stream)) (versioni (read-index stream)))
    (dbgprint " (make-pathname ~d ~d ~d ~d ~d ~d ~d)"
              index hosti devicei directoryi namei typei versioni)
    (setf (constant index)
          (make-pathname :host (constant hosti)
                         :device (constant devicei)
                         :directory (constant directoryi)
                         :name (constant namei)
                         :type (constant typei)
                         :version (constant versioni)))))

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

(defun decode-uaet (uaet-code)
  (or (first (find uaet-code +array-packing-infos+ :key #'second))
      (error "BUG: Unknown UAET code ~x" uaet-code)))

(defun decode-packing (code) (decode-uaet code)) ; same for now

(defmethod %load-instruction ((mnemonic (eql 'make-bytecode-function)) stream)
  (let ((index (read-index stream))
        (entry-point (read-ub32 stream))
        (size (read-ub32 stream))
        (nlocals (read-ub16 stream))
        (nclosed (read-ub16 stream))
        (modulei (read-index stream))
        (namei (read-index stream))
        (lambda-listi (read-index stream))
        (docstringi (read-index stream)))
    (dbgprint " (make-bytecode-function ~d ~d ~d ~d~@[ ~d~] ~d ~d ~d)"
              index entry-point nlocals nclosed
              modulei namei lambda-listi docstringi)
    (let ((module (constant modulei))
          ;; FIXME: use attrs for these instead
          (name (constant namei))
          (lambda-list (constant lambda-listi))
          (docstring (constant docstringi)))
      (declare (ignore name lambda-list docstring))
      (dbgprint "  entry-point = ~d, nlocals = ~d, nclosed = ~d"
                entry-point nlocals nclosed)
      (dbgprint "  module-index = ~d" modulei)
      (setf (constant index)
            (m:make-bytecode-function
             m:*client* module nlocals nclosed entry-point size)))))

(defmethod %load-instruction ((mnemonic (eql 'make-bytecode-module)) stream)
  (let* ((index (read-index stream))
         (len (read-ub32 stream))
         (bytecode (make-array len :element-type '(unsigned-byte 8)))
         ;; literals set by setf-literals
         (module (m:make-bytecode-module :bytecode bytecode)))
    (dbgprint " (make-bytecode-module ~d ~d)" index len)
    (read-sequence bytecode stream)
    (dbgprint "  bytecode:~{ ~2,'0x~}" (coerce bytecode 'list))
    (setf (constant index) module)))

(defmethod %load-instruction ((mnemonic (eql 'setf-literals)) stream)
  (let* ((mod (constant (read-index stream)))
         (nlits (read-ub16 stream))
         (lits (make-array nlits)))
    (loop for i below nlits
          do (setf (aref lits i) (constant (read-index stream))))
    (dbgprint " (setf-literals ~s ~s)" mod lits)
    (setf (m:bytecode-module-literals mod) lits)))

(defmethod %load-instruction ((mnemonic (eql 'fdefinition)) stream)
  (let ((find (read-index stream)) (namei (read-index stream)))
    (dbgprint " (fdefinition ~d ~d)" find namei)
    (setf (constant find) (fdefinition (constant namei)))))

(defmethod %load-instruction ((mnemonic (eql 'fcell)) stream)
  (let ((ind (read-index stream)) (fnamei (read-index stream)))
    (dbgprint " (fcell ~d ~d)" ind fnamei)
    (setf (constant ind)
          (m:link-function m:*client* *environment*
                           (constant fnamei)))))

(defmethod %load-instruction ((mnemonic (eql 'vcell)) stream)
  (let ((ind (read-index stream)) (vnamei (read-index stream)))
    (dbgprint " (vcell ~d ~d)" ind vnamei)
    (setf (constant ind)
          (m:link-variable m:*client* *environment*
                           (constant vnamei)))))

(defmethod %load-instruction ((mnemonic (eql 'environment)) stream)
  (let ((ind (read-index stream)))
    (dbgprint " (environment ~d)" ind)
    (setf (constant ind)
          (m:link-environment m:*client* *environment*))))

(defmethod %load-instruction ((mnemonic (eql 'funcall-create)) stream)
  (let ((index (read-index stream)) (funi (read-index stream))
        (args (loop repeat (read-ub16 stream)
                    collect (read-index stream))))
    (dbgprint " (funcall-create ~d ~d~{ ~d~})" index funi args)
    (setf (constant index)
          (apply (constant funi) (mapcar #'constant args)))))

(defmethod %load-instruction ((mnemonic (eql 'funcall-initialize)) stream)
  (let ((funi (read-index stream))
        (args (loop repeat (read-ub16 stream)
                    collect (read-index stream))))
    (dbgprint " (funcall-initialize ~d~{ ~d~})" funi args)
    (dbgprint "  calling ~s" (constant funi))
    (apply (constant funi) (mapcar #'constant args))))

(defmethod %load-instruction ((mnemonic (eql 'find-class)) stream)
  (let ((index (read-index stream)) (cni (read-index stream)))
    (dbgprint " (find-class ~d ~d)" index cni)
    (setf (constant index) (find-class (constant cni)))))

(defmethod %load-instruction ((mnemonic (eql 'init-object-array)) stream)
  (check-initialization *initflags*)
  (let ((nobjs (read-ub64 stream)))
    (dbgprint " (init-object-array ~d)" nobjs)
    (setf *index-bytes* (max 1 (ash 1 (1- (ceiling (integer-length nobjs) 8))))
          *constants* (make-array nobjs)
          *initflags* (make-array nobjs :element-type 'bit :initial-element 0))))

(defun load-instruction (stream)
  (%load-instruction (read-mnemonic stream) stream))

(defparameter *attributes*
  (let ((ht (make-hash-table :test #'equal)))
    #+clasp (setf (gethash "clasp:source-pos-info" ht) 'source-pos-info)
    #+clasp (setf (gethash "clasp:module-debug-info" ht) 'module-debug-info)
    ht))

(defgeneric %load-attribute (mnemonic stream))

(defmethod %load-attribute ((mnemonic string) stream)
  (let ((nbytes (read-ub32 stream)))
    (dbgprint " (unknown-attribute ~s ~d)" mnemonic nbytes)
    ;; FIXME: would file-position be better? Is it guaranteed to work here?
    (loop repeat nbytes do (read-byte stream))))

(defun load-attribute (stream)
  (let ((aname (constant (read-index stream))))
    (%load-attribute (or (gethash aname *attributes*) aname) stream)))

(defmethod %load-instruction ((mnemonic (eql 'attribute)) stream)
  (load-attribute stream))

(defun load-bytecode-stream (stream *environment*
                             &key ((:verbose *load-verbose*)
                                   *load-verbose*))
  (load-magic stream)
  (multiple-value-bind (*major* *minor*) (load-version stream)
    (let* ((ninsts (read-ub64 stream))
           ;; Bind these, and also set them to empty so that if there's
           ;; an instruction that tries to set a constant before doing
           ;; init-object-array, we get a nice error.
           (*index-bytes* 0)
           (*constants* #())
           (*initflags* #*))
      (dbgprint "Executing FASL bytecode")
      (dbgprint "File reports ~d instructions" ninsts)
      (loop repeat ninsts
            do (load-instruction stream))
      ;; CLHS is sort of written like LISTEN only works on character
      ;; streams, but that would be a pointless restriction.
      ;; Clasp and SBCL at least allow it on byte streams.
      (when (listen stream)
        (error "Bytecode continues beyond end of instructions"))
      (check-initialization *initflags*)))
  (values))

(defun load-bytecode (filespec *environment*
                      &key
                        ((:verbose *load-verbose*) *load-verbose*)
                        ((:print *load-print*) *load-print*)
                        ((:debug *debug-loader*) *debug-loader*)
                        (if-does-not-exist :error)
                        (external-format :default))
  (let ((*load-pathname* (pathname (merge-pathnames filespec))))
    (with-open-file (input filespec :element-type '(unsigned-byte 8)
                                    :if-does-not-exist if-does-not-exist
                                    :external-format external-format)
      ;; check for :if-does-not-exist nil failure
      (unless input (return-from load-bytecode nil))
      (verboseprint "Loading ~a as FASL" filespec)
      (load-bytecode-stream input *environment*)
      t)))
