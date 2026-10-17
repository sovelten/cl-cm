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
   (functions :initform (make-hash-table :test #'equal)
              :accessor database-functions
              :documentation "In-memory CID (string) -> compiled function
cache.  Compiled code is transient: it is rebuilt from the stored source
on demand and is not persisted.")
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

(defun init-database (&key (directory #p"./") (name "cl-cm-db")
                           identity-log code-store)
  "Open the code database under DIRECTORY, creating it when it is absent.

This is MAKE-DATABASE followed by LOAD-DATABASE, i.e. create new or load
existing: if an identity log or code store already lives under DIRECTORY
it is read into memory, and otherwise DIRECTORY simply holds a fresh,
empty database that is ready to use.  The identity log is
DIRECTORY/NAME.identities and the code store is the directory
DIRECTORY/NAME.objects/; IDENTITY-LOG and CODE-STORE override those
defaults when supplied.

Returns (values DATABASE EXISTED-P), where EXISTED-P is true when a
database was already present on disk."
  (let ((db (make-database :directory directory :name name
                           :identity-log identity-log
                           :code-store code-store)))
    (let ((existed-p (or (and (identity-log-path db)
                              (probe-file (identity-log-path db)))
                         (uiop:directory-exists-p (code-store-path db)))))
      (load-database db)
      (values db (and existed-p t)))))

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

(defun append-identity-record (db op key &optional cid)
  "Append one identity-log record to DB's identity log.

For `:define' and `:set', CID is required and the record is
`(OP <timestamp> KEY CID)'.  For `:retract' the record is
`(OP <timestamp> KEY)'."
  (let ((path (identity-log-path db)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output
                              :if-exists :append
                              :if-does-not-exist :create)
      (let ((*print-readably* t)
            (*print-pretty* nil))
        (if cid
            (format out "(~S ~S ~S ~S)~%"
                    op
                    (simplify-string (timestamp-string))
                    (simplify-string key)
                    (simplify-string cid))
            (format out "(~S ~S ~S)~%"
                    op
                    (simplify-string (timestamp-string))
                    (simplify-string key)))))))

(defun fold-identity-record (identities record)
  "Fold one identity-log RECORD into the IDENTITIES hash table.

A `:define' or `:set' record associates the key with its CID; a
`:retract' record removes the key.  Malformed records are ignored with a
warning.  This is the pure part of APPLY-IDENTITY-RECORD, shared with the
log replay that reconstructs a historical identity table."
  (unless (and (consp record)
               (member (first record) '(:define :set :retract))
               (stringp (third record)))
    (warn "Ignoring malformed identity-log record: ~S" record)
    (return-from fold-identity-record nil))
  (cond ((eq (first record) :retract)
         (remhash (third record) identities))
        ((stringp (fourth record))
         (setf (gethash (third record) identities) (fourth record)))
        (t
         (warn "Ignoring malformed identity-log record: ~S" record)))
  nil)

(defun apply-identity-record (db record)
  "Fold one identity-log RECORD into DB's in-memory identity table."
  (fold-identity-record (database-identities db) record))

(defun read-identity-records (db)
  "Return DB's whole identity log as a list of records, in file order.

Returns NIL when the log does not exist yet."
  (let ((path (identity-log-path db)))
    (when (probe-file path)
      (with-open-file (in path :direction :input)
        (let ((*read-eval* nil))
          (loop for record = (read in nil :eof)
                until (eq record :eof)
                collect record))))))

(defun read-identity-log (db)
  "Read DB's whole identity log, latest record per key winning."
  (dolist (record (read-identity-records db))
    (apply-identity-record db record)))

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
  (clrhash (database-functions db))
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

(defun retractidentity (db identity)
  "Retract IDENTITY from DB, appending a `:retract' record to its log.

DB comes first, like DEFIDENTITY and SETIDENTITY.  IDENTITY must be
currently defined; signals an error otherwise.  The key is removed from
the current identities and the CID it had is returned.  The object file
is left untouched -- call CLEAN-DATABASE to reap it once it is no longer
referenced."
  (ensure-database db)
  (let* ((key (identity-key identity))
         (cid (gethash key (database-identities db))))
    (unless cid
      (error "Identity ~A is not defined; cannot retract it." key))
    (append-identity-record db :retract key)
    (remhash key (database-identities db))
    cid))

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

(defun code-by-cid (db cid)
  "The source expression stored for CID in DB, or NIL when unsupported.

Unlike IDENTITY-CODE, this does not go through a name: it addresses the
code itself, so it still works for a CID that no current identity names
(a superseded version, or code stored with STORE-CODE).  This is what
lets a caller pinned to an old CID keep running after a reload."
  (ensure-database db)
  (let ((entry (gethash cid (database-code db))))
    (and entry (code-entry-source entry))))

;;; ------------------------------------------------------------------
;;; References and compiled code
;;; ------------------------------------------------------------------
;;;
;;; A definition's free function references were resolved to CIDs when
;;; its CID was computed.  Because the identity log is replayable, that
;;; resolution can be recovered afterwards -- so a stored definition's
;;; references stay meaningful even after the names it mentions have been
;;; redefined.  CODE-FUNCTION then compiles the source with those
;;; references wired to the compiled function of the referenced CID,
;;; which is what makes recursive content addressing executable: a
;;; compiled caller keeps reaching the versions it was compiled against.
;;;
;;; Compiled functions are transient (cached per database and CID) and are
;;; rebuilt from source on demand; nothing about them is persisted.

(defun identities-before-cid (db cid)
  "The identity table as it was when CID was first stored.

The identity log is replayed up to the first record mentioning CID, so
those are exactly the identities CL-CM resolved against when it computed
CID."
  (let ((identities (make-hash-table :test #'equal)))
    (dolist (record (read-identity-records db) identities)
      (when (and (member (first record) '(:define :set))
                 (stringp (fourth record))
                 (string= (fourth record) cid))
        (return identities))
      (fold-identity-record identities record))))

(defun references-in (identities source)
  "Resolve SOURCE's free references against the IDENTITIES table.
Returns (values REFERENCES UNRESOLVED): REFERENCES is a sorted alist
(SYMBOL . CID) of free *function* references that named an identity, and
UNRESOLVED is the sorted list of free function symbols that did not."
  (let ((references '())
        (free '()))
    (let ((cl-cm:*reference-resolver*
            (lambda (namespace symbol)
              (let ((cid (gethash (identity-key symbol) identities)))
                (when (eq namespace :function)
                  (pushnew symbol free)
                  (when cid
                    (pushnew (cons symbol cid) references :key #'car)))
                cid))))
      (cl-cm:normalize-code source))
    (values (sort references #'string< :key (lambda (pair) (symbol-name (car pair))))
            (sort (set-difference free (mapcar #'car references))
                  #'string< :key #'symbol-name))))

(defun source-references (db source)
  "References of SOURCE against DB's *current* identities.

Suitable before storing SOURCE, e.g. to reject unresolvable references:
returns (values REFERENCES UNRESOLVED) like CODE-REFERENCES."
  (ensure-database db)
  (references-in (database-identities db) source))

(defun code-references (db cid)
  "References the code stored as CID was resolved with.

Resolved against the identity table as it was when CID was stored, not the
current one, so a definition's references do not drift when the names it
mentions are redefined.  Returns (values REFERENCES UNRESOLVED)."
  (ensure-database db)
  (let ((source (code-by-cid db cid)))
    (unless source
      (error "No code is stored for CID ~A." cid))
    (references-in (identities-before-cid db cid) source)))

(defun code-function (db cid)
  "The compiled function of the code stored as CID, compiling it on first use.

The source must be a lambda form.  Its free function references are wired,
at compile time, to a call-time lookup of the compiled function of the
referenced CID, so an already-compiled caller keeps reaching the versions
it was compiled against even when a callee is redefined.  The compiled
function is cached per database and CID; two names for the same code share
one function."
  (ensure-database db)
  (or (gethash cid (database-functions db))
      (let ((source (code-by-cid db cid)))
        (unless (and (consp source) (eq (first source) 'lambda))
          (error "Code ~A is not a lambda form and cannot be compiled." cid))
        (multiple-value-bind (references unresolved) (code-references db cid)
          (declare (ignore unresolved))
          (let* ((lambda-list (second source))
                 (body (cddr source))
                 (names (mapcar #'car references))
                 (rest (gensym "REST-"))
                 ;; A referenced name may be a symbol of a locked package
                 ;; (GET, REMOVE, ...).  Binding it with FLET is exactly how
                 ;; the reference is pinned to a CID; lift the lock for
                 ;; those names in this compilation unit (SBCL only).
                 (declarations
                   #+sbcl (when references
                            `((declare (sb-ext:disable-package-locks ,@names))))
                   #-sbcl nil)
                 (wired
                   (if references
                       `(flet (,@(loop for (name . ref-cid) in references
                                       collect `(,name (&rest ,rest)
                                                 (apply (code-function ,db ,ref-cid)
                                                        ,rest))))
                          (function (lambda ,lambda-list ,@body)))
                       `(function (lambda ,lambda-list ,@body))))
                 (function
                   (funcall (compile nil `(lambda () ,@declarations ,wired)))))
            (setf (gethash cid (database-functions db)) function)
            function)))))

(defun identity-function (identity db)
  "The compiled function of the code currently bound to IDENTITY, or NIL."
  (let ((cid (identity-cid identity db)))
    (and cid (code-function db cid))))

(defun call-identity (identity db &rest arguments)
  "Call IDENTITY's current code against ARGUMENTS, compiled through DB.
Returns whatever the code returns (including multiple values).  Signals an
error when IDENTITY is not defined."
  (let ((function (identity-function identity db)))
    (unless function
      (error "Identity ~A is not defined." (identity-key identity)))
    (apply function arguments)))

;;; ------------------------------------------------------------------
;;; Definitions and reverse lookups
;;; ------------------------------------------------------------------
;;;
;;; A CODE-DEFINITION bundles a CID with the source form stored for it, so
;;; callers do not have to pair CODE-BY-CID with the source accessors
;;; themselves.  The identity table is queried in both directions: a
;;; definition by name, and the names a CID is currently bound to.

(defstruct (code-definition (:constructor %make-code-definition (cid source)))
  "One stored definition: its CID and the source form.
Use CODE-DEFINITION-LAMBDA-LIST and CODE-DEFINITION-BODY to split a
`(lambda ...)' source."
  cid
  source)

(defun code-definition-lambda-list (definition)
  "The lambda list of DEFINITION's `(lambda ...)' source."
  (second (code-definition-source definition)))

(defun code-definition-body (definition)
  "The body forms of DEFINITION's `(lambda ...)' source."
  (cddr (code-definition-source definition)))

(defun definition-by-cid (db cid)
  "The CODE-DEFINITION stored as CID, or NIL.
NIL when CID is unknown, or when its source is not a lambda form."
  (let ((source (code-by-cid db cid)))
    (when (and (consp source) (eq (first source) 'lambda))
      (%make-code-definition cid source))))

(defun definition-by-identity (identity db)
  "The CODE-DEFINITION currently bound to IDENTITY, or NIL."
  (let ((cid (identity-cid identity db)))
    (and cid (definition-by-cid db cid))))

(defun identity-symbol (key)
  "The symbol an identity KEY names, or NIL when its package is absent.

Identity keys are strings (`PKG::NAME', or `#::NAME' for an uninterned
symbol) so they can be read back without the packages that produced them.
This turns one back into a symbol when that package exists in the image."
  (let ((separator (search "::" key :from-end t)))
    (when separator
      (let ((package-name (subseq key 0 separator))
            (symbol-name (subseq key (+ separator 2))))
        (cond
          ((string= package-name "#") (make-symbol symbol-name))
          (t
           (let ((package (find-package package-name)))
             (when package
               (multiple-value-bind (symbol status)
                   (find-symbol symbol-name package)
                 (if (and symbol (member status '(:internal :external)))
                     symbol
                     (make-symbol symbol-name)))))))))))

(defun identity-names-for-cid (db cid)
  "The identity keys currently bound to CID in DB, sorted."
  (ensure-database db)
  (let ((names '()))
    (maphash (lambda (key value)
               (when (string= value cid)
                 (push key names)))
             (database-identities db))
    (sort names #'string<)))

(defun identity-history (identity db)
  "The CIDs IDENTITY has been bound to in DB, newest first."
  (let ((key (identity-key identity)))
    (remove-duplicates
     (loop for record in (reverse (read-identity-records db))
           when (and (consp record)
                     (member (first record) '(:define :set))
                     (string= (third record) key)
                     (stringp (fourth record)))
             collect (fourth record))
     :test #'string=)))

(defun code-referrers (db cid)
  "The identity keys whose current definition references CID.
Based on CIDs, so it is naming-independent: renaming a referrer does not
change the answer."
  (ensure-database db)
  (let ((out '()))
    (maphash (lambda (key bound-cid)
               (when (find cid (code-references db bound-cid)
                           :test #'string= :key #'cdr)
                 (push key out)))
             (database-identities db))
    (sort (remove-duplicates out) #'string<)))

;;; ------------------------------------------------------------------
;;; Whole-database helpers
;;; ------------------------------------------------------------------

(defun ensure-identity (db identity form)
  "Define IDENTITY with FORM, or change its code to FORM when it exists.
This is the upsert of DEFIDENTITY and SETIDENTITY: a new identity gets a
`:define' record, an existing one a `:set' record.  Re-storing the same
content is a no-op (no log record), since the CID is unchanged.  Returns
the CID."
  (ensure-database db)
  (let ((current (gethash (identity-key identity) (database-identities db))))
    (cond ((null current)
           (defidentity db identity form))
          ((string= current (database-code-cid db form))
           current)
          (t
           (setidentity db identity form)))))

(defun code-count (db)
  "Number of distinct definitions (CIDs) stored in DB."
  (ensure-database db)
  (hash-table-count (database-code db)))

(defun map-definitions (function db)
  "Call FUNCTION with each CODE-DEFINITION in DB, in CID order.  Returns DB."
  (ensure-database db)
  (let ((cids '()))
    (maphash (lambda (cid entry)
               (declare (ignore entry))
               (push cid cids))
             (database-code db))
    (dolist (cid (sort cids #'string<))
      (let ((definition (definition-by-cid db cid)))
        (when definition
          (funcall function definition)))))
  db)

(defun clean-database (db &key (mode :shallow) dry-run)
  "Remove object files from DB's code store that are no longer needed.

MODE selects how much history is kept:

  :shallow (the default)
      Keep every object whose CID appears anywhere in the identity log
      -- including CIDs from superseded `:define'/`:set' records -- and
      delete the rest.  The log itself is left exactly as it is, so old
      identities remain re-derivable.

  :deep
      Compact the identity log down to the current identities (the last
      record for each key, dropping retracted keys), then delete every
      object whose CID is not referenced by those current identities.
      Superseded history is discarded.

When DRY-RUN is true nothing is deleted and the log is not rewritten;
the return value still reports what would happen.

Returns a plist (:MODE MODE :KEPT KEPT :REMOVED REMOVED :FREED-BYTES N)."
  (ensure-database db)
  (labels ((current-records (records)
             "Latest non-retract record per key, in first-appearance order."
             (let ((last (make-hash-table :test #'equal))
                   (order '()))
               (dolist (record records)
                 (when (and (consp record)
                            (stringp (third record))
                            (member (first record) '(:define :set :retract)))
                   (let ((key (third record)))
                     (unless (nth-value 1 (gethash key last))
                       (push key order))
                     (setf (gethash key last) record))))
               (loop for key in (nreverse order)
                     for record = (gethash key last)
                     when (member (first record) '(:define :set))
                       collect record)))
           (log-cids (records)
             "Every distinct CID mentioned by a :define/:set record."
             (remove-duplicates
              (loop for record in records
                    when (and (consp record)
                              (member (first record) '(:define :set))
                              (stringp (fourth record)))
                      collect (fourth record))
              :test #'string=))
           (write-log (records)
             (let* ((path (identity-log-path db))
                    (tmp (merge-pathnames
                          (format nil "~A.tmp" (pathname-name path))
                          path)))
               (ensure-directories-exist path)
               (with-open-file (out tmp :direction :output
                                        :if-exists :supersede
                                        :if-does-not-exist :create)
                 (let ((*print-readably* t)
                       (*print-pretty* nil))
                   (dolist (record records)
                     (format out "~S~%" record))))
               (uiop:rename-file-overwriting-target tmp path))))
    (let* ((records (read-identity-records db))
           (compacted (ecase mode
                        (:shallow nil)
                        (:deep (current-records records))))
           (referenced (ecase mode
                         (:shallow (log-cids records))
                         (:deep (log-cids compacted)))))
      (when (and (eq mode :deep) (not dry-run))
        (write-log compacted)
        (clrhash (database-identities db))
        (read-identity-log db))
      (let ((keep (make-hash-table :test #'equal))
            (kept 0) (removed 0) (freed 0))
        (dolist (cid referenced)
          (setf (gethash cid keep) t))
        (when (uiop:directory-exists-p (code-store-path db))
          (dolist (file (uiop:directory-files (code-store-path db)))
            (let ((cid (file-namestring file)))
              (if (gethash cid keep)
                  (incf kept)
                  (progn
                    (incf removed)
                    (incf freed
                          (or (ignore-errors
                                (with-open-file (in file
                                                    :element-type '(unsigned-byte 8))
                                  (file-length in)))
                              0))
                    (unless dry-run
                      (ignore-errors (delete-file file))
                      (remhash cid (database-code db))
                      (remhash cid (database-functions db))))))))
        (list :mode mode :kept kept :removed removed :freed-bytes freed)))))
