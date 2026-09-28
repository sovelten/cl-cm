# cl-cm — Content-Addressable Common Lisp code

A minimal proof of concept in the spirit of [Unison](https://unison-lang.org/):
give a piece of Common Lisp *code*, get back a content identifier that is
**invariant under renaming of bound variables** (alpha-equivalence).

It is a thin layer on top of [cl-dasl](../cl-dasl) (DASL / dag-cbor / CIDv1 /
sha2-256), which supplies the actual encoding and hashing.

## Idea

```
source form  ──normalize──▶  canonical tree  ──dasl:generate-cid──▶  CID
```

`cl-cm:normalize-code` walks a form with a lexical environment and rewrites it
into a canonical **vector tree**. Every *bound* identifier is replaced by an
integer derived from its binding position; every *free* identifier keeps its
package-qualified name (it refers to code defined elsewhere); quoted data is
left untouched.

Because ids are handed out in deterministic traversal order, two programs that
differ only in the *names* of their bound identifiers normalize to `EQUALP`
trees and therefore hash to the same CID.

```lisp
(cl-cm:code-cid '(lambda (n) (if (zerop n) 1 (* n (fact (1- n))))))
;; => "bafyreidpgybbqtezmhcvosmfpd35si4f4biixzbypv4kpzurrwavag5jwe"

(cl-cm:code-cid '(lambda (k) (if (zerop k) 1 (* k (fact (1- k))))))
;; => "bafyreidpgybbqtezmhcvosmfpd35si4f4biixzbypv4kpzurrwavag5jwe"   ; same!
```

## Usage

```lisp
(asdf:load-system :cl-cm)   ; requires cl-dasl on the ASDF source registry

(cl-cm:code-cid form)          ; -> CIDv1 string (dag-cbor, sha2-256, base32)
(cl-cm:same-code-p a b)        ; -> T when alpha-equivalent
(cl-cm:normalize-code form)    ; -> the canonical tree (for inspection)
(cl-cm:code-node form)         ; -> version-tagged tree that is actually hashed
```

Example canonical tree:

```lisp
(cl-cm:normalize-code '(lambda (x) (foo x)))
;; => #("lambda" #(0) #(#("call" #("gref" "COMMON-LISP-USER" "FOO") #(#("var" 0)))))
```

Here the parameter `x` became the id `0`, its use in the body is
`#("var" 0)`, and the free function `foo` keeps its name.

## How alpha-renaming works

* **Lisp-2 namespaces.** Variables, functions, blocks and tagbody-tags are
  separate alists in the environment, so `(flet ((x ...)) ...)` and a variable
  `x` never collide.
* **Deterministic ids.** Four counters (`*var-counter*` etc.) are reset for each
  top-level normalization and incremented as bindings are encountered. Same
  binding structure ⇒ same ids ⇒ same tree.
* **Shadows just work.** The environment is an alist pushed in front, so an
  inner binding shadows an outer one; `lookup-var` finds the innermost.
* **Quoted data is data.** `'foo` normalizes to `#("sym" "PKG" "FOO")` and is
  never renamed; `(list 'a 'b)` and `(list 'b 'a)` hash differently.

Recognized binding forms: `lambda`, `let`, `let*`, `flet`, `labels`,
`macrolet`, `symbol-macrolet`, `multiple-value-bind`, `destructuring-bind`,
`block`/`return-from`, `tagbody`/`go`, `dolist`, `dotimes`, `prog`, `prog*`,
plus `quote` and `function`. Everything else is treated as a function call and
walked generically.

## Extending

Any binding form `cl-cm` does not know about can be added without touching the
walker:

```lisp
(cl-cm:define-form my-with-thing (args env)
  ;; ARGS is the cdr of the form, ENV the lexical environment.
  (let* ((name (first args))
         (id (cl-cm:fresh-var-id)))
    (cl-cm:nv "my-with-thing" id (cl-cm:norm (rest args) (cl-cm:bind-var env name id)))))
```

## Limitations (it is a concept, after all)

* **Macros are not expanded.** Only the binding forms listed above are
  understood. A macro that introduces bindings (e.g. `loop`'s `for x` clauses,
  `with-open-file`, `with-slots`) will have its variables treated as *free*
  identifiers, so renaming them would change the hash. Register a handler (or
  macroexpand first) to cover these.
* **Global names are matched by name, not by CID.** Free identifiers keep their
  `package:name`; a real system would replace them with the CID of the
  definition they reference, giving true recursive content addressing.
* **`&key` semantics are honored.** `(lambda (&key y) ...)` and
  `(lambda (&key b) ...)` are *not* equivalent, because the accepted keyword
  `:y` vs `:b` is part of the interface. Explicit `((:y b) ...)` forms *are*
  equivalent across renames.
* **Reader conditionals / custom readtables** are whatever the host reader
  produced; `cl-cm` works on the resulting s-expressions.
* **Reader macros and `#.`** are not sandboxed; don't normalize untrusted text
  with `*read-eval*` enabled.

## Tests

```lisp
(asdf:test-system :cl-cm)     ; or:
(cl-cm-tests:run-self-test)
```

24 checks: renaming bound identifiers must not change the CID, and structural
differences (free names, binding order, string case, quoted data) must.

## License

MIT
