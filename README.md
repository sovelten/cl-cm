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
  (:define  "2024-05-01T09:30:00Z" "CL-USER::FACT" "bafyreidpgybb...")
  (:set     "2024-05-01T09:41:12Z" "CL-USER::FACT" "bafyreih4xt...")
  (:retract "2024-05-01T09:55:03Z" "CL-USER::FACT")
  ```

  Folding the file from the top and keeping the last record per key yields
  the *current* identities, so a later compaction can rewrite it in place
  without changing the format. `:define` and `:set` carry a CID; `:retract`
  removes the key. Each line carries a UTC timestamp.

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
;; INIT-DATABASE creates a new database or loads an existing one, so the
;; same call works on a fresh checkout and on a populated directory.
;; It returns (values DB EXISTED-P).
(defparameter db (cl-cm-db:init-database :directory #p"~/code-db/" :name "test"))
;; => #<CODE-DATABASE ...>          ; or (values DB T) if code-db/ was already there

;; First definition: DEFUN-IDENTITY defuns MULT *and* logs a :define record.
(cl-cm-db:defun-identity mult db (x y) (* x y))
;; => "bafyrei..."   (object written to test.objects/, :define in test.identities)

;; Redefine it: SETF-IDENTITY defuns MULT again and logs a :set record.
(cl-cm-db:setf-identity mult db (x y z) (* x y z))
;; => "bafyrei..."   (new object; a :set line appended to test.identities)

(cl-cm-db:identity-cid 'mult db)    ; -> current CID
(cl-cm-db:identity-code 'mult db)   ; -> (LAMBDA (X Y Z) (* X Y Z))
```

The data-level API takes the source expression *as data* and never
evaluates it; `db` still comes first because the database defines the
environment the code is resolved against:

```lisp
(cl-cm-db:defidentity db 'square '(lambda (n) (* n n)))
(cl-cm-db:setidentity db 'square '(lambda (n) (let ((s (* n n))) s)))
```

`make-database` only builds the object (it does not touch disk);
`init-database` is `make-database` followed by `load-database`, and
`ensure-database` lazily loads an object the first time it is used.

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

### Compiled code

The database also manages compiled code. `code-function` compiles the
stored source of a CID on first use and caches the compiled function by
CID (the cache is transient — compiled code is rebuilt from source on
demand). Free function references are wired to the compiled function of
the referenced CID, so recursive content addressing is executable: an
already-compiled caller keeps reaching the versions it was compiled
against even after a callee is redefined.

```lisp
(cl-cm-db:defidentity db 'inc  '(lambda (x) (+ x 1)))
(cl-cm-db:defidentity db 'twice '(lambda (x) (inc (inc x))))

(funcall (cl-cm-db:code-function db (cl-cm-db:identity-cid 'twice db)) 10)
;; => 12

(cl-cm-db:setidentity db 'inc '(lambda (x) (+ x 10)))
;; TWICE still calls the version of INC it was compiled against...
(funcall (cl-cm-db:code-function db (cl-cm-db:identity-cid 'twice db)) 10)
;; => 12
```

`identity-function` is the same thing addressed by name; `code-references`
recovers the references a stored CID was hashed with (from the identity
log, so they do not drift), and `source-references` reports the references
of a source expression against the current identities — useful before
storing it.

### Definitions and reverse lookups

`definition-by-identity` and `definition-by-cid` return a
`code-definition` holding the CID and source; `code-definition-lambda-list`
and `code-definition-body` split a `(lambda ...)` source. Reverse lookups
go back the other way: `identity-names-for-cid` lists the names currently
bound to a CID, `identity-history` lists the CIDs a name has been bound to,
and `code-referrers` lists the names whose current definition references a
CID (by CID, so renaming a referrer does not change the answer).

```lisp
(cl-cm-db:identity-cid 'twice db)          ; -> current CID
(cl-cm-db:identity-names-for-cid db cid)   ; -> ("CL-USER::TWICE" ...)
(cl-cm-db:identity-history 'twice db)      ; -> (newest ... oldest)
(cl-cm-db:code-referrers db inc-cid)       ; -> ("CL-USER::TWICE")
```

`ensure-identity` is the upsert of `defidentity`/`setidentity`: it defines a
new identity, or changes an existing one, and treats re-storing identical
content as a no-op. `code-count` and `map-definitions` are the natural
whole-database queries.

### Retracting identities

`retractidentity` removes an identity. It appends a `(:retract ...)`
record and drops the key from the current identities; the old object stays
on disk until you clean it up.

```lisp
(cl-cm-db:retractidentity db 'square)
;; => "bafyrei..."           ; the CID SQUARE had
(cl-cm-db:identity-cid 'square db)   ; => NIL
(cl-cm-db:identity-code 'square db)  ; => NIL
```

Retracting an identity that is not defined signals an error, just like
`setidentity` — so an accidental retraction is hard to miss.

### Cleaning the object store

Object files are immutable, so redefining or retracting an identity leaves
superseded objects behind. `clean-database` reaps them, in two modes:

```lisp
;; :shallow -- keep every object named anywhere in the log (history is
;; preserved), delete only objects that no record refers to.
(cl-cm-db:clean-database db :mode :shallow)
;; => (:MODE :SHALLOW :KEPT 3 :REMOVED 1 :FREED-BYTES 321)

;; :deep -- compact the log to the current identities (latest record per
;; key, retracted keys dropped), then delete every object those current
;; identities do not reference.
(cl-cm-db:clean-database db :mode :deep)
;; => (:MODE :DEEP :KEPT 2 :REMOVED 2 :FREED-BYTES 644)

;; Preview the effect without deleting or rewriting anything:
(cl-cm-db:clean-database db :mode :deep :dry-run t)
```

`:shallow` is the safe, history-preserving choice; `:deep` is the
space-reclaiming one, and also rewrites `NAME.identities` in the same
one-record-per-line format. Both return a plist reporting how many objects
were kept, removed, and how many bytes were freed.

### Resolving references through the database

Because the database knows every current identity, it doubles as a cl-cm
`*reference-resolver*`: `database-resolver` returns a closure mapping a
free name to the CID of the identity it names. That is what makes content
addressing recursive — a referrer's CID depends on the CIDs it references:

```lisp
;; A definition that references MULT.
(cl-cm-db:defidentity db 'double '(lambda (n) (mult n 2)))

;; Ask cl-cm for the CID of the same form, resolved through the database.
(let ((cl-cm:*reference-resolver* (cl-cm-db:database-resolver db)))
  (cl-cm:code-cid '(lambda (n) (mult n 2))))
;; => DOUBLE's CID: the reference to MULT resolved to MULT's CID

;; ...or pass the resolver explicitly:
(cl-cm:code-cid-with-resolver
 '(lambda (n) (mult n 2))
 (cl-cm-db:database-resolver db))
;; => the same CID
```

`database-code-cid` is the one-step version (`code-cid` plus the database
resolver); `database-code-node` and `database-code-blob` expose the
resolved canonical tree and its CBOR bytes. Changing `mult` with
`setidentity` changes the CID that `double` *would now get* — while
`double`'s stored source stays stable until you redefine it too.

Key functions: `make-database`, `init-database`, `load-database` /
`ensure-database`, `defidentity`, `setidentity`, `retractidentity`,
`defun-identity`, `setf-identity`, `identity-cid`, `identity-code`,
`clean-database`, `store-code`, `database-code-cid`, `database-code-node`,
`database-code-blob`, `database-resolver`.

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
