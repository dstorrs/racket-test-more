(provide prefix-for-test-report ; parameter printed at start of each test
         prefix-for-diag        ; parameter printed at front of each (diag ...) message
         ok                ; A value is true
         not-ok            ; A value is false
         is-false          ; Alias for not-ok
         is                ; A value is what it should be
         isnt              ; ...or is not what it shouldn't be
         like              ; A value matches a regex
         unlike            ; A value does not match a regex
         lives             ; expression does not throw an exception
         dies              ; expression does throw an exception
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
         current-test-num  ; return current test number
         ;  You generally should not be using these, but you can if you want
         inc-test-num!     ; tests start at 1.  Use this to change test number (but why?)
         next-test-num     ; return next test number and optionally modify it

;;======================================================================
;;    The racket testing module has a few things I wish it did differently:
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
;;
;; This module addresses those problems.  It's named for, and largely a
;; clone of, the Test::More library on Perl's CPAN, although some
;; of the Perl version's features are not implemented.
;;
;; http://search.cpan.org/~exodist/Test-Simple-1.302120/lib/Test/More.pm
;; for more details on the original.
;;
;;    TODO:
;; - Add 'disable this test suite' keyword
;; - Add 'TODO this test suite' keyword
;; - Fix the issue where it sometimes shows 'expected #f got #f'
;; - On test-suite, add 'setup' and 'cleanup' keywords that take thunks
;;======================================================================
; Parameter: prefix-for-test-report
; Default: ""
;
; Set this to put a prefix on some or all of your tests.  Example:
;
;    (parameterize ([prefix-for-test-report "TODO: "])
;        ...tests...)
;;----------------------------------------------------------------------
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
; Typically, if you use this you would set it at top of file and then
; not modify it.  One reason that you might change it pater would be
; if you had some conditional tests that you determined should be
; skipped.
;
;----------------------------------------------------------------------
; tests-passed
;
; Set or get the number of tests passed  and failed.
;
; Call as (tests-passed) to get the number, (tests-passed 2) to add 2
; to the number and return it.
;
; DON'T CHANGE THE TEST NUMBERS UNLESS YOU KNOW WHAT YOU'RE DOING.
;
;----------------------------------------------------------------------
;
; Functions associated with the test number.
;
;    In normal cases, there is no reason to touch these.
;
;    ; parameter that tracks current number
;    current-test-num      
;
;    ; update the test number.  
;    (inc-test-num! inc)   ; increase the current test number by 'inc'
;
;    ; Get and, by default, increment the test number by 1
;    (next-test-num #:inc [should-increment #t])  
;
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
;
; The 'got' value will be sent through handy/utils 'unwrap-val'
; function before use, meaning that:
;
;    - If it's a procedure,   it will be executed with no arguments
;    - If it's a promise,     it will be forced
;    - If it's anything else, it will be used as is
;
; In the first two cases, whatever is returned will be the actual
; value used.
;
;;----------------------------------------------------------------------
; (ok got [msg ""])
; (not-ok got [msg ""])   ; opposite of ok
; (is-false got [msg ""]) ; alias for not-ok; reads better in some cases
;
; Simple boolean check.  Was the value of 'got' true? (i.e., it wasn't #f)
;    (ok 7)        ; success.  returns 7. prints just the normal "ok <test-num>" banner
;    (ok #f)       ; fail.  returns #f
;    (ok 7 "foo")  ; success, returns 7, prints "ok <test-num> - foo"
;
;    (not-ok #f)   ; success. Returns #t on success, #f on failure
;    (is-false #f) ; same as previous
;
;;----------------------------------------------------------------------
; (matches val predicate [msg ""] [op equal?])
; (not-matches val predicate [msg ""] [op equal?]) ; opposite of matches
;
; is-type    ; alias for matches
; isnt-type  ; alias for not-matches
;
; Verify that the value of 'got' does / does not match the predicate
;
;    (matches (my-func) hash? "(my-func) returns a hash")
;    (is-type (my-func) hash? "(my-func) returns a hash")
;
;    (not-matches 'foo hash? "symbol foo is not a hash")
;    (isnt-type 'foo hash? "symbol foo is not a hash")
;
;;----------------------------------------------------------------------
; (is val expected [msg ""] <optional comparison func> #:op <optional comparison func>)
; (isnt val expected [msg ""] <optional comparison func> #:op <optional comparison func>)
;
;    (is x 8 "x is 8")
;    (is (myfunc 7) 8 "(myfunc 7) returns 8")
;    (is x 8 "x is 8" =)       ; use = instead of equal? for comparison
;    (is x 8 "x is 8" #:op =)  ; use = instead of equal? for comparison
;
; The bread and butter of test-more.  Asks if two values are / not  the same
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
;;----------------------------------------------------------------------
; (like val regex [msg ""])   ; Returns the result of the regexp match
; (unlike val regex [msg ""]) ; Returns #t or #f
;
; Checks that the value does/doesn't match a regex. 
;
;;----------------------------------------------------------------------
; (lives thnk [msg ""])
;
; Verify that a thunk will run without throwing an exception.  The
; thunk may contain other tests.
;
;;----------------------------------------------------------------------
; (throws thnk pred [msg ""])
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
; the exception message (assuming there is an exception).
; If #:strip-message? is true then everything up to the first
; "expected: " is snipped off, as is everything after the last \n
;
;;----------------------------------------------------------------------
; (dies thnk [msg ""])
;
; Use this when all you care about is that it dies, not why.
;
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
;;----------------------------------------------------------------------
; (done-testing)
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
;;----------------------------------------------------------------------
; (diag . args)
;
; Variadic print statement that outputs the specified items with a
; standard prefix, stored in the 'prefix-for-diag' parameter.  By
; default this is "\t#### ", that's easy for test output analyzers to
; detect.  This prefix is prepended to the current value of the
; prefix-for-say parameter, so this:
;
;    (parameterize ([prefix-for-diag "my awesome message is: "])
;        (diag "foobar"))
;
; ...is the same as (displayln "\t#### my awesome message is: foobar")
;
; NB: This value is actually prepended to the prefix-for-say from
;  handy/utils.  That's normally "", but if it's been set then you'll
;  see something different than stated above.
;
;;----------------------------------------------------------------------
; (is-approx got expected [msg ""]
;            #:threshold  [threshold 1]
;            #:key        [key identity]
;            #:compare    [compare #f] ; value based on threshold
;            #:abs-diff?  [abs-diff? #t])
;   (->* (any/c any/c)
;        (string?
;         #:threshold any/c
;         #:key (-> any/c any/c)              ; (key got)  (key expected)
;         #:compare (-> any/c any/c any/c)    ; (compare diff threshold)
;         #:diff-with (-> any/c any/c any/c)  ; (diff-with  got expected)
;         #:abs-diff? boolean?)               ; use abs on diff before compare
;        any/c)
;
;    threshold   How close do they need to be?  Default is 1.
;    key         Function that generates a (usually numeric, but could be anything)
;                     value from each of 'got', 'expected'
;    compare     two arguments, diff and threshold, returning anything. true
;                     return value means success
;    abs-diff?   Use the absolute value of the difference?  Determines the acceptable ranges.
;
; Test that two values ('got' and 'expected') are approximately the
; same within a certain threshold.
;
; 'got' and 'expected' can be anything, but will usually be numbers.
; You may provide a 'key' function that generates a new value based on
; the value of 'got' and 'expected'
;
; If you don't provide a #:compare function, then it will assume that
; the values are numeric and the default acceptable ranges will depend
; on the value of threshold and abs-diff?:
;
;   abs-diff?   threshold   default value for compare (argument is diff or abs(diff))
;    #t/#f         0          (= 0 diff)
;    #t           != 0        (<= diff (abs threshold))
;    #f           < 0         ((between/c threshold   0) diff)
;    #f           > 0         ((between/c 0 threshold) diff)
;
; Examples:
;
;    (define now (current-seconds)) ; epoch time
;    (is-approx  (and (myfunc) (current-seconds)) now "(myfunc) ran in no more than 1 second")
;
; (for ([num (in-range 3 7)])
;   (let ([myfunc (thunk (make-list num 'x))])
;     (is-approx  (length (myfunc))
;                 3
;                 #:threshold 3
;                 #:abs-diff? #f
;                 "(myfunc) => list of 3-6 elements")))
; (is-approx  (hash 'age 8)
;             (hash 'age 9)
;             #:key (curryr hash-ref 'age)
;             "age is about 9")
;
; ;  More complex examples:
; (is-approx  ((thunk "Foobar"))
;             "f"
;             #:key (compose1 char->integer (curryr string-ref 0) string-downcase)
;             "(myfunc) returns a string that starts with 'f', 'F', 'g', or 'G'")
;
; (is-approx  (hash 'username "tom")
;             (hash 'username "tomas")
;             #:key  (curryr hash-ref 'username)
;             #:abs-diff? #f
;             #:diff-with  (lambda (got expected) (regexp-match (regexp got) expected))
;             #:compare (lambda (diff threshold) (not (false? diff)))
;             "first username matched part of second username")
;
;;----------------------------------------------------------------------
; (define/contract (isnt-approx got expected [msg ""]
;                             #:threshold  [threshold 1]
;                             #:key        [key identity]
;                             #:compare    [compare #f] ; value based on threshold
;                             #:abs-diff?  [abs-diff? #t])
;   (->* (any/c any/c)
;        (string?
;         #:threshold any/c
;         #:key (-> any/c any/c)              ; (key got)  (key expected)
;         #:compare (-> any/c any/c any/c)    ; (compare diff threshold)
;         #:diff-with (-> any/c any/c any/c)  ; (diff-with  got expected)
;         #:abs-diff? boolean?)               ; use abs on diff before compare
;        any/c)
;
; Same as is-approx but tests that it's outside the threshold
;
;;----------------------------------------------------------------------
