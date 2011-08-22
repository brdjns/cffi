;; Calling foreign functions
;; Liam Healy 2009-04-17 13:04:15EDT functions.lisp
;; Time-stamp: <2010-11-27 22:24:20EST functions.lisp>
;; $Id: $

(in-package :fsbv)

(export '(foreign-funcall defcfun foreign-function-not-prepared
	  defcfun-args-from-ff-args))

(define-condition foreign-function-not-prepared (error)
  ((foreign-function-name
    :initarg :foreign-function-name :reader foreign-function-name))
  (:report
   (lambda (condition stream)
     (format stream "Foreign function ~a did not prepare correctly"
	     (foreign-function-name condition))))
  (:documentation
   "A condition that has been signalled by the FSBV library."))

(defun prepare-function (foreign-function-name return-type argument-types)
  "Generate a closure that can be called on the Lisp objects and will return
   a Lisp object."
  (let* ((number-of-arguments (length argument-types))
	 (no-return-p (member return-type *no-value*))
	 (fo-symbols (loop for i from 0 below number-of-arguments
			collect (make-symbol (format nil "ARG~d" i)))))
    `(let ((cif (cffi:foreign-alloc 'ffi-cif))
	   (ffi-argtypes (cffi:foreign-alloc :pointer :count ,number-of-arguments)))
       (setf ,@(loop for argtype in argument-types
		  for argc from 0
		  append
		  `((cffi:mem-aref ffi-argtypes :pointer ,argc)
		    (libffi-type-pointer ,argtype))))
       (unless
	   (eql :OK
		(prep-cif cif :default-abi ,number-of-arguments
			  (libffi-type-pointer ,return-type)
			  ffi-argtypes))
	 (error
	  'foreign-function-not-prepared
	  :foreign-function-name ',foreign-function-name))
       (lambda (&rest args)
	 (with-foreign-objects
	     ,(loop for i from 0 below number-of-arguments
		 collect `(,(nth i fo-symbols) ',(nth i argument-types) (nth ,i args)))
	   (cffi:with-foreign-objects
	       ((argvalues :pointer ,number-of-arguments)
		,@(unless no-return-p `((result ',return-type))))
	     (setf ,@(loop for argc from 0 below number-of-arguments
			append
			`((cffi:mem-aref argvalues :pointer ,argc)
			  ,(nth argc fo-symbols))))
	     (call cif
		   (cffi:foreign-symbol-pointer ,foreign-function-name)
		   ,(if no-return-p '(cffi:null-pointer) 'result)
		   argvalues)
	     ,(unless no-return-p
		(convert-from-pointer 'result return-type))))))))

(defun defcfun-args-from-ff-args (arguments)
  "Convert the argument format from foreign-funcall to defcfun form.
   Returns a list of input arguments, and the return type."
  (values 
   (loop for (type symbol) on (butlast arguments) by #'cddr
      collect (list symbol type))
   (first (last arguments))))

(defmacro foreign-funcall (name-and-options &rest arguments)
  "Call the foreign function with or without structs-by-value."
  (multiple-value-bind (arguments-symbol-type return-type)
      (defcfun-args-from-ff-args arguments)
    (let ((name (name-from-name-and-options name-and-options)))
      (if (or (defined-type-p return-type)
	      (some 'defined-type-p (mapcar 'second arguments-symbol-type)))
	  `(funcall
	    ,(if (symbolp name)
		 `(get ',name 'prepared)
		 (prepare-function
		  ;; We do not use the "options" in name-and-options yet
		  name
		  return-type
		  (mapcar 'second arguments-symbol-type)))
	    ,@(mapcar 'first arguments-symbol-type))
	  ;; If there are no call or return by value structs, simply use
	  ;; cffi:foreign-funcall.
	  `(cffi:foreign-funcall ,name-and-options ,@arguments)))))

(defmacro defcfun (name-and-options return-type &body args)
  "Define a Lisp function that calls a foreign function.
   If the specified Lisp name has no home package (apparently
   uninterned), then the Lisp function is not made, but property
   'prepared for the function symbol is bound to the prepared
   function, through which the foreign function can be called."
  (multiple-value-bind (lisp-name foreign-name foreign-options)
      (cffi::parse-name-and-options name-and-options)
    (declare (ignore foreign-options))
    (let ((docstring (when (stringp (car args)) (pop args)))
	  (argsymbs (mapcar 'first args))
	  (set-property
	   `(setf (get ',lisp-name 'prepared)
		  ,(prepare-function
		    foreign-name return-type (mapcar 'second args)))))
      (if (symbol-package lisp-name)
	  `(progn
	     ,set-property
	     (defun ,lisp-name ,argsymbs
	       ,@(if docstring (list docstring))
	       (funcall (get ',lisp-name 'prepared) ,@argsymbs)))
	  ;; The symbol used for the lisp-name is apparently
	  ;; uninterned, so don't bother with the defun, because it
	  ;; could never be referenced.
	  set-property))))
