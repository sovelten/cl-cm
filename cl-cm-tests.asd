;;;; cl-cm-tests.asd

(asdf:defsystem #:cl-cm-tests
  :description "Self tests for cl-cm (content-addressable Common Lisp code)"
  :author "sophia"
  :license "MIT"
  :depends-on (#:cl-cm #:fiveam)
  :serial t
  :components ((:file "test")
               (:file "test-db"))
  :perform (asdf:test-op (operation component)
             (uiop:symbol-call :cl-cm-tests :run-self-test)))
