;;;; base.lisp --- canonical node helpers, lexical environment, id counters

(in-package #:cl-cm)

;;; ------------------------------------------------------------------
;;; Canonical nodes
;;; ------------------------------------------------------------------

(declaim (inline nv))
(defun nv (&rest items)
  "Build a canonical node: a general vector of ITEMS.

Nodes are plain vectors of strings, integers and nested vectors so they
can be handed straight to the DASL/CBOR encoder.  Lists are avoided on
purpose: CBOR has ambiguous list encodings (a list whose every element
is a cons is encoded as an alist and reordered), which would be fatal
for stable hashing."
  (coerce items 'vector))

(defun symbol-package-name (symbol)
  "Package name of SYMBOL, or NIL when the symbol is uninterned."
  (let ((package (symbol-package symbol)))
    (and package (package-name package))))

;;; ------------------------------------------------------------------
;;; Lexical environment
;;;
;;; Common Lisp is a Lisp-2, so variables and functions live in
;;; separate namespaces; blocks and tagbody tags are yet two more.
;;; Each namespace is a plain alist of SYMBOL -> integer id, pushed in
;;; front so that the innermost binding shadows the outer ones.
;;; ------------------------------------------------------------------

(defstruct (lenv (:constructor make-lenv))
  (vars '())
  (funs '())
  (blocks '())
  (tags '()))

(defun lookup-var (env symbol) (cdr (assoc symbol (lenv-vars env))))
(defun lookup-fun (env symbol) (cdr (assoc symbol (lenv-funs env))))
(defun lookup-block (env symbol) (cdr (assoc symbol (lenv-blocks env))))
(defun lookup-tag (env symbol) (cdr (assoc symbol (lenv-tags env))))

(defun bind-var (env symbol id)
  (let ((new (copy-lenv env)))
    (push (cons symbol id) (lenv-vars new))
    new))
(defun bind-fun (env symbol id)
  (let ((new (copy-lenv env)))
    (push (cons symbol id) (lenv-funs new))
    new))
(defun bind-block (env symbol id)
  (let ((new (copy-lenv env)))
    (push (cons symbol id) (lenv-blocks new))
    new))
(defun bind-tag (env symbol id)
  (let ((new (copy-lenv env)))
    (push (cons symbol id) (lenv-tags new))
    new))

;;; ------------------------------------------------------------------
;;; Fresh identifier counters
;;;
;;; Ids are assigned in deterministic traversal order, so two programs
;;; that differ only in the *names* of their bound identifiers get the
;;; same id assigned to the same binding position, hence the same tree.
;;; ------------------------------------------------------------------

(defvar *var-counter* 0)
(defvar *fun-counter* 0)
(defvar *block-counter* 0)
(defvar *tag-counter* 0)

(defun fresh-id (counter)
  (prog1 (symbol-value counter)
    (incf (symbol-value counter))))

(defun fresh-var-id () (fresh-id '*var-counter*))
(defun fresh-fun-id () (fresh-id '*fun-counter*))
(defun fresh-block-id () (fresh-id '*block-counter*))
(defun fresh-tag-id () (fresh-id '*tag-counter*))

(defmacro with-fresh-ids (&body body)
  "Reset every id counter, then evaluate BODY."
  `(let ((*var-counter* 0)
         (*fun-counter* 0)
         (*block-counter* 0)
         (*tag-counter* 0))
     ,@body))
