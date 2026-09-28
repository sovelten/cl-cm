;;;; alpha.lisp --- alpha-renaming normalizer for Common Lisp code
;;;;
;;;; `norm' walks a form with a lexical environment and produces a
;;;; canonical node in which every *bound* identifier (variable,
;;;; function, block name, tag) is replaced by an integer derived from
;;;; its binding position.  Free identifiers keep their package-qualified
;;;; name, because they refer to code outside the form.  Quoted data is
;;;; not renamed at all.
;;;;
;;;; Two forms that differ only in the names of bound identifiers are
;;;; therefore normalized to EQUAL trees and hash to the same CID.
;;;;
;;;; Nodes are tagged vectors, e.g.
;;;;   #("var" <id>)                      lexical variable reference
;;;;   #("free" <pkg> <name>)             free variable reference
;;;;   #("fref" <id>) / #("gref" <pkg> <name>)   function reference
;;;;   #("lambda" <lambda-list> <body>)   lambda
;;;;   #("call" <fn> <args>)
;;;;   #("quote" <datum>) ...

(in-package #:cl-cm)

(declaim (ftype (function (t lenv) t) norm))

(defvar *special-forms* (make-hash-table :test #'eq)
  "Maps a special/macro symbol to a handler `(lambda (args env) ...)',
where ARGS is the cdr of the form.  This is the extension point: add a
handler for any binding form `norm' does not already understand.")

(defmacro define-form (name (args env) &body body)
  "Register a normalizer for the form whose head is NAME."
  `(setf (gethash ',name *special-forms*)
         (lambda (,args ,env) ,@body)))

;;; ------------------------------------------------------------------
;;; Syntax helpers
;;; ------------------------------------------------------------------

(defun lambda-list-keyword-p (symbol)
  (and (symbolp symbol)
       (plusp (length (symbol-name symbol)))
       (char= #\& (char (symbol-name symbol) 0))))

(defun parse-param (item)
  "Parse a simple parameter: SYMBOL or (SYMBOL INIT [SUPPLIED-P])."
  (if (consp item)
      (values (first item) (second item) (third item))
      (values item nil nil)))

(defun parse-key-param (item)
  "Parse a &key parameter.
Returns (values keyword-name symbol init supplied-p)."
  (cond
    ((symbolp item)
     (values (symbol-name item) item nil nil))
    ((consp item)
     (let ((head (first item)))
       (if (consp head)
           (destructuring-bind (keyword symbol) head
             (values (symbol-name keyword) symbol (second item) (third item)))
           (values (symbol-name head) head (second item) (third item)))))
    (t (error "Malformed &key parameter: ~S" item))))

;;; ------------------------------------------------------------------
;;; Quoted data (never renamed)
;;; ------------------------------------------------------------------

(defun norm-datum (x)
  "Normalize quoted data: identifiers keep their identity, nothing is renamed."
  (cond
    ((consp x) (nv "cons" (norm-datum (car x)) (norm-datum (cdr x))))
    ((symbolp x) (nv "sym" (or (symbol-package-name x) "") (symbol-name x)))
    ((stringp x) (nv "str" x))
    ((vectorp x) (nv "vec" (map 'vector #'norm-datum x)))
    ((numberp x) (nv "num" x))
    ((characterp x) (nv "char" (char-code x)))
    (t (nv "atom" (princ-to-string x)))))

;;; ------------------------------------------------------------------
;;; Identifier references
;;; ------------------------------------------------------------------

(defun with-new-tag-scope (env)
  "A new function (lambda / flet / labels body) starts a fresh go/tag
scope: tagbody tags are not visible across function boundaries."
  (let ((new (copy-lenv env)))
    (setf (lenv-tags new) '())
    new))

(defun norm-var (env symbol)
  (let ((id (lookup-var env symbol)))
    (if id
        (nv "var" id)
        (nv "free" (symbol-package-name symbol) (symbol-name symbol)))))

(defun norm-fun (env symbol)
  (let ((id (lookup-fun env symbol)))
    (if id
        (nv "fref" id)
        (nv "gref" (symbol-package-name symbol) (symbol-name symbol)))))

;;; ------------------------------------------------------------------
;;; Bindings
;;; ------------------------------------------------------------------

(defun norm-lambda-list (lambda-list env)
  "Normalize LAMBDA-LIST, binding every parameter.
Returns (values node new-env)."
  (let ((out '())
        (mode :required)
        (env env))
    (flet ((bind (symbol)
             (let ((id (fresh-var-id)))
               (setf env (bind-var env symbol id))
               id)))
      (dolist (item lambda-list)
        (cond
          ((lambda-list-keyword-p item)
           (push (string-downcase (symbol-name item)) out)
           (setf mode (case (intern (symbol-name item) :keyword)
                        (:&optional :optional)
                        (:&rest :rest)
                        (:&body :rest)
                        (:&key :key)
                        (:&aux :aux)
                        (t mode))))
          ((eq mode :required)
           (push (bind item) out))
          ((eq mode :rest)
           (push (bind item) out))
          ((eq mode :optional)
           (multiple-value-bind (symbol init supplied) (parse-param item)
             (push (nv "opt" (bind symbol)
                       (if init (norm init env) (nv "false"))
                       (if supplied (bind supplied) (nv "false")))
                   out)))
          ((eq mode :key)
           (multiple-value-bind (keyword symbol init supplied) (parse-key-param item)
             (push (nv "key" keyword (bind symbol)
                       (if init (norm init env) (nv "false"))
                       (if supplied (bind supplied) (nv "false")))
                   out)))
          ((eq mode :aux)
           (multiple-value-bind (symbol init) (parse-param item)
             (push (nv "aux" (bind symbol)
                       (if init (norm init env) (nv "false")))
                   out))))))
    (values (coerce (nreverse out) 'vector) env)))

(defun norm-value-bindings (bindings env star)
  "Normalize `(VAR INIT)...' or `(VAR)...' bindings.
For `let' (STAR = NIL) every INIT is evaluated in the outer ENV; for
`let*' (STAR = T) each binding is visible to the following INITs.
Returns (values node new-env)."
  (flet ((name-of (binding)
           (if (consp binding) (first binding) binding))
         (init-of (binding)
           (if (consp binding) (second binding) nil)))
    (if star
        (let ((out '())
              (env env))
          (dolist (binding bindings)
            (let ((init (init-of binding))
                  (id (fresh-var-id)))
              (push (nv "bind" id
                        (if init (norm init env) (nv "false")))
                    out)
              (setf env (bind-var env (name-of binding) id))))
          (values (coerce (nreverse out) 'vector) env))
        (let ((out '())
              (pairs '()))
          (dolist (binding bindings)
            (let ((init (init-of binding))
                  (id (fresh-var-id)))
              (push (nv "bind" id
                        (if init (norm init env) (nv "false")))
                    out)
              (push (cons (name-of binding) id) pairs)))
          (let ((env env))
            (dolist (pair (nreverse pairs))
              (setf env (bind-var env (car pair) (cdr pair))))
            (values (coerce (nreverse out) 'vector) env))))))

(defun norm-fun-definitions (definitions env recursive)
  "Normalize flet/labels/macrolet definitions.
RECURSIVE means the names are visible inside their own bodies (labels).
Returns (values definitions-node body-env)."
  (let* ((names (mapcar #'first definitions))
         (ids (loop repeat (length names) collect (fresh-fun-id)))
         (definition-env
           (if recursive
               (let ((env env))
                 (loop for name in names for id in ids
                       do (setf env (bind-fun env name id)))
                 env)
               env))
         (body-env
           (let ((env env))
             (loop for name in names for id in ids
                   do (setf env (bind-fun env name id)))
             env))
         (nodes
           (loop for definition in definitions
                 for id in ids
                 collect (multiple-value-bind (lambda-list env)
                             (norm-lambda-list (second definition) definition-env)
                           (nv "def" id lambda-list
                               (norm-body (cddr definition)
                                          (with-new-tag-scope env)))))))
    (values (coerce nodes 'vector) body-env)))

(defun norm-tagbody (statements env)
  "Normalize a tagbody statement list.  Atoms are tags and are bound."
  (let ((tags '())
        (env env))
    (dolist (item statements)
      (when (atom item)
        (let ((id (fresh-tag-id)))
          (push (cons item id) tags)
          (setf env (bind-tag env item id)))))
    (nv "tagbody"
        (coerce
         (loop for item in statements
               if (atom item)
                 collect (nv "tag" (cdr (assoc item tags)))
               else
                 collect (norm item env))
         'vector))))

(defun norm-body (forms env)
  (coerce (mapcar (lambda (form) (norm form env)) forms) 'vector))

;;; ------------------------------------------------------------------
;;; Special-form handlers
;;; ------------------------------------------------------------------

(define-form quote (args env)
  (declare (ignore env))
  (nv "quote" (norm-datum (first args))))

(define-form function (args env)
  (let ((x (first args)))
    (cond
      ((symbolp x) (nv "fun" (norm-fun env x)))
      ((and (consp x) (eq (car x) 'lambda))
       (norm x env))
      (t (nv "fun" (norm-datum x))))))

(define-form lambda (args env)
  (multiple-value-bind (lambda-list env)
      (norm-lambda-list (first args) env)
    (nv "lambda" lambda-list
        (norm-body (rest args) (with-new-tag-scope env)))))

(define-form let (args env)
  (multiple-value-bind (bindings env)
      (norm-value-bindings (first args) env nil)
    (nv "let" bindings (norm-body (rest args) env))))

(define-form let* (args env)
  (multiple-value-bind (bindings env)
      (norm-value-bindings (first args) env t)
    (nv "let*" bindings (norm-body (rest args) env))))

(define-form flet (args env)
  (multiple-value-bind (definitions env)
      (norm-fun-definitions (first args) env nil)
    (nv "flet" definitions (norm-body (rest args) env))))

(define-form labels (args env)
  (multiple-value-bind (definitions env)
      (norm-fun-definitions (first args) env t)
    (nv "labels" definitions (norm-body (rest args) env))))

(define-form macrolet (args env)
  (multiple-value-bind (definitions env)
      (norm-fun-definitions (first args) env t)
    (nv "macrolet" definitions (norm-body (rest args) env))))

(define-form symbol-macrolet (args env)
  (let ((definitions (first args))
        (body (rest args))
        (env env))
    (dolist (definition definitions)
      (setf env (bind-var env (first definition) (fresh-var-id))))
    (nv "symbol-macrolet"
        (coerce (mapcar (lambda (definition)
                          (nv "sdef" (lookup-var env (first definition))
                              (norm (second definition) env)))
                        definitions)
                'vector)
        (norm-body body env))))

(define-form multiple-value-bind (args env)
  (destructuring-bind (variables value . body) args
    (let ((value-node (norm value env))
          (ids (loop repeat (length variables) collect (fresh-var-id))))
      (let ((env env))
        (loop for variable in variables for id in ids
              do (setf env (bind-var env variable id)))
        (nv "mvbind" (coerce ids 'vector) value-node
            (norm-body body env))))))

(define-form destructuring-bind (args env)
  (destructuring-bind (lambda-list value . body) args
    (let ((value-node (norm value env)))
      (multiple-value-bind (lambda-list env)
          (norm-lambda-list lambda-list env)
        (nv "dbind" lambda-list value-node (norm-body body env))))))

(define-form dolist (args env)
  (destructuring-bind ((variable list-form . result) . body) args
    (let* ((id (fresh-var-id))
           (bound-env (bind-var env variable id)))
      (nv "dolist" id (norm list-form env)
          (if result (norm (first result) bound-env) (nv "false"))
          (norm-body body bound-env)))))

(define-form dotimes (args env)
  (destructuring-bind ((variable count-form . result) . body) args
    (let* ((id (fresh-var-id))
           (bound-env (bind-var env variable id)))
      (nv "dotimes" id (norm count-form env)
          (if result (norm (first result) bound-env) (nv "false"))
          (norm-body body bound-env)))))

(define-form prog (args env)
  (multiple-value-bind (bindings env)
      (norm-value-bindings (first args) env nil)
    (nv "prog" bindings (norm-tagbody (rest args) env))))

(define-form prog* (args env)
  (multiple-value-bind (bindings env)
      (norm-value-bindings (first args) env t)
    (nv "prog*" bindings (norm-tagbody (rest args) env))))

(define-form block (args env)
  (let ((id (fresh-block-id)))
    (nv "block" id
        (norm-body (rest args) (bind-block env (first args) id)))))

(defun block-target (env name)
  (let ((id (lookup-block env name)))
    (if id
        (nv "block-ref" id)
        (nv "free-block"
            (if (symbolp name) (symbol-package-name name) nil)
            (if (symbolp name) (symbol-name name) (princ-to-string name))))))

(define-form return-from (args env)
  (let ((value (second args)))
    (if value
        (nv "return-from" (block-target env (first args)) (norm value env))
        (nv "return-from" (block-target env (first args))))))

(define-form tagbody (args env)
  (norm-tagbody args env))

(define-form go (args env)
  (let* ((tag (first args))
         (target (let ((id (lookup-tag env tag)))
                   (if id
                       (nv "tag-ref" id)
                       (nv "free-tag"
                           (if (symbolp tag) (symbol-package-name tag) nil)
                           (if (symbolp tag) (symbol-name tag)
                               (princ-to-string tag)))))))
    (nv "go" target)))

;;; ------------------------------------------------------------------
;;; The walker
;;; ------------------------------------------------------------------

(defun norm-call (form env)
  (nv "call"
      (if (symbolp (car form))
          (norm-fun env (car form))
          (norm (car form) env))
      (coerce (mapcar (lambda (argument) (norm argument env)) (cdr form))
              'vector)))

(defun norm (form env)
  "Normalize FORM in lexical environment ENV into a canonical node."
  (cond
    ((consp form)
     (let ((handler (and (symbolp (car form))
                         (gethash (car form) *special-forms*))))
       (if handler
           (funcall handler (cdr form) env)
           (norm-call form env))))
    ((null form) (nv "false"))
    ((eq form t) (nv "true"))
    ((keywordp form) (nv "kw" (symbol-name form)))
    ((symbolp form) (norm-var env form))
    ((numberp form) (nv "num" form))
    ((stringp form) (nv "str" form))
    ((characterp form) (nv "char" (char-code form)))
    (t (nv "atom" (princ-to-string form)))))
