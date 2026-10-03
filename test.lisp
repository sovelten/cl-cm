;;;; test.lisp --- self tests for cl-cm
;;;;
;;;; Deliberately dependency-free (no test framework): run with
;;;;   (asdf:test-system :cl-cm)
;;;; or
;;;;   (cl-cm-tests:run-self-test)

(defpackage #:cl-cm-tests
  (:use #:cl)
  (:export #:run-self-test))

(in-package #:cl-cm-tests)

(defvar *checks* 0)
(defvar *failures* 0)

(defmacro check (label value)
  `(progn
     (incf *checks*)
     (unless ,value
       (incf *failures*)
       (format t "  FAIL: ~A~%" ,label))
     ,value))

(defun run-self-test ()
  (let ((*checks* 0)
        (*failures* 0))
    (format t "~&Running cl-cm self-tests...~%")

    (format t "~&  -- alpha-equivalence: renaming must not change the CID~%")
    (check "lambda"
      (cl-cm:same-code-p '(lambda (x) (foo x))
                       '(lambda (y) (foo y))))
    (check "lambda cid string identical"
      (string= (cl-cm:code-cid '(lambda (x) (foo x)))
               (cl-cm:code-cid '(lambda (y) (foo y)))))
    (check "let"
      (cl-cm:same-code-p '(let ((x 1) (y 2)) (+ x y))
                       '(let ((a 1) (b 2)) (+ a b))))
    (check "let (no init) == let (init nil)"
      (cl-cm:same-code-p '(let ((x)) x)
                       '(let ((x nil)) x)))
    (check "let* sequential"
      (cl-cm:same-code-p '(let* ((x 1) (y (+ x 1))) (list x y))
                       '(let* ((a 1) (b (+ a 1))) (list a b))))
    (check "shadowing"
      (cl-cm:same-code-p '(let ((x 1)) (let ((x 2)) x))
                       '(let ((a 1)) (let ((b 2)) b))))
    (check "labels recursion"
      (cl-cm:same-code-p '(labels ((f (n) (if (zerop n) 1 (* n (f (1- n)))))) (f 5))
                       '(labels ((g (k) (if (zerop k) 1 (* k (g (1- k)))))) (g 5))))
    (check "flet separate namespaces"
      (cl-cm:same-code-p '(flet ((f (x) (g x))) (f 1))
                       '(flet ((h (y) (g y))) (h 1))))
    (check "block / return-from"
      (cl-cm:same-code-p '(block done (return-from done 1))
                       '(block stop (return-from stop 1))))
    (check "tagbody / go"
      (cl-cm:same-code-p '(tagbody top (go top))
                       '(tagbody again (go again))))
    (check "tagbody / go (loop counter)"
      (cl-cm:same-code-p '(let ((i 0)) (tagbody top (incf i) (go top)))
                       '(let ((j 0)) (tagbody again (incf j) (go again)))))
    (check "multiple-value-bind"
      (cl-cm:same-code-p '(multiple-value-bind (a b) (foo) (list a b))
                       '(multiple-value-bind (x y) (foo) (list x y))))
    (check "destructuring-bind"
      (cl-cm:same-code-p '(destructuring-bind (a &optional (b 2)) x (list a b))
                       '(destructuring-bind (p &optional (q 2)) x (list p q))))
    (check "dolist with result form"
      (cl-cm:same-code-p '(dolist (x lst x) (print x))
                       '(dolist (y lst y) (print y))))
    (check "dotimes"
      (cl-cm:same-code-p '(dotimes (i 10 i) (print i))
                       '(dotimes (n 10 n) (print n))))
    (check "prog"
      (cl-cm:same-code-p '(prog ((x 1)) (go out) out (return x))
                       '(prog ((y 1)) (go end) end (return y))))
    (check "&optional / &key explicit keyword"
      (cl-cm:same-code-p '(lambda (&key ((:y b) b)) b)
                       '(lambda (&key ((:y c) c)) c)))

    (format t "~&  -- distinct structure must change the CID~%")
    (check "different free function"
      (not (cl-cm:same-code-p '(lambda (x) (foo x))
                            '(lambda (x) (bar x)))))
    (check "different binding order (semantics differ)"
      (not (cl-cm:same-code-p '(let ((x 1) (y 2)) (list x y))
                            '(let ((x 2) (y 1)) (list x y)))))
    (check "free variable captured vs shadowed"
      (not (cl-cm:same-code-p '(lambda (x) (lambda (y) (list x y)))
                            '(lambda (x) (lambda (x) (list x x))))))
    (check "quoted symbols are data"
      (not (cl-cm:same-code-p '(list 'a 'b) '(list 'b 'a))))
    (check "string literal is not a vector of characters"
      (not (cl-cm:same-code-p '(f "abc") '(f #(#\a #\b #\c)))))
    (check "string case matters"
      (not (cl-cm:same-code-p '(f "Foo") '(f "foo"))))
    (check "&key implicit keyword is part of the interface"
      (not (cl-cm:same-code-p '(lambda (&key y) y)
                            '(lambda (&key b) b))))

    (format t "~&  -- global references resolved to content ids~%")
    (flet ((resolve-as (table)
             (lambda (namespace symbol)
               (when (eq namespace :function)
                 (cdr (assoc (symbol-name symbol) table :test #'string=))))))
      (let ((r (resolve-as '(("FOO" . "cid-foo") ("BAR" . "cid-foo")))))
        ;; A resolved reference is not the same as an unresolved (named) one.
        (check "resolved reference differs from named reference"
          (not (string= (cl-cm:code-cid-with-resolver '(lambda (x) (foo x)) r)
                        (cl-cm:code-cid '(lambda (x) (foo x))))))
        ;; Two different *names* bound to the *same* CID hash identically:
        ;; references are by content, not by name.
        (check "different names, same resolved cid"
          (string= (cl-cm:code-cid-with-resolver '(lambda (x) (foo x)) r)
                   (cl-cm:code-cid-with-resolver '(lambda (x) (bar x)) r)))
        ;; Changing the CID a name resolves to changes the referrer's CID.
        (check "changing the referenced cid changes the referrer"
          (not (string= (cl-cm:code-cid-with-resolver '(lambda (x) (foo x)) r)
                        (cl-cm:code-cid-with-resolver
                         '(lambda (x) (foo x))
                         (resolve-as '(("FOO" . "cid-other"))))))))
      (let ((anything (lambda (namespace symbol)
                        (declare (ignore namespace symbol))
                        "always-a-cid")))
        ;; Bound identifiers shadow: the resolver is never consulted for them,
        ;; so a fully-bound form hashes exactly as it does without a resolver.
        (check "bound identifiers are not resolved"
          (string= (cl-cm:code-cid-with-resolver '(lambda (x) x) anything)
                   (cl-cm:code-cid '(lambda (x) x))))
        ;; Quoted data is data: symbols inside QUOTE are never resolved.
        (check "quoted symbols are not resolved"
          (string= (cl-cm:code-cid-with-resolver '(quote (a b c)) anything)
                   (cl-cm:code-cid '(quote (a b c)))))))

    (format t "~&~D checks, ~D failure~:P.~%" *checks* *failures*)
    (zerop *failures*)))
