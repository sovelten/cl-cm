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

(defun read-all-identity-records (db)
  "Read DB's identity log as a list of raw records."
  (let ((path (cl-cm-db:identity-log-path db)))
    (when (probe-file path)
      (with-open-file (in path :direction :input)
        (let ((*read-eval* nil))
          (loop for record = (read in nil :eof)
                until (eq record :eof)
                collect record))))))

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

(test init-database-creates-then-loads
  (let ((directory (nth-value 1 (fresh-test-database "init"))))
    (multiple-value-bind (db existed)
        (cl-cm-db:init-database :directory directory :name "init")
      (is (not existed))
      (let ((cid (cl-cm-db:defidentity db 'foo '(f))))
        (multiple-value-bind (db2 existed2)
            (cl-cm-db:init-database :directory directory :name "init")
          (is (eq t existed2))
          (is (string= cid (cl-cm-db:identity-cid 'foo db2)))
          (is (equal '(f) (cl-cm-db:identity-code 'foo db2))))))))

(test defun-identity-and-setf-identity-write-the-log
  (let ((directory (nth-value 1 (fresh-test-database "macro"))))
    (multiple-value-bind (db)
        (cl-cm-db:init-database :directory directory :name "macro")
      (let ((cid (cl-cm-db:defun-identity add2 db (x) (+ x 2))))
        (is (stringp cid))
        (is (string= cid (cl-cm-db:identity-cid 'add2 db)))
        (let ((records (read-all-identity-records db)))
          (is (= 1 (length records)))
          (is (eq :define (first (first records))))
          (is (string= cid (fourth (first records)))))
        (cl-cm-db:setf-identity add2 db (x) (+ x 3))
        (let ((records (read-all-identity-records db)))
          (is (= 2 (length records)))
          (is (eq :set (first (second records))))
          (is (string= (cl-cm-db:identity-cid 'add2 db)
                       (fourth (second records)))))))))

(test retractidentity-removes-and-logs
  (multiple-value-bind (db directory) (fresh-test-database "retract")
    (let ((cid (cl-cm-db:defidentity db 'foo '(f))))
      (is (string= cid (cl-cm-db:retractidentity db 'foo)))
      (is (null (cl-cm-db:identity-cid 'foo db)))
      (is (null (cl-cm-db:identity-code 'foo db)))
      (let ((records (read-all-identity-records db)))
        (is (= 2 (length records)))
        (is (eq :retract (first (second records))))
        (is (string= (cl-cm-db:identity-key 'foo) (third (second records)))))
      ;; the retraction survives a reload
      (let ((db2 (cl-cm-db:make-database :directory directory :name "retract")))
        (cl-cm-db:load-database db2)
        (is (null (cl-cm-db:identity-cid 'foo db2))))
      ;; retracting again is an error
      (signals error (cl-cm-db:retractidentity db 'foo)))))

(test clean-database-shallow-keeps-log-history
  (multiple-value-bind (db) (fresh-test-database "shallow")
    (let ((old (cl-cm-db:defidentity db 'foo '(f 1))))
      (let ((new (cl-cm-db:setidentity db 'foo '(f 2))))
        (let ((stray (cl-cm-db:store-code db '(some stray code))))
          ;; the stray object is on disk but no identity names it
          (is (probe-file (cl-cm-db::object-path db stray)))
          (let ((result (cl-cm-db:clean-database db :mode :shallow)))
            (is (eq :shallow (getf result :mode)))
            (is (= 1 (getf result :removed)))
            (is (= 2 (getf result :kept)))
            ;; the superseded :define CID is still in the log, so kept
            (is (probe-file (cl-cm-db::object-path db old)))
            (is (probe-file (cl-cm-db::object-path db new)))
            (is (not (probe-file (cl-cm-db::object-path db stray))))
            ;; shallow leaves the identity log exactly as it was
            (is (= 2 (length (read-all-identity-records db))))))))))

(test clean-database-deep-compacts-log-and-objects
  (multiple-value-bind (db directory) (fresh-test-database "deep")
    (let ((old (cl-cm-db:defidentity db 'foo '(f 1))))
      (let ((new (cl-cm-db:setidentity db 'foo '(f 2))))
        (cl-cm-db:defidentity db 'bar '(g))
        (let ((stray (cl-cm-db:store-code db '(some stray code))))
          (let ((result (cl-cm-db:clean-database db :mode :deep)))
            (is (eq :deep (getf result :mode)))
            (is (= 2 (getf result :removed)))
            (is (= 2 (getf result :kept)))
            ;; the superseded CID and the stray object are gone
            (is (not (probe-file (cl-cm-db::object-path db old))))
            (is (probe-file (cl-cm-db::object-path db new)))
            (is (not (probe-file (cl-cm-db::object-path db stray))))
            ;; the log is compacted to one current record per identity
            (let ((records (read-all-identity-records db)))
              (is (= 2 (length records)))
              (is (equal (sort (list (cl-cm-db:identity-key 'bar)
                                     (cl-cm-db:identity-key 'foo))
                               #'string<)
                         (sort (mapcar #'third records) #'string<))))
            ;; and the compacted log still reloads to the current values
            (let ((db2 (cl-cm-db:make-database :directory directory :name "deep")))
              (cl-cm-db:load-database db2)
              (is (string= new (cl-cm-db:identity-cid 'foo db2)))
              (is (equal '(g) (cl-cm-db:identity-code 'bar db2))))))))))

;;; ------------------------------------------------------------------
;;; Definitions, names and referrers
;;; ------------------------------------------------------------------

(test definition-by-identity-and-cid
  (multiple-value-bind (db) (fresh-test-database "defn")
    (let ((cid (cl-cm-db:defidentity db 'inc '(lambda (x) (+ x 1)))))
      (let ((definition (cl-cm-db:definition-by-identity 'inc db)))
        (is (typep definition 'cl-cm-db:code-definition))
        (is (string= cid (cl-cm-db:code-definition-cid definition)))
        (is (equal '(x) (cl-cm-db:code-definition-lambda-list definition)))
        (is (equal '((+ x 1)) (cl-cm-db:code-definition-body definition))))
      (is (string= cid (cl-cm-db:code-definition-cid
                        (cl-cm-db:definition-by-cid db cid)))))))

(test identity-names-and-history
  (multiple-value-bind (db) (fresh-test-database "names")
    (cl-cm-db:defidentity db 'a '(lambda (x) (+ x 1)))
    (let ((first (cl-cm-db:identity-cid 'a db)))
      (cl-cm-db:defidentity db 'b '(lambda (x) (+ x 1)))
      (is (equal (list (cl-cm-db:identity-key 'a) (cl-cm-db:identity-key 'b))
                 (cl-cm-db:identity-names-for-cid db first)))
      (is (eq 'a (cl-cm-db:identity-symbol (cl-cm-db:identity-key 'a))))
      (let ((second (cl-cm-db:setidentity db 'a '(lambda (x) (+ x 2)))))
        (is (equal (list second first)
                   (cl-cm-db:identity-history 'a db)))))))

(test code-references-are-historical-and-referrers-follow-the-cid
  (multiple-value-bind (db) (fresh-test-database "refs")
    (let ((callee (cl-cm-db:defidentity db 'callee '(lambda (x) (+ x 1)))))
      (let ((caller (cl-cm-db:defidentity db 'caller '(lambda (x) (callee x)))))
        (multiple-value-bind (references unresolved) (cl-cm-db:code-references db caller)
          (is (equal (list (cons 'callee callee)) references))
          (is (null unresolved)))
        ;; Redefining the callee does not move the caller's stored references.
        (cl-cm-db:setidentity db 'callee '(lambda (x) (+ x 2)))
        (multiple-value-bind (references) (cl-cm-db:code-references db caller)
          (is (equal (list (cons 'callee callee)) references)))
        (is (equal (list (cl-cm-db:identity-key 'caller))
                   (cl-cm-db:code-referrers db callee)))
        (is (null (cl-cm-db:code-referrers
                   db (cl-cm-db:identity-cid 'callee db))))))))

(test source-references-use-current-identities
  (multiple-value-bind (db) (fresh-test-database "src")
    (cl-cm-db:defidentity db 'helper '(lambda (x) x))
    (multiple-value-bind (references unresolved)
        (cl-cm-db:source-references db '(lambda (y) (helper y)))
      (is (equal (list (cons 'helper (cl-cm-db:identity-cid 'helper db)))
                 references))
      (is (null unresolved)))))

;;; ------------------------------------------------------------------
;;; Compiled code
;;; ------------------------------------------------------------------

(test code-function-pins-superseded-versions
  (multiple-value-bind (db) (fresh-test-database "compile")
    (cl-cm-db:defidentity db 'inc '(lambda (x) (+ x 1)))
    (let ((twice (cl-cm-db:defidentity db 'twice '(lambda (x) (inc (inc x))))))
      (is (= 12 (funcall (cl-cm-db:code-function db twice) 10)))
      (cl-cm-db:setidentity db 'inc '(lambda (x) (+ x 10)))
      (is (= 12 (funcall (cl-cm-db:code-function db twice) 10))
          "TWICE still calls the version of INC it was compiled against")
      (let ((twice2 (cl-cm-db:setidentity db 'twice '(lambda (x) (inc (inc x))))))
        (is (= 30 (funcall (cl-cm-db:code-function db twice2) 10)))))))

(test call-identity-and-whole-database-helpers
  (multiple-value-bind (db) (fresh-test-database "helpers")
    (cl-cm-db:defidentity db 'inc '(lambda (x) (+ x 1)))
    (cl-cm-db:defidentity db 'double '(lambda (x) (* x 2)))
    (is (= 12 (cl-cm-db:call-identity 'inc db 11)))
    (is (= 2 (cl-cm-db:code-count db)))
    (let ((seen '()))
      (cl-cm-db:map-definitions
       (lambda (definition)
         (push (cl-cm-db:code-definition-cid definition) seen))
       db)
      (is (= 2 (length seen))))))

(test ensure-identity-defines-then-sets
  (multiple-value-bind (db) (fresh-test-database "ensure")
    (let ((first (cl-cm-db:ensure-identity db 'foo '(lambda () 1))))
      (is (equal '(lambda () 1) (cl-cm-db:identity-code 'foo db)))
      (let ((second (cl-cm-db:ensure-identity db 'foo '(lambda () 2))))
        (is (not (string= first second)))
        (is (equal '(lambda () 2) (cl-cm-db:identity-code 'foo db)))))))

;;; ------------------------------------------------------------------
;;; Suite runner, used by RUN-SELF-TEST
;;; ------------------------------------------------------------------

(defun run-database-tests ()
  "Run the FiveAM database suite.  Returns T when every test passed."
  (let ((results (run 'cl-cm-db-suite)))
    (explain! results)
    (results-status results)))
