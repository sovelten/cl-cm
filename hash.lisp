;;;; hash.lisp --- content addressing of canonical code

(in-package #:cl-cm)

(defparameter *code-version* "code/v1"
  "Version tag mixed into every hash so the scheme can evolve without
silently reusing old identifiers.")

(defun normalize-code (form)
  "Return the canonical, alpha-renamed node for FORM."
  (with-fresh-ids
    (norm form (make-lenv))))

(defun code-node (form)
  "The exact version-tagged node that gets hashed for FORM."
  (nv *code-version* (normalize-code form)))

(defun code-cid (form)
  "Content identifier for FORM: CIDv1, dag-cbor, sha2-256, base32.
Alpha-equivalent forms (differing only in bound-identifier names)
produce the same CID."
  (generate-cid (code-node form)))

(defun code-cid-with-resolver (form resolver)
  "Like CODE-CID, but resolve free identifiers through RESOLVER while
normalizing FORM.  RESOLVER is a function `(lambda (namespace symbol)
cid)' — see *REFERENCE-RESOLVER*.  With this, the resulting CID depends
on the CIDs of the definitions FORM references (recursive content
addressing), not on their names."
  (let ((*reference-resolver* resolver))
    (code-cid form)))

(defun same-code-p (form-a form-b)
  "True when FORM-A and FORM-B have the same content identifier,
i.e. when they are alpha-equivalent modulo *code-version*."
  (string= (code-cid form-a) (code-cid form-b)))
