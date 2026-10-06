;;;; db.lisp --- a persistent, content-addressed database of code identities
;;;;
;;;; This is the "definition graph" layer on top of cl-cm: it associates a
;;;; stable *identity* (a symbol, e.g. a top-level name) with the content
;;;; identifier (CID) of a piece of code, and stores that code.
;;;;
;;;; The database has two parts, each its own file/directory:
;;;;
;;;;   * the IDENTITY LOG -- an append-only text file.  Every identity
;;;;     definition or redefinition appends one readable s-expression,
;;;;     `(:define <timestamp> <key> <cid>)' or
;;;;     `(:set <timestamp> <key> <cid>)'.  Folding the log from the top
;;;;     and keeping the last record per key yields the *current*
;;;;     identities; a future compaction can rewrite the log in place.
;;;;
;;;;   * the CODE STORE -- a directory with one object file per CID
;;;;     (git/Unison-style).  Each object holds two things: the CBOR
;;;;     encoding of the resolved canonical node (the bytes the CID
;;;;     hashes, i.e. "the code saved in the hash") and the original
;;;;     source expression that produced it (before normalization).
;;;;
;;;; The database also acts as cl-cm's *reference-resolver*: when it
;;;; computes a CID it resolves every free identifier that names a known
;;;; identity to that identity's CID.  Content addressing is therefore
;;;; recursive -- `foo' referencing `bar' has a CID that changes when
;;;; `bar' does -- exactly as cl-cm's `code-cid-with-resolver' promises.

(in-package #:cl-cm-db)

;;; ------------------------------------------------------------------
;;; The database object
;;; ------------------------------------------------------------------

(defclass code-database ()
  ((identity-log :initarg :identity-log
                 :accessor identity-log-path
                 :documentation "Pathname of the append-only identity log.")
   (code-store :initarg :code-store
               :accessor code-store-path
               :documentation "Directory holding one object file per CID.")
   (identities :initform (make-hash-table :test #'equal)
               :accessor database-identities
               :documentation "In-memory key (string) -> CID (string) cache.")
   (code :initform (make-hash-table :test #'equal)
         :accessor database-code
         :documentation "In-memory CID (string) -> CODE-ENTRY cache.")
   (loaded-p :initform nil
             :accessor database-loaded-p
             :documentation "True once LOAD-DATABASE has populated the caches."))
  (:documentation "A content-addressed identity/code database (see file header)."))

(defstruct (code-entry (:constructor make-code-entry (source)))
  "One stored piece of code: the original source expression and nothing
else.  The canonical node and CBOR blob are recomputable from SOURCE and
the current identities, and are not kept in memory."
  (source nil))

(defun make-database (&key (directory #p"./") (name "cl-cm-db")
                           identity-log code-store)
  "Build a CODE-DATABASE whose two parts live under DIRECTORY.

The identity log is DIRECTORY/NAME.identities and the code store is the
directory DIRECTORY/NAME.objects/.  IDENTITY-LOG and CODE-STORE override
those defaults when supplied."
  (let ((dir (uiop:ensure-directory-pathname directory)))
    (make-instance 'code-database
                   :identity-log (or identity-log
                                     (merge-pathnames
                                      (format nil "~A.identities" name) dir))
                   :code-store (or code-store
                                   (merge-pathnames
                                    (format nil "~A.objects/" name) dir)))))

;;; ------------------------------------------------------------------
;;; Identity keys and timestamps
;;; ------------------------------------------------------------------

(defun identity-key (identity)
  "Canonical string key for IDENTITY, a symbol or a string.

A symbol is keyed by its package-qualified name (`PKG::NAME'), so two
symbols spelled the same in different packages are distinct identities;
an uninterned symbol is keyed `#::NAME'.  A string is taken to be a key
already (this is what lets a log be read back without the packages the
identities came from)."
  (etypecase identity
    (string identity)
    (symbol
     (if (symbol-package identity)
         (format nil "~A::~A"
                 (package-name (symbol-package identity))
                 (symbol-name identity))
         (format nil "#::~A" (symbol-name identity))))))

(defun timestamp-string (&optional (universal-time (get-universal-time)))
  "UTC timestamp for the identity log, e.g. \"2024-05-01T09:30:00Z\"."
  (multiple-value-bind (sec min hour date month year)
      (decode-universal-time universal-time 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ"
            year month date hour min sec)))

(defun simplify-string (string)
  "Return STRING as a simple character string.

`format' returns base-char arrays; under `*print-readably*' SBCL prints
those as `#A(...)' rather than \"...\", which is ugly in the
\(meant-to-be-greppable) identity log.  Copying into a fresh
`make-string' yields a `(simple-array character (*))', which prints as a
plain string literal."
  (let ((out (make-string (length string))))
    (replace out string)
    out))

;;; ------------------------------------------------------------------
;;; Content addressing through the database
;;; ------------------------------------------------------------------

(defun database-resolver (db)
  "A cl-cm reference resolver that consults DB's identity table.

Suitable as the RESOLVER argument of `cl-cm:code-cid-with-resolver', or
as a value for `cl-cm:*reference-resolver*'.  It resolves a free
identifier to the CID of the identity that names it, regardless of
cl-cm's :variable/:function namespace.  The returned closure shares DB's
identity table, so identities loaded later are visible to it."
  (let ((identities (database-identities db)))
    (lambda (namespace symbol)
      (declare (ignore namespace))
      (gethash (identity-key symbol) identities))))

(defun database-code-node (db form)
  "The resolved, version-tagged canonical node that FORM hashes to in DB
\(free references replaced by the CIDs of the identities they name)."
  (let ((cl-cm:*reference-resolver* (database-resolver db)))
    (cl-cm:code-node form)))

(defun database-code-blob (db form)
  "The DASL/CBOR bytes of FORM's canonical node, as resolved by DB.
These are exactly the bytes stored in the object file and hashed to a CID."
  (cl-cm:encode (database-code-node db form)))

(defun database-code-cid (db form)
  "The CID DB assigns to FORM: CIDv1 of the resolved canonical node.

This is a pure computation -- it reads DB's identities but does not store
anything and does not force a load.  Call LOAD-DATABASE (or
ENSURE-DATABASE) first for the resolution to see the stored identities."
  (cl-cm:generate-block-cid (database-code-blob db form)))

;;; ------------------------------------------------------------------
;;; Object files (one per CID)
;;; ------------------------------------------------------------------
;;;
;;; Layout of an object file (all integers big-endian):
;;;
;;;   "CMOB"  4 bytes magic
;;;   1       version byte
;;;   u32     length of the CBOR blob
;;;   ...     the CBOR blob (canonical node)
;;;   u32     length of the UTF-8 source text
;;;   ...     the source text (original expression, printed readably)
;;;
;;; The CID is recovered from the blob on load; the source text is a
;;; convenience for humans and for `identity-code'.

(defparameter *object-magic* "CMOB"
  "Magic bytes at the start of every object file.")

(defparameter *object-version* 1
  "Current object-file container version.")

(defun write-u32 (stream value)
  (declare (type (unsigned-byte 32) value)
           (type stream stream))
  (dotimes (i 4)
    (write-byte (ldb (byte 8 (- 24 (* 8 i))) value) stream)))

(defun read-u32 (stream)
  (declare (type stream stream))
  (let ((value 0))
    (loop repeat 4
          do (setf value (logior (ash value 8) (read-byte stream))))
    value))

(defun write-object (path blob source-text)
  "Write BLOB and SOURCE-TEXT to the object file at PATH."
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output
                            :if-exists :supersede
                            :if-does-not-exist :create
                            :element-type '(unsigned-byte 8))
    (write-sequence (trivial-utf-8:string-to-utf-8-bytes *object-magic*) out)
    (write-byte *object-version* out)
    (write-u32 out (length blob))
    (write-sequence blob out)
    (let ((source (trivial-utf-8:string-to-utf-8-bytes source-text)))
      (write-u32 out (length source))
      (write-sequence source out))))

(defun read-object (path)
  "Read the object file at PATH.
Returns (values CBOR-BLOB SOURCE-TEXT), or NIL if PATH is not an object."
  (with-open-file (in path :direction :input :element-type '(unsigned-byte 8))
    (let ((magic (make-array 4 :element-type '(unsigned-byte 8))))
      (unless (= (read-sequence magic in) 4)
        (return-from read-object nil))
      (unless (string= (trivial-utf-8:utf-8-bytes-to-string magic)
                       *object-magic*)
        (return-from read-object nil))
      (unless (= (read-byte in) *object-version*)
        (error "~A: unsupported object version." path))
      (let* ((blob-length (read-u32 in))
             (blob (make-array blob-length :element-type '(unsigned-byte 8))))
        (unless (= (read-sequence blob in) blob-length)
          (error "~A: truncated object (blob)." path))
        (let* ((source-length (read-u32 in))
               (source (make-array source-length
                                   :element-type '(unsigned-byte 8))))
          (unless (= (read-sequence source in) source-length)
            (error "~A: truncated object (source)." path))
          (values blob
                  (trivial-utf-8:utf-8-bytes-to-string source)))))))

(defun object-path (db cid)
  "Pathname of the object file for CID inside DB's code store."
  (merge-pathnames cid (code-store-path db)))

(defun print-source (form)
  "Print FORM as a single readable s-expression."
  (let ((*print-readably* t)
        (*print-pretty* nil)
        (*print-circle* t))
    (prin1-to-string form)))

(defun parse-source (text)
  "Read back a printed source expression.
Falls back to returning TEXT itself when it cannot be read (e.g. the
package a stored symbol belongs to is not currently loaded)."
  (handler-case
      (let ((*read-eval* nil))
        (read-from-string text))
    (error (condition)
      (warn "Could not read stored source (~A); keeping it as a string." condition)
      text)))

;;; ------------------------------------------------------------------
;;; Storing code
;;; ------------------------------------------------------------------

(defun hash-present-p (key table)
  (nth-value 1 (gethash key table)))

(defun store-code (db form)
  "Store FORM in DB's code store and return its CID.

The CID is computed with DB as the reference resolver (recursive content
addressing); the object file records both the CBOR blob and the printed
source.  Storing an already-known CID is a no-op.  If DB has not been
loaded, its identities are loaded first so resolution is correct."
  (ensure-database db)
  (let* ((blob (database-code-blob db form))
         (cid (cl-cm:generate-block-cid blob)))
    (unless (hash-present-p cid (database-code db))
      (write-object (object-path db cid) blob (print-source form))
      (setf (gethash cid (database-code db))
            (make-code-entry form)))
    cid))

;;; ------------------------------------------------------------------
;;; The identity log
;;; ------------------------------------------------------------------

(defun append-identity-record (db op key cid)
  "Append one `(OP <timestamp> KEY CID)' record to DB's identity log."
  (let ((path (identity-log-path db)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output
                              :if-exists :append
                              :if-does-not-exist :create)
      (let ((*print-readably* t)
            (*print-pretty* nil))
        (format out "(~S ~S ~S ~S)~%"
                op
                (simplify-string (timestamp-string))
                (simplify-string key)
                (simplify-string cid))))))

(defun apply-identity-record (db record)
  "Fold one identity-log RECORD into DB's in-memory identity table."
  (unless (and (consp record)
               (member (first record) '(:define :set))
               (stringp (third record))
               (stringp (fourth record)))
    (warn "Ignoring malformed identity-log record: ~S" record)
    (return-from apply-identity-record nil))
  (setf (gethash (third record) (database-identities db)) (fourth record)))

(defun read-identity-log (db)
  "Read DB's whole identity log, latest record per key winning."
  (let ((path (identity-log-path db)))
    (when (probe-file path)
      (with-open-file (in path :direction :input)
        (let ((*read-eval* nil))
          (loop for record = (read in nil :eof)
                until (eq record :eof)
                do (apply-identity-record db record)))))))

(defun load-object-file (db file)
  "Read one object FILE into DB's in-memory code table."
  (multiple-value-bind (blob source-text) (read-object file)
    (when blob
      (let ((cid (cl-cm:generate-block-cid blob)))
        (setf (gethash cid (database-code db))
              (make-code-entry (parse-source source-text)))))))

(defun read-code-store (db)
  "Read every object file in DB's code store into memory."
  (let ((directory (code-store-path db)))
    (when (uiop:directory-exists-p directory)
      (dolist (file (uiop:directory-files directory))
        (load-object-file db file)))))

(defun load-database (db)
  "Load DB's identity log and code store into memory, replacing any
cached state.  Idempotent; returns DB."
  (clrhash (database-identities db))
  (clrhash (database-code db))
  (read-identity-log db)
  (read-code-store db)
  (setf (database-loaded-p db) t)
  db)

(defun ensure-database (db)
  "Load DB if it has not been loaded yet; returns DB."
  (unless (database-loaded-p db)
    (load-database db))
  db)

;;; ------------------------------------------------------------------
;;; Defining and changing identities
;;; ------------------------------------------------------------------

(defun %set-identity (db identity form op)
  (let* ((key (identity-key identity))
         (cid (store-code db form)))
    (append-identity-record db op key cid)
    (setf (gethash key (database-identities db)) cid)
    cid))

(defun defidentity (db identity form)
  "Associate IDENTITY with the code of FORM in DB and return the CID.

DB comes first because it defines the environment: FORM is resolved
against DB's identities, so the database is what gives the stored CID its
meaning.  IDENTITY is a symbol (or a string key); FORM is the source
expression to store.  The code is stored in DB's code store and a
`:define' record is appended to its identity log.  Signals an error when
IDENTITY is already defined -- use SETIDENTITY to change an existing
identity.

Note that a definition's CID depends only on the identities that exist
at the moment it is defined: a free reference to a not-yet-defined name
is hashed by name, and defining that name later does not retroactively
change this CID."
  (ensure-database db)
  (let ((key (identity-key identity)))
    (when (hash-present-p key (database-identities db))
      (error "Identity ~A is already defined; use SETIDENTITY to change it."
             key))
    (%set-identity db identity form :define)))

(defun setidentity (db identity form)
  "Change the code associated with the existing IDENTITY in DB.

Like DEFIDENTITY, DB comes first because it defines the environment.
Requires IDENTITY to already exist and appends a `:set' record to the
log.  Returns the new CID."
  (ensure-database db)
  (let ((key (identity-key identity)))
    (unless (hash-present-p key (database-identities db))
      (error "Identity ~A is not defined; use DEFIDENTITY to define it."
             key))
    (%set-identity db identity form :set)))

(defmacro defun-identity (name db lambda-list &body body)
  "Define NAME as a function and register it as an identity in DB.

This is the convenient form of DEFIDENTITY: NAME goes first, like DEFUN,
and the identity is registered under the same name, so the function and
its content-addressed definition stay in step:

  (defun-identity fact db (n) (factorial n))

is equivalent to

  (defun fact (n) (factorial n))
  (defidentity db 'fact '(lambda (n) (factorial n)))

Signals an error when the identity already exists -- use SETF-IDENTITY
to change it.  Returns the CID."
  `(progn
     (defun ,name ,lambda-list ,@body)
     (defidentity ,db ',name '(lambda ,lambda-list ,@body))))

(defmacro setf-identity (name db lambda-list &body body)
  "Redefine NAME as a function and update its identity in DB.

Like DEFUN-IDENTITY, but requires the identity to already exist and
appends a `:set' record to the log:

  (setf-identity fact db (n) (factorial n))

is equivalent to

  (defun fact (n) (factorial n))
  (setidentity db 'fact '(lambda (n) (factorial n)))

Returns the new CID."
  `(progn
     (defun ,name ,lambda-list ,@body)
     (setidentity ,db ',name '(lambda ,lambda-list ,@body))))

(defun identity-cid (identity db)
  "Current CID of IDENTITY in DB, or NIL when it is not defined."
  (ensure-database db)
  (gethash (identity-key identity) (database-identities db)))

(defun identity-code (identity db)
  "The source expression stored for IDENTITY in DB, or NIL when unknown.

Returns NIL both when IDENTITY is undefined and when its stored code is
literally NIL; use IDENTITY-CID to tell the two apart."
  (let ((cid (identity-cid identity db)))
    (and cid
         (code-entry-source (gethash cid (database-code db))))))
