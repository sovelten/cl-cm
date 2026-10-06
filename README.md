# cl-cm — Content-Addressable Common Lisp code

A minimal proof of concept in the spirit of [Unison](https://unison-lang.org/):
give a piece of Common Lisp *code*, get back a content identifier that is
**invariant under renaming of bound variables** (alpha-equivalence).

Its DASL/CBOR encoding and CIDv1 generation (dag-cbor / sha2-256 / base32) are
self-contained: the encoder was moved from [cl-dasl](../cl-dasl) into
`dasl.lisp`, so cl-cm no longer depends on cl-dasl.

## Idea

```
source form  ──normalize──▶  canonical tree  ──encode + CID──▶  CID
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
(asdf:load-system :cl-cm)

(cl-cm:code-cid form)          ; -> CIDv1 string (dag-cbor, sha2-256, base32)
(cl-cm:code-cid-with-resolver form resolver) ; -> CID with free refs by content
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

## Content-addressed references (recursive hashing)

By default a *free* identifier keeps its `package:name`, so two forms that
reference different names (or the same name defined differently elsewhere)
hash differently. Bind `*reference-resolver*` — or call
`code-cid-with-resolver` — to replace a free identifier with the **CID of the
definition it refers to**:

```lisp
(cl-cm:code-cid-with-resolver
 '(lambda (x) (foo x))
 (lambda (namespace symbol)
   (when (and (eq namespace :function) (string= (symbol-name symbol) "FOO"))
     "bafyreia...")))            ; the CID of FOO's definition
;; => a CID that depends on FOO's definition, not on the name "FOO"
```

A resolved free identifier becomes `#("fcid" <cid>)` (function) or
`#("vcid" <cid>)` (variable) instead of `#("gref" pkg name)` /
`#("free" pkg name)`. This is what makes hashing *recursive* (as in Unison):
the CID of a form depends on the CIDs of the definitions it references, so

* renaming a referenced definition does **not** change the referring form's
  CID, and
* editing a referenced definition **does** change it.

Bound identifiers are unaffected — the lexical environment always wins, so
`*reference-resolver*` is never consulted for a bound name — and identifiers
inside quoted data are never resolved. With no resolver bound (the default)
the output is byte-for-byte what it was before, so existing CIDs are stable.

## The code database (`cl-cm-db`)

`cl-cm` addresses code; `cl-cm-db` remembers **names** for it. A
`code-database` associates a stable *identity* (a symbol, e.g. a top-level
name) with the CID of a piece of code, and stores that code. It is exactly
the "definition graph" the recursive-hashing section above leaves to the
layer built on top.

The database is split in two, each half in its own file:

* **The identity log** — append-only text, `NAME.identities`. Every
  definition or redefinition appends one readable line:

  ```lisp
  (:define "2024-05-01T09:30:00Z" "CL-USER::FACT" "bafyreidpgybb...")
  (:set    "2024-05-01T09:41:12Z" "CL-USER::FACT" "bafyreih4xt...")
  ```

  Folding the file from the top and keeping the last record per key yields
  the *current* identities, so a later compaction can rewrite it in place
  without changing the format. Each line carries a UTC timestamp.

* **The code store** — a directory, `NAME.objects/`, with one object file
  per CID (git/Unison-style). Each object file holds two things: the
  DASL/CBOR bytes of the resolved canonical node (the bytes the CID hashes
  — literally *the code saved in the hash*) and the original source
  expression that produced it, printed readably:

  ```
  "CMOB"  version  u32-blob-length  <CBOR blob>  u32-source-length  <source text>
  ```

  The CID is recovered from the blob on load, so an object file is
  self-verifying.

The database doubles as cl-cm's reference resolver, so content addressing
is *recursive*: a definition's CID depends on the CIDs of the identities it
references.

```lisp
(defparameter db (cl-cm-db:make-database :directory #p"~/code-db/" :name "my"))

(cl-cm-db:load-database db)                    ; populate the in-memory caches

(cl-cm-db:defidentity db 'fact
  '(lambda (n) (if (zerop n) 1 (* n (fact (1- n))))))
;; => "bafyrei..."  (also stored in the code store, logged in the identity log)

(cl-cm-db:setidentity db 'fact '(lambda (n) (factorial n)))   ; change it

(cl-cm-db:identity-cid 'fact db)    ; -> current CID
(cl-cm-db:identity-code 'fact db)   ; -> the stored source expression
```

`defidentity` signals an error when the identity is already defined;
`setidentity` signals one when it is not — so the two are hard to confuse.
Neither evaluates the form: they take an s-expression *as data*, which is
what a codebase manager wants.  Both take the database first, because the
database is what defines the environment the code is resolved against.

When the identity *is* an ordinary function, the `defun-identity` and
`setf-identity` macros keep the Lisp definition and its stored identity in
step — each `defun`s the name and registers the matching `(lambda ...)`:

```lisp
(cl-cm-db:defun-identity fact db (n) (factorial n))   ; like defun + defidentity
(cl-cm-db:setf-identity  fact db (n) (factorial n))   ; like defun + setidentity
```

Storage is content-addressed and immutable. Storing the same code twice is
a no-op, and changing a referenced definition never rewrites what already
exists: the referrer's identity keeps its old CID until you `setidentity`
it, at which point it gets a *new* CID. Old objects stay on disk, still
addressable by their own hash. (A definition's CID therefore depends only
on which identities existed when it was defined — a free reference to a
name defined later is hashed by name.)

Key functions: `make-database`, `load-database` / `ensure-database`,
`defidentity`, `setidentity`, `defun-identity`, `setf-identity`,
`identity-cid`, `identity-code`, `store-code`, `database-code-cid`,
`database-code-node`, `database-code-blob`, `database-resolver`.

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
* **Recursive content addressing is opt-in, not automatic.** Free identifiers
  keep their `package:name` unless you bind `*reference-resolver*` (see
  *Content-addressed references*). `cl-cm` does not itself track a definition
  graph, resolve name collisions, or break reference cycles — those belong to
  the layer built on top (see `apeiron/verbs`).
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
(asdf:test-system :cl-cm)        ; runs the hand-rolled checks AND the FiveAM suite
(cl-cm-tests:run-self-test)      ; the same thing, at the REPL
(fiveam:run! 'cl-cm-tests::cl-cm-db-suite)   ; just the database suite
```

The core `cl-cm` behaviour is covered by 29 dependency-free checks: renaming
bound identifiers must not change the CID, structural differences (free names,
binding order, string case, quoted data) must, and a resolved free reference
must hash by the referenced CID, not its name.

The database layer is covered by a FiveAM suite (`test-db.lisp`): defining and
redefining identities, the timestamped append-only log, the object-file layout
\(CBOR + source, self-verifying by CID), persistence across a reload, and
recursive content addressing through referenced identities.

## License

MIT

The DASL/CBOR encoder and CID generation in `dasl.lisp` are moved/adapted
from [cl-dasl](https://gitlab.nijl.ac.jp/CHISE/cl-dasl) (MIT), by
_Mihai Bazon <mihai.bazon@gmail.com>_ and _Tomohiko Morioka_, which is
itself based on the CBOR encoder/decoder for Common Lisp (cbor.lisp) by
_Mihai Bazon <mihai.bazon@gmail.com>_.
