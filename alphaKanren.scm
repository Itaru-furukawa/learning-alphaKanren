;; Complete, revised implementation of alphaKanren, an embedding of nominal
;; logic programming in R5RS-compliant Scheme.  
;;
;; This implementation is from the revised version of:
;;
;; alphaKanren: A Fresh Name in Nominal Logic Programming
;; William E. Byrd and Daniel P. Friedman
;;
;; first presented in the Proceedings of the 2007 Workshop on Scheme and
;; Functional Programming, Universite Laval Technical Report DIUL-RT-0701,
;; pp. 79-90.
;;
;; Revised:  16 January 2014
;; tie and hash now require their first arguments be ground noms.
#!r6rs
(import (rnrs))

(define-syntax pmatch
  (syntax-rules (else guard)
    ((_ (op arg ...) cs ...)
     (let ((v (op arg ...)))
       (pmatch v cs ...)))
    ((_ v) (if #f #f))
    ((_ v (else e0 e ...)) (begin e0 e ...))
    ((_ v (pat (guard g ...) e0 e ...) cs ...)
     (let ((fk (lambda () (pmatch v cs ...))))
       (ppat v pat 
         (if (and g ...) (begin e0 e ...) (fk))
         (fk))))
    ((_ v (pat e0 e ...) cs ...)
     (let ((fk (lambda () (pmatch v cs ...))))
       (ppat v pat (begin e0 e ...) (fk))))))

(define-syntax ppat
  (syntax-rules (? quote unquote)
    ((_ v ? kt kf) kt)
    ((_ v () kt kf) (if (null? v) kt kf))
    ((_ v (quote lit) kt kf)
     (if (equal? v (quote lit)) kt kf))
    ((_ v (unquote var) kt kf) (let ((var v)) kt))
    ((_ v (x . y) kt kf)
     (if (pair? v)
       (let ((vx (car v)) (vy (cdr v)))
         (ppat vx x (ppat vy y kt kf) kf))
       kf))
    ((_ v lit kt kf) (if (equal? v (quote lit)) kt kf))))

(define-syntax mv-let
  (syntax-rules ()
    ((_ ((x ...) e) b0 b ...)
     (pmatch e ((,x ...) b0 b ...)))))

(define nom?
  (lambda (x)
    (pmatch x
      ((nom-tag ?) #t)
      (else #f))))

(define-syntax tie
  (syntax-rules ()
    ((_ a t)
     (begin
       (unless (nom? a) (error 'tie "first argument is not a nom" a))
       `(tie-tag ,a ,t)))))

(define var
  (lambda ()
    (letrec ((s (list 'susp-tag '() (lambda () s))))
      s)))

(define unify
  (lambda (eqns sigma nabla fk)
    (let ((eqns (apply-subst sigma eqns)))
      (mv-let ((sigma^ delta) (apply-sigma-rules eqns fk))
        (unifyhash delta (compose-subst sigma sigma^) nabla fk)))))

(define unifyhash
  (lambda (delta sigma nabla fk)
    (let ((delta (apply-subst sigma delta))
          (nabla (apply-subst sigma nabla)))
      (let ((delta (delta-union nabla delta)))
        `(,sigma ,(apply-nabla-rules delta fk))))))

(define apply-sigma-rules
  (lambda (eqns fk)
    (cond
      ((null? eqns) `(,empty-sigma ,empty-delta))
      (else
       (let ((eqn (car eqns)) (eqns (cdr eqns)))
         (mv-let ((eqns sigma delta) (or (sigma-rules eqn eqns) (fk)))
           (mv-let ((sigma^ delta^) (apply-sigma-rules eqns fk))
             `(,(compose-subst sigma sigma^) ,(delta-union delta^ delta)))))))))

(define apply-nabla-rules
  (lambda (delta fk)
    (cond
      ((null? delta) empty-nabla)
      (else
       (let ((c (car delta)) (delta (cdr delta)))
         (mv-let ((delta nabla) (or (nabla-rules c delta) (fk)))
           (delta-union nabla (apply-nabla-rules delta fk))))))))

(define untagged?
  (lambda (x)
    (not (memv x '(tie-tag nom-tag susp-tag)))))

(define sigma-rules  
  (lambda (eqn eqns)
    (pmatch eqn
      ((,c . ,c^)
       (guard (not (pair? c)) (equal? c c^))
       `(,eqns ,empty-sigma ,empty-delta))
       (((tie-tag ,a ,t) . (tie-tag ,a^ ,t^))
        (guard (eq? a a^))
        `(((,t . ,t^) . ,eqns) ,empty-sigma ,empty-delta))
       (((tie-tag ,a ,t) . (tie-tag ,a^ ,t^))
        (guard (not (eq? a a^)))
        (let ((u^ (apply-pi `((,a ,a^)) t^)))
          `(((,t . ,u^) . ,eqns) ,empty-sigma ((,a . ,t^)))))
       (((nom-tag ?) . (nom-tag ?))
        (guard (eq? (car eqn) (cdr eqn)))
        `(,eqns ,empty-sigma ,empty-delta))
       (((susp-tag ,pi ,x) . (susp-tag ,pi^ ,x^))
        (guard (eq? (x) (x^)))
        (let ((delta (map (lambda (a) `(,a . ,(x))) 
                             (disagreement-set pi pi^))))
          `(,eqns ,empty-sigma ,delta)))
       (((susp-tag ,pi ,x) . ,t)
        (guard (not (occurs-check (x) t)))
        (let ((sigma `((,(x) . ,(apply-pi (reverse pi) t)))))
          `(,(apply-subst sigma eqns) ,sigma ,empty-delta)))
       ((,t . (susp-tag ,pi ,x))
        (guard (not (occurs-check (x) t)))
        (let ((sigma `((,(x) . ,(apply-pi (reverse pi) t)))))
          `(,(apply-subst sigma eqns) ,sigma ,empty-delta)))
       (((,t1 . ,t2) . (,t1^ . ,t2^))
        (guard (untagged? t1) (untagged? t1^))
        `(((,t1 . ,t1^) (,t2 . ,t2^) . ,eqns) ,empty-sigma ,empty-delta))
       (else #f))))

(define apply-pi
  (lambda (pi v)
    (pmatch v
      (,c (guard (not (pair? c))) c)
      ((tie-tag ,a ,t) (tie (apply-pi pi a) (apply-pi pi t)))      
      ((nom-tag ?)
       (let loop ((v v) (pi pi))
         (if (null? pi) v (apply-swap (car pi) (loop v (cdr pi))))))
      ((susp-tag ,pi^ ,x)
       (let ((pi `(,@pi . ,pi^)))
         (if (null? pi) (x) `(susp-tag ,pi ,x))))
      ((,a . ,d) `(,(apply-pi pi a) . ,(apply-pi pi d))))))

(define apply-swap
  (lambda (swap a)
    (pmatch swap
      ((,a1 ,a2)
       (cond
         ((eq? a a2) a1)
         ((eq? a a1) a2)
         (else a))))))

(define nabla-rules
  (lambda (d delta)
    (pmatch d
      ((,a . ,c)
       (guard (not (pair? c)))
       `(,delta ,empty-nabla))
      ((,a . (tie-tag ,a^ ,t))
       (guard (eq? a^ a))
       `(,delta ,empty-nabla))
      ((,a . (tie-tag ,a^ ,t))
       (guard (not (eq? a^ a)))
       `(((,a . ,t) . ,delta) ,empty-nabla))
      ((,a . (nom-tag ?))
       (guard (not (eq? a (cdr d))))
       `(,delta ,empty-nabla))
      ((,a . (susp-tag ,pi ,x))
       `(,delta ((,(apply-pi (reverse pi) a) . ,(x)))))
      ((,a . (,t1 . ,t2))
       (guard (untagged? t1))
       `(((,a . ,t1) (,a . ,t2) . ,delta) ,empty-nabla))
      (else #f))))

(define disagreement-set
  (lambda (pi pi^)
    (filter
      (lambda (a) (not (eq? (apply-pi pi a) (apply-pi pi^ a))))
      (remove-duplicates
        (append (apply append pi) (apply append pi^))))))

(define occurs-check
  (lambda (x v)
    (pmatch v
      (,c (guard (not (pair? c))) #f)
      ((tie-tag ? ,t) (occurs-check x t))      
      ((nom-tag ?) #f)
      ((susp-tag ? ,x^) (eq? (x^) x))
      ((,x^ . ,y^) (or (occurs-check x x^) (occurs-check x y^)))
      (else #f))))

(define compose-subst
  (lambda (sigma tau)
    (let ((sigma^ (map
                    (lambda (a) `(,(car a) . ,(apply-subst tau (cdr a))))
                    sigma)))
      (append
        (filter (lambda (a) (not (assq (car a) sigma^))) tau)
        (filter (lambda (a) (not (eq? (car a) (cdr a)))) sigma^)))))

(define apply-subst
  (lambda (sigma v)
    (pmatch v
      (,c (guard (not (pair? c))) c)
      ((tie-tag ,a ,t) (tie a (apply-subst sigma t)))      
      ((nom-tag ?) v)
      ((susp-tag ,pi ,x) (apply-pi pi (get (x) sigma)))
      ((,x . ,y) `(,(apply-subst sigma x) . ,(apply-subst sigma y))))))

(define delta-union
  (lambda (delta delta^)
    (pmatch delta
      (() delta^)
      ((,d . ,delta) (if (term-member? d delta^)
                       (delta-union delta delta^)
                       (cons d (delta-union delta delta^)))))))

(define term-member?
  (lambda (v v*)
    (pmatch v*
      (() #f)
      ((,v^ . ,v*) 
       (or (term-equal? v^ v) (term-member? v v*))))))

(define term-equal?
  (lambda (u v)
    (pmatch `(,u ,v)
      ((,c ,c^) (guard (not (pair? c)) (not (pair? c^)))
       (equal? c c^))
      (((tie-tag ,a ,t) (tie-tag ,a^ ,t^))
       (and (eq? a a^) (term-equal? t t^)))
      (((nom-tag ?) (nom-tag ?)) (eq? u v))
      (((susp-tag ,pi ,x) (susp-tag ,pi^ ,x^))
       (and (eq? (x) (x^)) (null? (disagreement-set pi pi^))))
      (((,x . ,y) (,x^ . ,y^))
       (and (term-equal? x x^) (term-equal? y y^)))
      (else #f))))

(define-syntax choice
  (syntax-rules ()
    ((_ a f) (cons a f))))

(define-syntax inc 
  (syntax-rules ()
    ((_ e) (lambdaf@ () e))))

(define-syntax case-inf
  (syntax-rules ()
    ((_ a-inf (() e0) ((f^) e1) ((a^) e2) ((a f) e3))
     (pmatch a-inf
       (#f e0)
       (,f^ (guard (procedure? f^)) e1)
       (,a^ (guard (not 
                     (and (pair? a^) 
                          (procedure? (cdr a^)))))
            e2)
       ((,a . ,f) e3)))))

(define-syntax lambdag@
  (syntax-rules () ((_ (p) e) (lambda (p) e))))

(define-syntax lambdaf@
  (syntax-rules () ((_ () e) (lambda () e))))

(define-syntax run
  (syntax-rules ()
    ((_ n (x) g0 g ...)
     (take n (lambdaf@ ()
               ((exist (x) g0 g ... 
                  (lambdag@ (p)
                    (cons (reify x p) '())))
                `(,empty-sigma ,empty-nabla)))))))

(define take
  (lambda (n f)
    (if (and n (zero? n)) 
      '()
      (case-inf (f)
        (() '())
        ((f) (take n f))
        ((a) a)
        ((a f) (cons (car a)
                 (take (and n (- n 1)) f)))))))

(define-syntax run*
  (syntax-rules ()
    ((_ (x) g0 g ...)
     (run #f (x) g0 g ...))))

(define empty-sigma '())
(define empty-delta '())
(define empty-nabla '())

(define unifier
  (lambda (fn set)
    (lambdag@ (p)
      (mv-let ((sigma nabla) p)
        (call/cc (lambda (fk) (fn set sigma nabla (lambda () (fk #f)))))))))

(define ==
  (lambda (u v)
    (unifier unify `((,u . ,v)))))

(define hash
  (lambda (a t)
    (begin
      (unless (nom? a) (error 'hash "first argument is not a nom" a))
      (unifier unifyhash `((,a . ,t))))))

(define-syntax exist
  (syntax-rules ()
    ((_ (x ...) g0 g ...)
     (lambdag@ (p)
       (inc
         (let ((x (var)) ...)
           (bind* (g0 p) g ...)))))))

(define-syntax fresh
  (syntax-rules ()
    ((_ (a ...) g0 g ...)
     (lambdag@ (p)
       (inc
         (let ((a (nom 'a)) ...)
           (bind* (g0 p) g ...)))))))

(define nom
  (lambda (a)
    `(nom-tag ,(symbol->string a))))

(define-syntax bind*
  (syntax-rules ()
    ((_ e) e)
    ((_ e g0 g ...)
     (let ((a-inf e))
       (and a-inf (bind* (bind a-inf g0) g ...))))))

(define bind
  (lambda (a-inf g)
    (case-inf a-inf
      (() #f)
      ((f) (inc (bind (f) g)))
      ((a) (g a))
      ((a f) (mplus (g a) (lambdaf@ () (bind (f) g)))))))

(define mplus
  (lambda (a-inf f)
    (case-inf a-inf
      (() (f))
      ((f^) (inc (mplus (f) f^)))
      ((a) (choice a f))
      ((a f^) (choice a (lambdaf@ () (mplus (f) f^)))))))

(define-syntax conde
  (syntax-rules ()
    ((_ (g0 g ...) (g1 g^ ...) ...)
     (lambdag@ (p)
       (inc 
         (mplus* (bind* (g0 p) g ...)
                 (bind* (g1 p) g^ ...)
                 ...))))))

(define-syntax mplus*
  (syntax-rules ()
    ((_ e) e)
    ((_ e0 e ...) (mplus e0 (lambdaf@ () (mplus* e ...))))))

(define-syntax conda
  (syntax-rules ()
    ((_ (g0 g ...) (g1 g^ ...) ...)
     (lambdag@ (p)
       (inc (ifa ((g0 p) g ...)
                 ((g1 p) g^ ...) ...))))))

(define-syntax ifa
  (syntax-rules ()
    ((_) #f)
    ((_ (e g ...) b ...)
     (let loop ((a-inf e))
       (case-inf a-inf
         (() (ifa b ...))
         ((f) (inc (loop (f))))
         ((a) (bind* a-inf g ...))
         ((a f) (bind* a-inf g ...)))))))

(define-syntax condu
  (syntax-rules ()
    ((_ (g0 g ...) (g1 g^ ...) ...)
     (lambdag@ (p)
       (inc (ifu ((g0 p) g ...)
                 ((g1 p) g^ ...) ...))))))

(define-syntax ifu
  (syntax-rules ()
    ((_) #f)
    ((_ (e g ...) b ...)
     (let loop ((a-inf e))
       (case-inf a-inf
         (() (ifu b ...))
         ((f) (inc (loop (f))))
         ((a) (bind* a-inf g ...))
         ((a f) (bind* a g ...)))))))

(define-syntax project
  (syntax-rules ()                       
    ((_ (x ...) g0 g ...)
     (lambdag@ (p)
       (mv-let ((sigma nabla) p)
         (let ((x (apply-subst sigma x)) ...)
           (bind* (g0 p) g ...)))))))

(define reify
  (lambda (x p)
    (mv-let ((sigma nabla) p)
      (let* ((v (get x sigma))
             (s (reify-s v))
             (v (apply-reify-s v s)))
        (let ((nabla (filter (lambda (a)
                               (and (symbol? (car a))
                                    (symbol? (cdr a))))
                       (apply-reify-s nabla s))))
          (cond
            ((null? nabla) v)
            (else `(,v : ,nabla))))))))

(define apply-reify-s
  (lambda (v s)
    (pmatch v
      (,c (guard (not (pair? c))) c)
      ((tie-tag ,a ,t) 
       `(tie-tag ,(get a s) ,(apply-reify-s t s)))
      ((nom-tag ?) (get v s))
      ((susp-tag () ?) (get v s))
      ((susp-tag ,pi ,x) 
       `(susp-tag
          ,(map (lambda (swap)
                  (pmatch swap
                    ((,a ,b) `(,(get a s) ,(get b s)))))
             pi)
          ,(get (x) s)))
      ((,a . ,d)
       `(,(apply-reify-s a s) . ,(apply-reify-s d s))))))

(define reify-s
  (letrec
    ((r-s (lambda (v s)
            (pmatch v
              (,c (guard (not (pair? c))) s)
              ((tie-tag ,a ,t) (r-s t (r-s a s)))
              ((nom-tag ,n)
               (cond
                 ((assq v s) s)
                 ((assp nom? s)
                  => (lambda (p)
                       (cons `(,v . ,(reify-n (cdr p))) s)))
                 (else (cons `(,v . a.0) s))))
              ((susp-tag () ?)
               (cond
                 ((assq v s) s)
                 ((assp var? s)
                  => (lambda (p)
                       (cons `(,v . ,(reify-n (cdr p))) s)))
                 (else (cons `(,v . _.0) s))))
              ((susp-tag ,pi ,x)
               (r-s (x) (r-s pi s)))
              ((,a . ,d) (r-s d (r-s a s)))))))
      (lambda (v)
        (r-s v '()))))


(define var?
  (lambda (x)
    (pmatch x
      ((susp-tag () ?) #t)
      (else #f))))

(define reify-n
  (lambda (a)
    (let ((str* (string->list (symbol->string a))))
      (let ((c* (memv #\. str*)))
        (let ((rn (string->number (list->string (cdr c*)))))
	  (let ((n-str (number->string (+ rn 1))))
	    (string->symbol 
	      (string-append
		(string (car str*)) "." n-str))))))))

(define get
  (lambda (x s)
    (cond
      ((assq x s) => cdr)
      (else x))))

(define assp
  (lambda (p s)
    (cond
      ((null? s) #f)
      ((p (car (car s))) (car s))
      (else (assp p (cdr s))))))

(define filter
  (lambda (p s)
    (cond
      ((null? s) '())
      ((p (car s)) (cons (car s) (filter p (cdr s))))
      (else (filter p (cdr s))))))

(define remove-duplicates
  (lambda (s)
    (cond
      ((null? s) '())
      ((memq (car s) (cdr s)) (remove-duplicates (cdr s)))
      (else (cons (car s) (remove-duplicates (cdr s)))))))

;; add definition from 3.1 Non-naive Substitution

(define substo
  (lambda (e new a out)
    (conde
     ((== `(var ,a) e) (== new out))
     ((exist (y)
              (== `(var ,y) e)
              (== `(var ,y) out)
              (hash a y)))
     ((exist (rator ratorres rand randres)
             (== `(app ,rator ,rand) e)
             (== `(app ,ratorres ,randres) out)
             (substo rator new a ratorres)
             (substo rand new a randres)))
     ((exist (body bodyres)
             (fresh (c)
                    (== `(lam ,(tie c body)) e)
                    (== `(lam ,(tie c bodyres)) out)
                    (hash c a)
                    (hash c new)
                    (substo body new a bodyres)))))))

;; add definition from 3.2 Type Inferencer for Simply Typed λ-calculus

(define typo
  (lambda (g e te)
    (conde
     ((exist (x)
             (== `(var ,x) e)
             (lookupo x te g)))
     ((exist (rator trator rand trand)
             (== `(app ,rator ,rand) e)
             (== `(→ ,trand ,te) trator)
             (typo g rator trator)
             (typo g rand trand)))
     ((exist (e^ te^ trand g^)
             (fresh (b)
                    (== `(lam ,(tie b e^)) e)
                    (== `(→ ,trand ,te^) te)
                    (hash b g)
                    (== `((,b . ,trand) . ,g) g^)
                    (typo g^ e^ te^)))))))

(define lookupo
  (lambda (x tx g)
    (exist (a d)
           (== `(,a . ,d) g)
           (conde
            ((== `(,x . ,tx) a))
            ((exist (x^ tx^)
                    (== `(,x^ . ,tx^) a)
                    (hash x x^)
                    (lookupo x tx d)))))))
