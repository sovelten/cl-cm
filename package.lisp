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
   ;; low-level encoding, used by the code database (cl-cm-db)
   #:encode
   #:generate-block-cid
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

(defpackage #:cl-cm-db
  (:use #:cl)
  (:documentation
   "A small, persistent, content-addressed database of code identities,
built on top of cl-cm.

The database is made of two parts:

  * an append-only IDENTITY LOG (a text file): one readable
    s-expression per line, `(:define <timestamp> <key> <cid>)' or
    `(:set <timestamp> <key> <cid>)'.  The current value of an identity
    is the last record that mentions its key.

  * a CODE STORE (a directory): one object file per CID
    (git/Unison-style), each holding both the CBOR encoding of the
    resolved canonical node and the original source expression.

A definition's CID is computed with the database acting as cl-cm's
*reference-resolver*, so free references resolve to the CIDs of the
identities they name: content addressing is recursive.")
  (:export
   ;; database object
   #:code-database
   #:make-database
   #:load-database
   #:ensure-database
   #:database-loaded-p
   #:identity-log-path
   #:code-store-path
   #:database-identities
   #:database-code
   ;; identities
   #:defidentity
   #:setidentity
   #:defun-identity
   #:setf-identity
   #:identity-cid
   #:identity-code
   #:identity-key
   ;; content addressing through the database
   #:database-resolver
   #:database-code-node
   #:database-code-blob
   #:database-code-cid
   #:store-code))
