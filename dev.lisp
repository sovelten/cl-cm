(let ((project-dir (make-pathname :name nil :type nil :defaults *load-truename*)))
  (pushnew project-dir asdf:*central-registry* :test #'equal))

(ql:quickload :cl-cm)
(ql:quickload :cl-cm-tests)
