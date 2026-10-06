;;;; test-db.lisp --- FiveAM tests for the cl-cm code database (cl-cm-db)
;;;;
;;;; These complement the framework-free checks in test.lisp.  They are
;;;; picked up by `(asdf:test-system :cl-cm)' (through RUN-SELF-TEST) and
;;;; can be run on their own with:
;;;;   (fiveam:run! 'cl-cm-tests::cl-cm-db-suite)

(in-package #:cl-cm-tests)

(def-suite cl-cm-db-suite
  :description "The cl-cm-db identity/code database.")

(in-suite cl-cm-db-suite)

(defvar *test-db-counter* 0
  "Makes each test's temporary database directory unique within an image.")

(defun fresh-test-database (&optional (name "db"))
  "A database in a brand-new temporary directory (nothing on disk yet).
Returns (values DATABASE DIRECTORY)."
  (let* ((unique (incf *test-db-counter*))
         (directory
           (merge-pathnames
            (format nil "cl-cm-db-test-~A-~D-~D/"
                    name (get-universal-time) unique)
            (uiop:temporary-directory))))
    (values (cl-cm-db:make-database :directory directory :name name)
            directory)))

;;; ------------------------------------------------------------------
;;; Defining identities
;;; ------------------------------------------------------------------

(test defidentity-stores-code-and-cid
  (multiple-value-bind (db) (fresh-test-database "def")
    (let ((cid (cl-cm-db:defidentity db 'foo '(lambda (x) (+ x 1)))))
      (is (stringp cid))
      (is (string= cid (cl-cm-db:identity-cid 'foo db)))
      (is (equal '(lambda (x) (+ x 1)) (cl-cm-db:identity-code 'foo db)))
      (is (null (cl-cm-db:identity-cid 'unknown db))))))

(test defidentity-twice-signals-an-error
  (multiple-value-bind (db) (fresh-test-database "dup")
    (cl-cm-db:defidentity db 'foo '(f))
    (signals error (cl-cm-db:defidentity db 'foo '(g)))))

(test setidentity-unknown-signals-an-error
  (multiple-value-bind (db) (fresh-test-database "unset")
    (signals error (cl-cm-db:setidentity db 'nope '(g)))))

(test setidentity-changes-the-cid
  (multiple-value-bind (db) (fresh-test-database "set")
    (let ((before (cl-cm-db:defidentity db 'foo '(f 1))))
      (let ((after (cl-cm-db:setidentity db 'foo '(f 2))))
        (is (not (string= before after)))
        (is (string= after (cl-cm-db:identity-cid 'foo db)))
        (is (equal '(f 2) (cl-cm-db:identity-code 'foo db)))))))

;;; ------------------------------------------------------------------
;;; The identity log
;;; ------------------------------------------------------------------

(test identity-log-is-append-only-and-timestamped
  (multiple-value-bind (db) (fresh-test-database "log")
    (cl-cm-db:defidentity db 'foo '(f))
    (cl-cm-db:setidentity db 'foo '(g))
    (let ((records '()))
      (with-open-file (in (cl-cm-db:identity-log-path db))
        (let ((*read-eval* nil))
          (loop for record = (read in nil :eof)
                until (eq record :eof)
                do (push record records))))
      (setf records (nreverse records))
      (is (= 2 (length records)))
      (is (eq :define (first (first records))))
      (is (eq :set (first (second records))))
      ;; both records name the same identity...
      (is (string= (third (first records)) (third (second records))))
      ;; ...and each carries a UTC timestamp string.
      (is (stringp (second (first records))))
      (is (search "T" (second (first records)))))))

;;; ------------------------------------------------------------------
;;; The code store
;;; ------------------------------------------------------------------

(test object-file-holds-cbor-and-source
  (multiple-value-bind (db) (fresh-test-database "obj")
    (let* ((cid (cl-cm-db:defidentity db 'foo '(lambda (x) (+ x 1))))
           (path (merge-pathnames cid (cl-cm-db:code-store-path db))))
      (is (probe-file path))
      (multiple-value-bind (blob source) (cl-cm-db::read-object path)
        ;; the blob is "the code saved in the hash": hashing it re-derives the CID
        (is (string= cid (cl-cm:generate-block-cid blob)))
        ;; and the original expression was kept alongside it
        (is (equal '(lambda (x) (+ x 1))
                   (let ((*read-eval* nil)) (read-from-string source))))))))

;;; ------------------------------------------------------------------
;;; Persistence
;;; ------------------------------------------------------------------

(test database-persists-across-reload
  (multiple-value-bind (db directory) (fresh-test-database "persist")
    (let ((cid (cl-cm-db:defidentity db 'foo '(lambda (x) (+ x 1)))))
      (cl-cm-db:defidentity db 'bar '(lambda (y) (* y 2)))
      (let ((db2 (cl-cm-db:make-database :directory directory :name "persist")))
        (cl-cm-db:load-database db2)
        (is (string= cid (cl-cm-db:identity-cid 'foo db2)))
        (is (equal '(lambda (x) (+ x 1)) (cl-cm-db:identity-code 'foo db2)))
        (is (equal '(lambda (y) (* y 2)) (cl-cm-db:identity-code 'bar db2)))))))

(test reload-keeps-the-latest-value-of-a-changed-identity
  (multiple-value-bind (db directory) (fresh-test-database "latest")
    (cl-cm-db:defidentity db 'foo '(f 1))
    (let ((after (cl-cm-db:setidentity db 'foo '(f 2))))
      (let ((db2 (cl-cm-db:make-database :directory directory :name "latest")))
        (cl-cm-db:load-database db2)
        (is (string= after (cl-cm-db:identity-cid 'foo db2)))
        (is (equal '(f 2) (cl-cm-db:identity-code 'foo db2)))))))

;;; ------------------------------------------------------------------
;;; Recursive content addressing
;;; ------------------------------------------------------------------

(test references-resolve-through-the-database
  (multiple-value-bind (db) (fresh-test-database "resolve")
    (cl-cm-db:defidentity db 'bar '(lambda (x) x))
    ;; naming BAR, a known identity, is not the same as an unresolved name:
    (is (not (string= (cl-cm-db:database-code-cid db '(lambda (y) (bar y)))
                      (cl-cm:code-cid '(lambda (y) (bar y))))))))

(test changing-a-referenced-identity-changes-the-referrer
  (multiple-value-bind (db) (fresh-test-database "rec")
    (cl-cm-db:defidentity db 'bar '(lambda (x) (baz x)))
    (let ((foo-cid (cl-cm-db:defidentity db 'foo '(lambda (y) (bar y)))))
      ;; the stored CID is reproducible from the database...
      (is (string= foo-cid
                   (cl-cm-db:database-code-cid db '(lambda (y) (bar y)))))
      ;; ...but changing BAR changes the CID FOO would now get...
      (cl-cm-db:setidentity db 'bar '(lambda (x) (baz x) x))
      (is (not (string= foo-cid
                        (cl-cm-db:database-code-cid db '(lambda (y) (bar y))))))
      ;; ...while FOO's stored source is untouched (identities are the stable part)
      (is (equal '(lambda (y) (bar y)) (cl-cm-db:identity-code 'foo db))))))

;;; ------------------------------------------------------------------
;;; Suite runner, used by RUN-SELF-TEST
;;; ------------------------------------------------------------------

(defun run-database-tests ()
  "Run the FiveAM database suite.  Returns T when every test passed."
  (let ((results (run 'cl-cm-db-suite)))
    (explain! results)
    (results-status results)))
