;;;; dasl.lisp --- DASL/CBOR encoder and CID generation
;;;;
;;;; The code in this file is moved/adapted from cl-dasl, an MIT-licensed
;;;; DASL implementation:
;;;;
;;;;   cl-dasl --- DASL encoder/decoder
;;;;   Author:  Mihai Bazon <mihai.bazon@gmail.com> and Tomohiko Morioka
;;;;   License: MIT
;;;;
;;;; cl-dasl is itself based on the CBOR encoder/decoder for Common Lisp
;;;; (cbor.lisp) by Mihai Bazon <mihai.bazon@gmail.com>.
;;;;
;;;; Only the parts cl-cm actually needs are kept: encoding of the value
;;;; types that occur in cl-cm's canonical nodes (vectors, strings,
;;;; integers, floats, ratios, complex numbers and NIL) together with the
;;;; computation of a CIDv1 (dag-cbor, sha2-256, base32).  The decoder,
;;;; stringrefs, sharedrefs, the symbol/character/cons/CLOS encoders and
;;;; the CID converters are intentionally omitted.
;;;;
;;;; The encoder is kept byte-for-byte compatible with cl-dasl's
;;;; `dasl:generate-cid' so that existing content identifiers are stable.

(in-package #:cl-cm)

;;; ------------------------------------------------------------------
;;; Shared settings and tags (from cl-dasl.lisp)
;;; ------------------------------------------------------------------

(eval-when (:compile-toplevel :load-toplevel :execute)
  (deftype raw-data () '(simple-array (unsigned-byte 8) 1))
  (defparameter *optimize* '(optimize speed (safety 1) (space 0) (debug 0)))
  (defparameter *max-uint64* (1- (expt 2 64)))
  (defparameter *min-uint64* (- (expt 2 64))))

(defconstant +tag-positive-bignum+ 2)
(defconstant +tag-negative-bignum+ 3)
(defconstant +tag-ratio+ 30)
(defconstant +tag-complex+ 43000)

;; Float converters: 16-bit is generated here (ieee-floats has no 16-bit
;; converters); 32/64-bit come from ieee-floats directly.
(declaim (inline encode-float16 decode-float16))
(ieee-floats:make-float-converters encode-float16 decode-float16 5 10 nil)

;;; ------------------------------------------------------------------
;;; Errors (from errors.lisp)
;;; ------------------------------------------------------------------

(define-condition cbor-error (error)
  ((text :initarg :text :reader error-text)
   (stream :initarg :stream :reader error-stream)
   (position :initarg :position :reader error-position))
  (:report (lambda (condition out)
             (write-string (error-text condition) out))))

(define-condition cbor-encode-error (cbor-error)
  ())

(defmacro encode-error ((text &rest format-args) &optional stream position)
  `(error 'cbor-encode-error
          :text (funcall #'format nil ,text ,@format-args)
          :stream ,stream
          :position ,(or position (if stream `(ms-position ,stream)))))

;;; ------------------------------------------------------------------
;;; In-memory output stream (from memstream.lisp)
;;; ------------------------------------------------------------------

(declaim (type fixnum *buffer-size*))
(defparameter *buffer-size* (* 64 1024))

(defstruct (memstream
            (:constructor %make-memstream)
            (:conc-name ms-))
  (data (make-array *buffer-size* :element-type '(unsigned-byte 8))
   :type raw-data)
  (position 0 :type (integer 0 #.array-total-size-limit))
  (size 0 :type (integer 0 #.array-total-size-limit)))

(defmacro with-stream-slots (stream &body body)
  `(symbol-macrolet
       ((data (ms-data ,stream))
        (size (ms-size ,stream))
        (position (ms-position ,stream)))
     ,@body))

(defun make-memstream (&optional data)
  (declare (type (or null raw-data) data))
  (if data
      (%make-memstream :data data
                       :position 0
                       :size (length data))
      (%make-memstream)))

(declaim (inline ms-extend-stream))
(defun ms-extend-stream (stream &optional (min-size 0))
  (declare (type memstream stream)
           (type (integer 0 #.array-total-size-limit) min-size)
           #.*optimize*)
  (with-stream-slots stream
    (let ((newdata (make-array (max min-size
                                    (min (* 2 (array-total-size data))
                                         array-total-size-limit))
                               :element-type '(unsigned-byte 8))))
      (replace newdata data)
      (setf data newdata))))

(declaim (inline ms-write-byte))
(defun ms-write-byte (byte stream)
  (declare (type memstream stream)
           (type (unsigned-byte 8) byte)
           #.*optimize*)
  (with-stream-slots stream
    (when (>= position (array-total-size data))
      (ms-extend-stream stream))
    (setf (aref data position) byte)
    (unless (< position size)
      (incf size))
    (incf position)))

(declaim (inline ms-write-sequence))
(defun ms-write-sequence (sequence stream &key (start 0) (end (length sequence)))
  (declare (type raw-data sequence)
           (type memstream stream)
           (type (integer 0 #.array-total-size-limit) start end)
           #.*optimize*)
  (with-stream-slots stream
    (let* ((count (- end start))
           (end1 (+ position count)))
      (when (> end1 (array-total-size data))
        (ms-extend-stream stream end1))
      (replace data sequence :start1 position :end1 end1
                             :start2 start :end2 end)
      (setf position end1)
      (when (> end1 size)
        (setf size end1))
      sequence)))

(defun ms-whole-data (stream)
  (declare (type memstream stream)
           #.*optimize*)
  (with-stream-slots stream
    (declare (type raw-data data))
    (subseq data 0 size)))

;;; ------------------------------------------------------------------
;;; CBOR encoder (from encode.lisp, trimmed)
;;; ------------------------------------------------------------------

(defun encode (value)
  "Encode VALUE into a fresh DASL/CBOR byte vector."
  (let ((output (make-memstream)))
    (%encode value output)
    (ms-whole-data output)))

(defun encode-false (output)
  (declare (type memstream output)
           #.*optimize*)
  (ms-write-byte 244 output))

(defun encode-true (output)
  (declare (type memstream output)
           #.*optimize*)
  (ms-write-byte 245 output))

(defun encode-null (output)
  (declare (type memstream output)
           #.*optimize*)
  (ms-write-byte 246 output))

(defmacro unroll-write-byte (size value output)
  `(progn
     ,@(loop for i from (* 8 (1- size)) downto 0 by 8
             collect `(ms-write-byte (ldb (byte 8 ,i) ,value) ,output))))

(defun write-tag (type argument output)
  (declare (type (unsigned-byte 3) type)
           (type (integer 0 #.*max-uint64*) argument)
           (type memstream output)
           #.*optimize*)
  (let ((tag (ash type 5)))
    (cond
      ((<= argument 23)
       (ms-write-byte (logior tag argument) output))
      ((<= argument #xFF)
       (ms-write-byte (logior tag 24) output)
       (unroll-write-byte 1 argument output))
      ((<= argument #xFFFF)
       (ms-write-byte (logior tag 25) output)
       (unroll-write-byte 2 argument output))
      ((<= argument #xFFFFFFFF)
       (ms-write-byte (logior tag 26) output)
       (unroll-write-byte 4 argument output))
      (t
       (ms-write-byte (logior tag 27) output)
       (unroll-write-byte 8 argument output)))))

(defun encode-positive-integer (value output)
  (declare (type (integer 0 #.*max-uint64*) value)
           (type memstream output)
           #.*optimize*)
  (write-tag 0 value output))

(defun encode-negative-integer (value output)
  (declare (type (integer #.*min-uint64* -1) value)
           (type memstream output)
           #.*optimize*)
  (write-tag 1 (1- (- value)) output))

(macrolet ((try (bytes encoder decoder)
             `(handler-case
                  (let ((v (,encoder value)))
                    (when (= value (,decoder v))
                      (ms-write-byte ,(logior #b11100000
                                              (ecase bytes
                                                (2 25)
                                                (4 26)
                                                (8 27)))
                                     output)
                      (unroll-write-byte ,bytes v output)
                      t))
                (error (c)
                  (declare (ignore c))
                  nil))))
  (defun encode-float (value output)
    (declare (type float value)
             (type memstream output)
             #.*optimize*)
    (or (try 2 encode-float16 decode-float16)
        (try 4 ieee-floats:encode-float32 ieee-floats:decode-float32)
        (try 8 ieee-floats:encode-float64 ieee-floats:decode-float64)
        (encode-error ("Can't encode float value: ~A" value)))))

(defun encode-ratio (ratio output)
  (declare (type rational ratio)
           (type memstream output)
           #.*optimize*)
  (write-tag 6 +tag-ratio+ output)
  (write-tag 4 2 output)                ; array of two values
  (%encode (numerator ratio) output)
  (%encode (denominator ratio) output))

(defun encode-complex (value output)
  (declare (type complex value)
           (type memstream output)
           #.*optimize*)
  (write-tag 6 +tag-complex+ output)
  (write-tag 4 2 output)                ; array of two values
  (%encode (realpart value) output)
  (%encode (imagpart value) output))

(defun encode-string (str output)
  (declare (type string str)
           (type memstream output)
           #.*optimize*)
  (let ((len (trivial-utf-8:utf-8-byte-length str)))
    (write-tag 3 len output)
    (ms-write-sequence (trivial-utf-8:string-to-utf-8-bytes str) output)))

(defun encode-array (value output)
  (declare (type array value)
           #.*optimize*)
  (write-tag 4 (length value) output)
  (loop for val across value do (%encode val output)))

(flet ((write-num (value output)
         (multiple-value-bind (size rem) (round (integer-length value) 8)
           (unless (zerop rem)
             (incf size))
           (write-tag 2 size output)
           (loop for i from 0 below size
                 for j from (* 8 (1- size)) downto 0 by 8
                 for byte = (ldb (byte 8 j) value)
                 do (ms-write-byte byte output)))))
  (defun encode-bignum (value output)
    (declare (type integer value)
             (type memstream output)
             #.*optimize*)
    (cond
      ((>= value 0)
       (write-tag 6 +tag-positive-bignum+ output)
       (write-num value output))
      (t
       (write-tag 6 +tag-negative-bignum+ output)
       (write-num (1- (- value)) output)))))

(defun %encode (value output)
  "Encode VALUE onto OUTPUT.  Covers exactly the value types that occur
in cl-cm's canonical nodes: NIL, T, integers, floats, ratios, complex
numbers, strings and (general) vectors."
  (declare (type memstream output)
           #.*optimize*)
  (cond
    ((or (eq value :t)
         (eq value :true))
     (setf value t))
    ((eq value :null)
     (setf value nil)))
  (case value
    ((t) (encode-true output))
    ((nil) (encode-null output))
    (otherwise
     (cond
       ((or (eq value :f)
            (eq value :false))
        (encode-false output))
       (t
        (etypecase value
          ((integer 0 #.*max-uint64*)
           (encode-positive-integer value output))
          ((integer #.*min-uint64* -1)
           (encode-negative-integer value output))
          (integer
           (encode-bignum value output))
          (float
           (encode-float value output))
          (ratio
           (encode-float (float value) output))
          (complex
           (encode-complex value output))
          (string
           (encode-string value output))
          (vector
           (encode-array value output)))))))
  output)

;;; ------------------------------------------------------------------
;;; Content identifiers (from cid.lisp)
;;; ------------------------------------------------------------------

(defun bytes-to-base32-with-no-padding (some-bytes)
  "Like bytes-to-base32, but return base32 string without padding"
  (let* ((word-count (ceiling (* 8 (length some-bytes)) 5))
         (base32-string (make-string word-count)))
    (dotimes (i word-count)
      (setf (aref base32-string i)
            (cl-base32::encode-word (cl-base32::read-word some-bytes i))))
    base32-string))

(defun generate-block-cid (block)
  (let ((cds (ironclad:digest-sequence :sha256 block)))
    (concatenate 'string
                 "b"
                 (bytes-to-base32-with-no-padding
                  (concatenate 'vector
                               `#(1 #x71 #x12 ,(length cds))
                               cds)))))

(defun generate-cid (data)
  "CIDv1 (dag-cbor, sha2-256, base32) of DATA's DASL/CBOR encoding."
  (generate-block-cid (encode data)))
