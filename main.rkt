#lang racket

(require racket
         racket/splicing
         handy/utils
         )

(provide prefix-for-test-report ; parameter printed at start of each test
         prefix-for-diag        ; parameter printed at front of each (diag ...) message

         ok                ; A value is true
         not-ok            ; A value is false
         is-false          ; Alias for not-ok

         is                ; A value is what it should be
         isnt              ; ...or shouldn't be

         like              ; A value matches a regex
         unlike            ; A value does not match a regex

         lives             ; expression does not throw an exception
         dies              ; expression does throw
         throws            ; throws an exception and that exn matches a predicate

         matches           ; value matches a predicate
         not-matches       ; ...or doesn't
         is-type           ; alias for matches
         isnt-type         ; alias for not-matches

         is-approx         ; value is roughly the expected value
         isnt-approx       ; ...or not

         test-suite        ; gather a set of tests together, trap exns, output some extra debugging

         make-test-file    ; create a file on disk, populate it

         expect-n-tests    ; unless N tests ran, print error at end of file execution
         done-testing      ; never mind how many tests we expect, we're okay if we see this
         diag              ; print a diagnostic message. see prefix-for-diag

         tests-passed      ; # of tests passed so far
         tests-failed      ; # of tests failed so far

         test-more-check   ; fundamental test procedure.  All others call this

         inc-test-num!     ; tests start at 1.  Use this to change test number (but why?)
         current-test-num  ; return current test number
         next-test-num     ; return next test number and optionally modify it
         )


;;======================================================================
;;    The racket testing module has a few things that I think could be better:
;;
;; 1) The test function names are verbose and redundant.  check-this, check-that, etc
;;
;; 2) The test functions display nothing on success.  There's no way
;; to tell the difference between "no tests ran" and "all tests
;; succeeded"
;;
;; 3) The tests return nothing.  You can't do conditional tests like:
;;        (unless (is os 'Windows) (ok test-that-won't-pass-on-windows))
;;
;; This module addresses those problems.  It's named for, and largely a
;; clone of, the Test::More library on Perl's CPAN, although some
;; features are not implemented.
;;
;; http://search.cpan.org/~exodist/Test-Simple-1.302120/lib/Test/More.pm
;; for more details on the original.
;;
;; ----------------------------------------------------------------------
;; NOTE: For testing purposes, some 'private' functions are exported.
;; Their names all start with '_'; these functions should not be called
;; unless you know what you're doing.
;; ----------------------------------------------------------------------

;;    TODO:
;; - Add 'disable this test suite' keyword
;; - Add 'TODO this test suite' keyword
;; - Fix the issue where it sometimes shows 'expected #f got #f'
;; - On test-suite, add 'setup' and 'cleanup' keywords that take thunks

;;======================================================================


; Parameter: prefix-for-test-report
;
; Set this to put a prefix on some or all of your tests.  Example:
;
;    (parameterize ([prefix-for-test-report "TODO: "])
;        ...tests...)
(define prefix-for-test-report (make-parameter ""))

; Internal variables
(define _tp (make-parameter 0))                 ; how many tests have passed thus far?
(define _tf (make-parameter 0))                 ; how many tests have failed thus far?
(define saw-done-testing (make-parameter #f))   ; did we see a (done-testing) call?

;;----------------------------------------------------------------------
;
; Parameter: expect-n-tests
; Default  : #f
;
; Set this to say "this script will run 17 tests" (or however many).
; If it runs more or fewer then an error will be reported at the end.
;
; See also: done-testing
;
; If neither this nor done-testing are seen before end of file, a
; warning will be reported when the tests are run.
;
(define expect-n-tests (make-parameter #f))

;----------------------------------------------------------------------
; Internal helper functions to set or get the number of tests passed  and failed.
;
; Call as (tests-passed) to get the number, (tests-passed 2) to add 2 to the number and return it
(define (tests-passed [inc 0])
  (_tp (+ (_tp) inc))
  (_tp))

(define (tests-failed [inc 0])
  (_tf (+ (_tf) inc))
  (_tf))

;----------------------------------------------------------------------

;  Track which test we're on. (i.e. test 1, 2, 3....)
(define current-test-num (make-parameter 0))
(define (inc-test-num! inc) (current-test-num (+ (current-test-num) inc)))
(define (next-test-num #:inc [should-increment #t])
  (define next (add1 (current-test-num)))
  (when should-increment
    (current-test-num next))
  (current-test-num))

;;----------------------------------------------------------------------

; plumbers are called when the program exits.  In this case, when the
; plumber flushes we will do a final report saying whether or not we
; ran all tests.
(void
 (plumber-add-flush! (current-plumber)
                     (lambda (flush-handle)
                       (cond [(saw-done-testing) #t]
                             [(equal? (current-test-num) (expect-n-tests)) #t]
                             [(false? (expect-n-tests))
                              (say "WARNING: Neither (expect-n-tests N) nor (done-testing) was called.  May not have run all tests.")  ; THIS IS NOT DEBUGGING
                              ]
                             [else
                              ; THIS IS NOT DEBUGGING
                              (say (format "\n\t!!ERROR!!:  Expected ~a tests, ~a saw ~a\n"
                                           (expect-n-tests)
                                           (cond [(> (current-test-num) (expect-n-tests))
                                                  "actually"]
                                                 [else "only"])
                                           (current-test-num)))
                              #t])
                       (plumber-flush-handle-remove! flush-handle))))

;;----------------------------------------------------------------------

; test-more-check
;
; All the testing functions defined below are wrappers around this.
;
;  (test-more-check  #:got           got            ; the value to check
;                    #:expected      [expected #t]  ; what it should be
;                    #:msg           [msg ""]       ; what message to display
;                    #:op            [op equal?]    ; (op got expected) determines success
;                    #:show-expected/got? [show-expected/got? #t] ; display expected and got on fail?
;                    #:report-expected-as [report-expected-as #f] ; show this as expected on fail
;                    #:report-got-as      [report-got-as #f]      ; show this as got on fail
;                    #:return             [return #f]             ; return value
(define/contract
  (test-more-check  #:got           got
                    #:expected      [expected #t]
                    #:msg           [msg ""]
                    #:op            [op equal?]
                    #:show-expected/got? [show-expected/got? #t]
                    #:report-expected-as [report-expected-as #f]
                    #:report-got-as      [report-got-as #f]
                    #:return             [return #f]
                    )
  (->* (#:got any/c)
       (#:expected any/c
        #:msg string?
        #:op (-> any/c any/c any/c)
        #:show-expected/got? boolean?
        #:report-expected-as any/c
        #:report-got-as any/c
        #:return any/c
        )
       any)
  (let* ([success (op got expected)]
         [ok-str (if success "ok " "NOT ok ")]
         [expected-msg (~v (or report-expected-as expected))]
         [got-msg (~v (or report-got-as got))]
         [msg-str (format "~a~a"
                          (if (non-empty-string? msg)
                              (format " - ~a" msg)
                              "")
                          (if (and (not success) show-expected/got?)
                              (format "\n  Got:      ~a\n  Expected: ~a"
                                      got-msg
                                      expected-msg
                                      )
                              ""
                              ))])
    (define pass/fail-counter (if success tests-passed tests-failed))
    (pass/fail-counter 1)
    (parameterize ((prefix-for-say (~a (prefix-for-test-report) (prefix-for-say))))
      (say ok-str (next-test-num) msg-str)) ; THIS IS NOT DEBUGGING

    (if return
        return ; if we were told what to return, return that
        got))  ; otherwise, return the result
  )

;;----------------------------------------------------------------------

; simple boolean check.  Was the value of 'got' true? (i.e., it wasn't #f)
;    (ok 7)        ; success.  returns 7. prints just the normal "ok <test-num>" banner
;    (ok #f)       ; fail.  returns #f
;    (ok 7 "foo")  ; success, returns 7, prints "ok <test-num> - foo"
;
; Note the use of unwrap-val.  If pass in a thunk it will be called
; and the return value is used as the value of 'got'.  If you pass a
; promise it will be forced.  If you pass anything else, that's the
; value of got.
(define (ok val [msg ""])
  (test-more-check #:got (unwrap-val val)
                   #:msg msg
                   #:show-expected/got? #f
                   #:op (lambda (a b) (not (false? a)))
                   ))

; opposite of ok
(define (not-ok val [msg ""])
  (ok (false? (unwrap-val val))
      msg))

; alias for not-ok.  reads a little better
(define (is-false val [msg ""])
  (ok (false? (unwrap-val val))
      msg))

;;----------------------------------------------------------------------

; (matches val predicate [msg ""] [op equal?])
;
; Verify that the value of 'got' matches the predicate
;    (matches (my-func) hash? "(my-func) returns a hash")
(define (matches val predicate [msg ""] [op equal?])
  (test-more-check #:got (predicate val)
                   #:msg msg
                   #:op op
                   #:return val
                   ))

;;    (not-matches 'foo hash? "symbol foo is not a hash")
(define (not-matches val type-pred [msg ""] [op equal?])
  (test-more-check #:got ((negate type-pred) val)
                   #:msg msg
                   #:op op
                   #:return val
                   ))

;;    alias for 'matches'.  Reads cleaner for things like (is-type 7
;;    integer?) but matches is more general, e.g. (matches 7 (lambda
;;    (x) (= (add1 x) 8)))
(define (is-type val type-pred [msg ""] [op equal?])
  (matches val type-pred msg op))

;;    alias for 'not-matches'
(define (isnt-type val type-pred [msg ""] [op equal?])
  (not-matches val type-pred msg op))

;;----------------------------------------------------------------------

; (define (is val expected [msg ""] <optional comparison func> #:op <optional comparison func>
;
;    (is x 8 "x is 8")
;    (is (myfunc 7) 8 "(myfunc 7) returns 8")
;    (is x 8 "x is 8" =)       ; use = instead of equal? for comparison
;    (is x 8 "x is 8" #:op =)  ; use = instead of equal? for comparison
;
; The bread and butter of test-more.  Asks if two values are the same
; according to a particular comparison operator. (by default 'equal?')
;
; Returns the value that was checked (i.e. 'val', the first argument)
;
; NOTE: You can specify the comparison operator either positionally or
; via a keyword. The ability to provide an operator was added after
; this was already in use in code.  It was originally added as an
; optional parameter, and the better idea of having it be a keyword
; came along last.  In order to maintain backwards compatibility, both
; are supported.  If both are provided then the positional one wins.
;
(define (is val expected [msg ""] [op1 #f] #:op [op2 #f])
  (define op (or op1 op2 equal?))
  (test-more-check #:got (unwrap-val val)
                   #:expected expected
                   #:msg msg
                   #:op op
                   #:return val
                   ))

;;----------------------------------------------------------------------

; (define (isnt val expected [msg ""] <optional comparison func> #:op <optional comparison func>
;
; Same as 'is', but it checks that the values are NOT the same
(define (isnt val
              expected
              [msg ""]
              [op1 #f]
              #:op [op2 #f])
  (define op (or op1 op2 (negate equal?)))
  (test-more-check #:got (unwrap-val val)
                   #:expected expected
                   #:msg msg
                   #:report-expected-as (~a "<anything but " (~v expected) ">")
                   #:op op))

;;----------------------------------------------------------------------

; (define/contract (like val regex [msg ""])
;
; Checks that the value matches a regex. Returns the result of the regexp match
(define/contract (like val regex [msg ""])
  (->* (any/c regexp?) (string?) any)
  (define res (regexp-match regex (unwrap-val val)))
  (test-more-check #:got (true? res) ; force to boolean
                   #:return res
                   #:msg msg
                   #:report-expected-as (~a "<something matching " regex ">")))

;;----------------------------------------------------------------------

; (define/contract (unlike val regex [msg ""])
;
; Opposite of 'like' --checks that the value does NOT match a
; regex. Returns either #t or #f.
(define/contract (unlike val regex [msg ""])
  (->* (any/c regexp?)
       (string?)
       any/c)
  (test-more-check #:got (unwrap-val val)
                   #:expected #t
                   #:msg msg
                   #:report-expected-as (~a "<something NOT matching " regex ">")
                   #:op (lambda (a b) (not (regexp-match regex val)))))

;;----------------------------------------------------------------------

; (define/contract (lives thunk [msg ""])
;
; Verify that a thunk will run without throwing an exception.  The
; thunk may well contain other tests.

(define/contract (lives thnk [msg ""])
  (->* (procedure?) (string?) any/c)
  (define (make-msg e)
    (cond [(exn? e) (format "Exception thrown! Test message: '~a'.  Exception: '~a'" msg (exn-message e))]
          [else
           (format "Exception thrown! Test message: '~a'.  Exception: '~a'" msg (->string e))]
          ))
  (with-handlers (((lambda (e) #t) ; Trap everything
                   (lambda (e)
                     (test-more-check #:got #f
                                      #:return e
                                      #:msg (make-msg e)))))
    (define result (thnk))
    (test-more-check #:got result  #:expected result  #:msg msg)))

;;----------------------------------------------------------------------

; (define/contract (throws thnk pred [msg ""])
;
; Verify that a thunk DOES throw an exception and that the exception
; matches a specified predicate.
;
;    'pred' could be anything, but some types are handled specially:
;        - string: Check if it is exactly the (non-boilerplate) exn message
;        - proc:   Pass it the exn, see if it returns #t
;        - regex:  Check if the regex matches the (exn message || string) thrown
;        - etc:    Check if it's equal? to the exception
;
; NOTE: If you give it a function predicate that predicate must take
; one argument but it can be anything, not just an (exn?)
;
; NOTE: When providing a string as the value, it is matched against
; the non-boilerplate part of the exception message (assuming there is
; an exception).  That means that everything up to the first
; "expected: " is snipped off, as is everything after the last \n
;
;    (define (get-msg e) (if (exn? e) (exn-message e) e))
;    (let* ([str (regexp-replace #px"^.+?expected: " (get-msg the-exception) "")]
;           [str (regexp-replace #px"(.+)\n.+$" str "\\1")])
;        str)
(define/contract (throws thnk pred [msg ""])
  (->* ((-> any)
        any/c
        )
       (string?)
       any/c)

  ;;    'thnk' should generate an exception
  ;;    'msg'  is what test-more-check will report
  ;;    'pred' could be anything, but some types are handled specially:
  ;;        - string: Check if it is exactly the (non-boilerplate) exn message
  ;;        - proc:   Pass it the exn, see if it returns #t
  ;;        - regex:  Check if the regex matches the (exn message || string) thrown
  ;;        - etc:    Check if it's equal? to the exception
  (define (get-msg e) (if (exn? e) (exn-message e) e))
  (define (remove-exn-boilerplate s)
    (let* ([str (regexp-replace #px"^.+?expected: " (get-msg s) "")]
           [str (regexp-replace #px"(.+)\n.+$" str "\\1")])
      str))

  (define (accept-all e) #t)
  (define-values (e threw)
    (with-handlers ((exn:break? (lambda (e) (raise e))) ; if user hit ^C, don't eat it
                    (accept-all (lambda (e) (values e #t))))
      (values (thnk) #f)))

  (define pred-needs-string (or (string? pred) (regexp? pred)))
  (define e-can-be-string   (or (string? e) (exn? e)))
  (when (and pred-needs-string (not e-can-be-string))
    (raise-arguments-error 'throws
                           "predicate was (string or regexp) but thrown value was not (string or exn)"
                           "thrown value" e))

  (cond [(false? threw)    (test-more-check #:got #f  #:msg (~a msg " [DID NOT THROW]")  #:return e)]
        [(procedure? pred) (test-more-check #:msg msg #:got (and (pred e) #t) #:report-got-as e #:return e)]
        [(string? pred)    (test-more-check #:msg msg #:got (equal? pred (remove-exn-boilerplate e)) #:report-got-as e  #:return e)]
        [(regexp? pred)    (test-more-check #:msg msg #:got (regexp-match? pred (get-msg e)) #:report-got-as e  #:return e)]
        [else              (test-more-check #:msg msg #:got e  #:expected pred #:return e)]
        )
  )

;;----------------------------------------------------------------------

; (define/contract (dies thnk [msg ""])
;
; Use this when all you care about is that it dies, not why.
(define/contract (dies thnk [msg ""])
  (->* (procedure?)
       (string?)
       any/c)
  (throws thnk (lambda (e) #t) msg))

;;----------------------------------------------------------------------

; (test-suite ...)
;
; Group a bunch of tests together and give them an identity.  Trap
; exceptions that they throw and report on whether they threw.  Print
; header and footer banners so it's easy to tell where they
; start/finish.  Returns (void)
;
;    (test-suite
;      "user creation"
;
;      (lives (thunk (my-list)) "(my-list) lives")
;      (is (my-list) '() "(my-list) returns '()")
;      (is (my-list 7) '(7) "(my-list 7) returns '(7)")
;     )
;
;  The above code prints:
;
; ### START test-suite: user creation
; ok 1 - (my-list) lives
; ok 2 - (my-list) returns '()
; ok 3 - (my-list 7) returns '(7)
;
; Total tests passed so far: 3
; Total tests failed so far: 0
;
; ### END test-suite: user creation
;
(define-syntax (test-suite stx)
  (syntax-case stx ()
    [(_ msg body body1 ...)
     #'(begin (diag "START test-suite: " msg)
              (lives (thunk body body1 ...  (void)) ; discard return values
                     "test-suite completed without throwing uncaught exception")
              ;(say "")
              ;(say "Total tests passed so far: " (tests-passed))
              ;(say "Total tests failed so far: " (tests-failed))
              (diag "END test-suite: " msg))]))

;;----------------------------------------------------------------------


; (define/contract (make-test-file [fpath (make-temporary-file)]
;                                  [text (rand-val "test file contents")]
;                                  #:overwrite [overwrite #t])
;  (->* () (path-string? string? #:overwrite boolean?) path-string?)
;
; Creates (and, optionally, populates) a file for use by a test.
;
; If fpath is not specified it will default.  See make-temporary-file
; in the Racket docs for details.
;
; If fpath is an existing directory, a file with a random name will be
; created in that directory.
;;
; If fpath is a filepath and its directory does not exist then it will
; be created.
;
; Once we have decided on the filepath according to the above details,
; we check to see if the file exists.  If so, make-test-file will
; either throw an exception or overwrite the existing file depending
; on the value of 'overwrite'.  DEFAULT IS TO OVERWRITE because you're
; generating a file for testing and it's assumed that you know what
; you're doing.
;
; Note: Once you're done with your tests, you will need to manually
; delete the file that this creates unless you do something like this:
;
;    (require handy/utils)
;    (with-temp-file #:path (make-test-file)
;      (lambda (filepath)
;       ...the test file is at 'filepath' and has been created and populated...
;      )
;    )
;    ; After leaving the scope of the 'with-temp-file', the test file is
;    ; guaranteed to have been deleted because that's what with-temp-file does
;
; The file will be populated with the text you specify, or with some
; random text if you don't specify anything.  (Note that it's written
; via 'display', but you can use (make-test-file #:text (~v <data>))
; if that's what you want.
;
(define/contract (make-test-file [fpath (make-temporary-file)]
                                 #:text [text (rand-val "test file contents")]
                                 #:overwrite [overwrite #t])
  (->* () (path-string? #:text string? #:overwrite boolean?) path-string?)
  (define-values (dir fn ignore) (split-path fpath))

  (make-directory* dir) ; this doesn't fail if the directory exists, so no reason not to do it

  (define filepath
    (cond [(file-exists? fpath) fpath]
          [(directory-exists? fpath) (build-path fpath (rand-val "test-file"))]
          [else fpath]))

  (with-output-to-file
    filepath
    (thunk (display text))
    #:exists (if overwrite 'replace 'error))

  (path-string->string filepath))

;;----------------------------------------------------------------------

; (define/contract (done-testing)
;
; It can be a pain to count exactly how many tests you're going to
; run, especially if some of the tests are conditional.  If you simply
; put (done-testing) as the last line in your test file then test-more
; will assume that you completed correctly.
;
; If neither this nor expect-n-tests are seen before end of file, a
; warning will be reported when the tests are run.
;
; If both this and expect-n-tests are run, this wins; it will not
; check how many tests were run.
;
(define/contract (done-testing)
  (-> any)
  ;(say "Done.")
  (saw-done-testing #t))

;;----------------------------------------------------------------------

;(define/contract (diag . args)
;
; Variadic print statement that outputs the specified items with a
; standard prefix, stored in the 'prefix-for-diag' parameter.  By
; default this is "\t#### ", that's easy for test output analyzers to
; detect.  This prefix is prepended to the current value of the
; prefix-for-say parameter, so this:
;
;    (parameterize ([prefix-for-say "my awesome message"])
;        (diag "foobar"))
;
; ...is the same as (displayln "\t#### my awesome messagefoobar")
;
(define prefix-for-diag (make-parameter "######## "))
(define/contract (diag . args)
  (->* () () #:rest (listof any/c) any)
  (parameterize ([prefix-for-say (~a (prefix-for-diag)  (prefix-for-say))])
    (say args))) ; THIS IS NOT DEBUGGING

;;----------------------------------------------------------------------

; (define/contract (is-approx got expected [msg ""]
;                             #:threshold  [threshold 1]
;                             #:key        [extract-key identity]
;                             #:is-valid?  [is-valid? <=]
;                             #:abs-diff?  [abs-diff? #t])
;   (->* (any/c any/c)
;        (string?
;         #:threshold number?
;         #:key (-> any/c number?)
;         #:is-valid? (-> number? boolean?)
;         #:abs-diff? boolean?)
;        any/c)
;
;    is-valid?   determines if 'got' is within the threshold of 'expected'. See below.
;    key         A function that will generate a numeric value from each of 'got', 'expected'
;    threshold   How close do they need to be?  Default is 1.
;    abs-diff?   Use the absolute value of the difference?
;
; Test that two values ('got' and 'expected') are approximately the
; same within a certain threshold.  got and expected must either be
; numeric or you must provide a 'extract-key' function that generates an
; exact numeric value when given one of the values.  We then check if
; difference between those values is within the specified threshold.
; More specifically, we check if this is true:
;
;    (define diff (- (key expected) (key got)))
;    (is-valid? (if abs-diff? (abs diff) diff) threshold)
;
; is-valid will default to:
;    
;    abs-diff? #t   =>  (between/c -threshold +threshold)
;    abs-diff? #f   =>  (apply between/c (sort (list threshold 0) <))
;
; That is, when abs-diff? is #f, a positive threshold means the
; difference must be between 0 and threshold, while a negative
; threshold means the difference must be between the threshold and 0.
;
;
; Examples:
;
;    (define now (current-seconds)) ; epoch time
;    (is-approx  (and (myfunc) (current-seconds)) now "(myfunc) ran in no more than 1 second")
;
; (for ([num (in-range 3 7)])
;   (let ([data  (make-list num 'x)])
;     (is-approx  (length data)
;                 6
;                 #:threshold 3
;                 #:abs-diff? #f
;                 "data was a list of 3-6 elements")))
;
; (is-approx  (hash 'age 18)
;             (hash 'age 19)
;             #:key (curryr hash-ref 'age)
;             "user is between 18 and 20 years old")
;
; (is-approx  (hash 'age 17)
;             (hash 'age 18)
;             #:key (curryr hash-ref 'age)
;             #:threshold 3
;             #:abs-diff? #f
;             "user is not old enough.  acceptable range was 18-21, got 17")
;
; ;   The following is a silly example but it shows some of the
; ;   versatility.  The value being checked will be automatically
; ;   unwrapped, meaning the thunk will be called.
; (is-approx  (thunk "Foobar")
;             "f"
;             #:key (compose1 char->integer (curryr string-ref 0) string-downcase)
;             "(myfunc) returns a string that starts with 'f', 'F', 'g', or 'G'")
;
(define/contract (is-approx got expected [msg ""]
                            #:threshold  [threshold 1]
                            #:key        [extract-key identity]
                            #:is-valid?  [is-valid? #f]
                            #:abs-diff?  [abs-diff? #t]
                            )
  (->* (any/c any/c)
       (string?
        #:threshold number?
        #:key (-> any/c number?)
        #:is-valid? (-> number? boolean?)
        #:abs-diff? boolean?)
       any/c)

  (define is-within-threshold?
    (cond [(procedure? is-valid?) is-valid?]
          [abs-diff?       (apply between/c (sort (list (* -1 threshold) threshold) <))]
          [else            (apply between/c (sort (list 0 threshold) <))]))

  (define extract-key-name       (object-name extract-key))
  (define got-val         (unwrap-val got))
  (define expected-val    (unwrap-val expected))
  (define got-result      (extract-key got-val))
  (define expected-result (extract-key expected-val))

  ;(say "extract-key-name: " extract-key-name)
  ;(say "got-val: "   got-val)
  ;(say "expected-val: " expected-val)
  ;(say "got-result: " got-result)
  ;(say "expected-result: " expected-result)
  ;(say "threshold: " threshold)
  ;(say "abs-diff?: " abs-diff?)
  ;(say "is-valid?: " is-valid?)
  ;(say "is-within-threshold?: " is-within-threshold?)
  (when (not (andmap number? (list got-result expected-result)))
    (raise-arguments-error 'is-approx
                           "arguments to is-approx / isnt-approx must be numeric or you must use #:key to include a function that return a numeric measurement from 'got' and 'expected'"
                           "got" got
                           "expected" expected
                           "key" extract-key-name
                           "(key <got>)" got-result
                           "(key <expected>)" expected-result))

  (define diff (- got-result expected-result))
  ;(say "diff: " diff)
  ;(say "final result: "  (is-within-threshold? diff))
  (test-more-check #:got (is-within-threshold? diff)
                   #:expected #t
                   #:msg msg
                   #:report-expected-as (format "(~a ~a) => ~a (diff: ~a, abs-diff?: ~a, threshold: ~a)" extract-key-name (~v expected) expected-result diff abs-diff? threshold)
                   #:report-got-as (format "(~a ~a) => ~a" extract-key-name (~v got) got-result)
                   #:return diff)

  )

;;----------------------------------------------------------------------

; (define/contract (isnt-approx got expected [msg ""]
;                               #:threshold  [threshold 1]
;                               #:key        [extract-key identity]
;                               #:is-valid?  [is-valid? {{determined at runtime}}]
;                               #:abs-diff?  [abs-diff? #t])
;
; Same as is-approx but tests that it's outside the threshold
(define/contract (isnt-approx got expected  [msg ""]
                              #:threshold   [threshold 1]
                              #:key         [extract-key identity]
                              #:is-valid?   [is-valid? #f]
                              #:abs-diff?   [abs-diff? #t]
                              )
  (->* (any/c any/c)
       (string? #:threshold number?
                #:key (-> any/c exact?)
                #:is-valid?   (-> number? boolean?)
                #:abs-diff? boolean?)
       any/c)

  (define is-outside-threshold?
    (cond [(procedure? is-valid?) is-valid?]
          [abs-diff?       (not/c (apply between/c (sort (list (* -1 threshold)
                                                               threshold) <)))]
          [else            (not/c (apply between/c (sort (list 0 threshold) <)))]))

  (is-approx got expected msg
             #:threshold threshold
             #:key       extract-key
             #:is-valid? is-outside-threshold?
             #:abs-diff? abs-diff?)
  )

;;----------------------------------------------------------------------