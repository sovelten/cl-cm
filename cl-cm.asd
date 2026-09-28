;;;; cl-cm.asd --- Content-Addressable Common Lisp code

(asdf:defsystem #:cl-cm
  :description "Content-addressable Common Lisp code (alpha-renaming + DASL/CID hashing)"
  :author "sophia"
  :license "MIT"
  :version "0.1.0"
  :serial t
  :depends-on (#:cl-dasl)
  :components ((:file "package")
               (:file "base")
               (:file "alpha")
               (:file "hash")))
