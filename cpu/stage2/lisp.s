; lisp.s: the program of lisp_tb.v, a test of the LISP opcodes through the whole
; pipeline. The tags: 00 fixnum (n * 4), 01 cons, 11 immediate (NIL = 3).
;
; lisp.hex holds its CODE bytes from address 0, one per line, padded to 1 KB: the bytes
; of the listing of
;   mp32as -o build/lisp.o -l build/lisp.lst lisp.s
; The vector table is at 0 (VEC: lisp_tb.v gives execute VEC_RESET = 0): at 0 the
; reset (a jump to start), at $10 (VEC + 16, exception 4) the GC handler.
;
; What lisp_tb.v checks at the end:
;   r2 = 24   the sum of (1 2 3) as a fixnum (6 * 4)
;   r5 = 6    the sum untagged (ASRI 2)
;   r7 = 1    the GC handler ran once (the third CONS trapped)
;   r4 bit 3  V after TADD of a non-fixnum (5 + 5): 1
;   r6 = 40   the car of the list after RPLACA (fixnum 10)
;   r8 = 8    the car of the cdr (fixnum 2)
;   r9 = 1    the heap limit was passed: HLIM was raised by the handler

NIL = 3

        CBR     A, start        ; $0: vector 0, the reset
        .align  16

; ---- the GC handler ($10: exception 4, the trap of CONS): the CONS that trapped comes
; back with RET. It must keep T and S (the car and the cdr of the CONS). It raises HLIM
; to $1F9 (cells up to $1F8).
gc:     INCR    r7
        MOVI2   r1, $7E
        ADD2    r1, r1          ; $FC
        ADD2    r1, r1          ; $1F8
        INCR    r1              ; $1F9
        MOV2    HLIM, r1
        RET

start:
        LIT16   $200
        MOVR    PSP, T          ; the parameter stack: from $200 down
        LIT16   $3F0
        MOVR    RSP, T          ; the return stack: from $3F0 down
        LIT16   $101
        MOVR    L, T            ; the heap: the first cell at $100 (tagged $101)
        LIT8    $09
        MOVR    HLIM, T         ; room for 2 cells ($101, $109): the third CONS traps
        MOVI2   r7, 0           ; GC count

        ; (1 2 3), built from the end
        LIT8    NIL             ; T = NIL
        DUP
        LIT8    12              ; S = NIL, T = 3 (fixnum)
        SWAP
        CONS                    ; T = (3)
        DUP
        LIT8    8
        SWAP
        CONS                    ; T = (2 3)
        DUP
        LIT8    4
        SWAP
        CONS                    ; T = (1 2 3): traps first, the handler makes room
        MOVR    r6, T           ; keep the list

        ; the sum, as fixnums
        MOVI2   r2, 0
loop:   TTAG    3, 1            ; a cons?
        CBR     NE, done
        DUP
        CAR                     ; S = the list, T = its car
        DUP
        MOVR    T, r2           ; S = the car, T = the sum
        TADD                    ; T = car + sum, S = the list
        CBR     VS, bad
        MOVR    r2, T
        DROP                    ; T = the list
        CDR
        CBR     A, loop
done:   MOVR    T, r2
        ASRI    2               ; untag
        MOVR    r5, T

        ; TADD of a value that is not a fixnum: V
        LIT8    5
        DUP
        TADD
        MOVR    T, ST
        MOVR    r4, T

        ; RPLACA: the car of the list = 10
        MOVR    T, r6           ; T = the list
        DUP
        LIT8    40
        SWAP                    ; S = 40, T = the list
        RPLACA
        CAR
        MOVR    r6, T           ; 40
        ; the car of the cdr (needs the list again: it is in memory at $111)
        LIT16   $111
        CDR
        CAR
        MOVR    r8, T           ; 8

        ; did HLIM go up?
        MOVR    T, HLIM
        MOVR    r1, T
        MOVI2   r9, 0
        CMP2    r1, r7          ; HLIM > 1
        CBR     LS, end
        MOVI2   r9, 1
end:    CBR     A, end

bad:    MOVI2   r2, -1
        CBR     A, end
