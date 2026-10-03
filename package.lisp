;;;; package.lisp

(defpackage #:cl-cm
  (:use #:cl)
  (:documentation
   "Content-Addressable Common Lisp code.

Normalize a form into an alpha-renamed canonical tree and hash it to a
CIDv1 (DASL / dag-cbor / sha2-256 / base32), so that the identifier is
invariant under renaming of bound variables.")
  (:export
   ;; hashing / addressing
   #:code-cid
   #:code-node
   #:normalize-code
   #:same-code-p
   #:*code-version*
   ;; normalizer extension point
   #:define-form
   #:*special-forms*
   ;; global reference resolution (recursive content addressing)
   #:*reference-resolver*
   #:resolve-reference
   #:code-cid-with-resolver
   ;; environment (exposed for extension / inspection)
   #:lenv
   #:make-lenv
   #:lookup-var
   #:lookup-fun
   #:lookup-block
   #:lookup-tag
   #:bind-var
   #:bind-fun
   #:bind-block
   #:bind-tag
   #:fresh-var-id
   #:fresh-fun-id
   #:fresh-block-id
   #:fresh-tag-id
   #:with-fresh-ids
   #:nv
   #:norm))
