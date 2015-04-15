(in-package :clasp-cleavir)


(defun %i32 (num)
  (cmp:jit-constant-i32 num))

(defun %i64 (num)
  (cmp:jit-constant-i64 num))

(defun %size_t (num)
  (cmp:jit-constant-size_t num))

(defun %nil ()
  "A nil in a T*"
  (llvm-sys:create-int-to-ptr cmp:*irbuilder* (cmp:jit-constant-size_t cmp:+nil-value+) cmp:+t*+ "nil"))


(defun %literal (lit &optional (label "literal"))
  (llvm-sys:create-extract-value cmp:*irbuilder* (cmp:irc-load (cmp:compile-reference-to-literal lit nil)) (list 0) label))

(defun alloca-size_t (&optional (label "var"))
  (llvm-sys:create-alloca *entry-irbuilder* cmp:+size_t+ (%i32 1) label))

(defun alloca-i32 (&optional (label "var"))
  (llvm-sys:create-alloca *entry-irbuilder* cmp:+i32+ (%i32 1) label))

(defun alloca-i8* (&optional (label "var"))
  (llvm-sys:create-alloca *entry-irbuilder* cmp:+i8*+ (%i32 1) label))

(defun alloca-t* (&optional (label "var"))
  (let ((instr (llvm-sys:create-alloca *entry-irbuilder* cmp:+t*+ (%i32 1) label)))
    #+(or)(cc-dbg-when *debug-log*
		       (format *debug-log* "          alloca-t*   *entry-irbuilder* = ~a~%" *entry-irbuilder*)
		       (format *debug-log* "          Wrote ALLOCA ~a into function ~a~%" instr (llvm-sys:get-name (instruction-llvm-function instr))))
    instr))

(defun alloca-mv-struct (&optional (label "V"))
  (llvm-sys:create-alloca *entry-irbuilder* cmp:+mv-struct+ (%i32 1) label))


(defun %load-or-null (obj)
  (if obj
      (cmp:irc-load obj)
      (llvm-sys:constant-pointer-null-get cmp:+t*+)))


(defun instruction-llvm-function (instr)
  (llvm-sys:get-parent (llvm-sys:get-parent instr)))

(defun %store (val target &optional label)
  (let* ((instr (cmp:irc-store val target)))
    (when (typep target 'llvm-sys:instruction)
      (let ((store-fn (llvm-sys:get-name (instruction-llvm-function instr)))
	    (target-fn (llvm-sys:get-name (instruction-llvm-function target))))
	(unless (string= store-fn target-fn)
	  (error "Mismatch in store function vs target function - you are attempting to store a value in a target where the store instruction is in a different LLVM function(~a) from the target value(~a)" store-fn target-fn))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; with-entry-basic-block
;;;
;;; All contained LLVM-IR gets written into the clasp-cleavir:*current-function-entry-basic-block*
;;;

(defmacro with-entry-ir-builder (&rest body)
  `(let ((cmp:*irbuilder* *entry-irbuilder*))
     ,@body))





;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; MULTIPLE-VALUE-ARRAY-ADDRESS
;;;
;;; Return the address of the multiple-value-array structure
;;; If it hasn't been determined in this function then stick the
;;; code to look it up into the entry block of the current function
;;;

(defvar *function-current-multiple-value-array-address*)
(defun multiple-value-array-address ()
  (unless *function-current-multiple-value-array-address*
    (with-entry-ir-builder
	(setq *function-current-multiple-value-array-address* 
	      (cmp:irc-intrinsic "cc_multipleValuesArrayAddress"))))
  *function-current-multiple-value-array-address*)


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; RETURN-VALUES
;;;
;;; Simplifies access to the return values stored
;;; in registers and in the multiple-value-array
;;; %numvals - returns a Value that stores the number of return values
;;; %return-registers - a list of the first (register-return-size) return values
;;;                     returned in registers (X86 System V ABI says 1pointer + 1integer)
;;; %multiple-value-array-address - The an llvm::Value address of the multiple-value array
;;;                                 It is only set if the array is needed.
;;;
(defclass return-values ()
  ((%sret-arg :initarg :sret-arg :accessor sret-arg)
   (%numvals :initarg :numvals :accessor number-of-return-values)
   (%return-registers :initarg :return-registers :accessor return-registers)))


(defvar +pointers-returned-in-registers+ 1)
;; Only one pointer and one integer can be returned in registers return value returned in a register

(defgeneric make-return-values (return-sret-arg abi))

(defmethod make-return-values (return-sret-arg (abi abi-x86-64))
  (make-instance 'return-values
		 :sret-arg return-sret-arg
		 :numvals (llvm-sys:create-in-bounds-gep cmp:*irbuilder* return-sret-arg (list (%i32 0) (%i32 1)) "ret-nvals")
		 :return-registers (list (llvm-sys:create-in-bounds-gep cmp:*irbuilder* return-sret-arg (list (%i32 0) (%i32 0)) "ret-regs"))))

(defun return-values-num (return-vals)
  (number-of-return-values return-vals))

(defun return-value-elt (return-vals idx)
  (if (< idx +pointers-returned-in-registers+)
      (elt (return-registers return-vals) idx)
      (let ((multiple-value-pointer (multiple-value-array-address)))
	(error "Finish implementing return-value-elt - you need to use gep to index into the array")
	#||(setf (multiple-value-array-address return-vals) multiple-value-pointer))
	(multiple-value-array-get multiple-value-pointer idx)||#)))




(defmacro with-return-values ((return-vals abi) &body body)
  (let ((args (gensym "args"))
	(return-sret-arg (gensym "retstruct")))
    `(let* ((,args (llvm-sys:get-argument-list cmp:*current-function*))
	    (,return-sret-arg (first ,args))
	    (,return-vals (make-return-values ,return-sret-arg ,abi)))
       ,@body)))



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; APPLY-CC-CALLING-CONVENTION
;;;
;;; Simplifies interaction with the calling convention.
;;; Arguments are passed in registers and in the multiple-value-array
;;;

(defun closure-call (call-or-invoke intrinsic-name closure arguments abi &key (label "") landing-pad)
  ;; Write excess arguments into the multiple-value array
  (unless (<= (length arguments) 5)
    (let ((mv-args (nthcdr 5 arguments)))
      (do* ((idx 5 (1+ idx))
	    (cur-arg (nthcdr 5 arguments) (cdr cur-arg))
	    (arg (car cur-arg) (car cur-arg)))
	   ((null cur-arg) nil)
	(let* ((mvarray (multiple-value-array-address))
	       (mv-elt-ref (llvm-sys:create-geparray cmp:*irbuilder* mvarray (list (%size_t 0) (%size_t idx)) "element")))
	  (%store (cmp:irc-load arg) mv-elt-ref)))))
  (with-return-values (return-vals abi)
    (let ((args (list 
		 (sret-arg return-vals)
		 (cmp:irc-load closure)
		 (%size_t (length arguments))
		 (%load-or-null (first arguments))
		 (%load-or-null (second arguments))
		 (%load-or-null (third arguments))
		 (%load-or-null (fourth arguments))
		 (%load-or-null (fifth arguments)))))
      (if (eq call-or-invoke :call)
	  (cmp:irc-create-call intrinsic-name args label)
	  (cmp:irc-create-invoke intrinsic-name args landing-pad label)))))
