; loop.s: the program of loop_tb.v, a test of the counted loops UNEXT, NEXT2 and NEXT3
; (and the NEXT pseudo-instruction) through the whole pipeline, with real backward
; branches.
;
; loop.hex holds its CODE bytes from address 0, one per line, padded to 1 KB: the bytes
; of the listing of
;   mp32as -o build/loop.o -l build/loop.lst loop.s
;
; The rule of all three: if the counter is not 0, counter = counter - 1 and branch;
; if it is 0, fall through (for R: drop it, the return stack is popped into R).
; So a count of n runs the body n + 1 times (as Forth's FOR .. NEXT).
;
; What loop_tb.v checks at the end:
;   r1  = 5     UNEXT with R = 4: the body ran 5 times
;   r3  = $55   R after that UNEXT loop: the word below was popped into R
;   r4  = 0     NEXT2's counter at the end (it stays 0)
;   r5  = 10    NEXT2 with r4 = 9, a body longer than a line: 10 times
;   r6  = 3     NEXT3 with R = 2, a body of more than 127 bytes: 3 times
;   r11 = $66   R after that NEXT3 loop (dropped)
;   r9  = 6     nested: NEXT r8 (3 times) around UNEXT (2 times each)
;   r8  = 0
;   r10 = 0     NEXT2 with a counter of 0: no branch, the counter stays 0
;   r12 = 1     ... and its body ran once
;   R   = $66, RSP = $3E8 (two words on the return stack: what R was at the start, $55)

start:
        LIT16   $200
        MOVR    PSP, T          ; the parameter stack: from $200 down
        LIT16   $3F0
        MOVR    RSP, T          ; the return stack: from $3F0 down
        MOVI2   r1, 0
        MOVI2   r5, 0
        MOVI2   r6, 0
        MOVI2   r9, 0
        MOVI2   r12, 0

        ; ---- 1: UNEXT, R = 4: the body 5 times; then R = $55 again
        LIT8    $55
        PUSH                    ; R = $55
        LIT8    4
        PUSH                    ; R = 4, $55 below it
        .align  16
u1:     INCR    r1
        UNEXT   u1
        MOV2    r3, R           ; $55

        ; ---- 2: NEXT2 on r4 = 9, a body of more than a line: 10 times
        MOVI2   r4, 9
n2:     INCR    r5
        .rept   20
        NOP
        .endr
        NEXT2   r4, n2

        ; ---- 3: NEXT3 on R = 2, a body of more than 127 bytes: 3 times; R dropped
        LIT8    $66
        PUSH                    ; R = $66
        LIT8    2
        PUSH                    ; R = 2
n3:     INCR    r6
        .rept   150
        NOP
        .endr
        NEXT3   R, n3
        MOV2    r11, R          ; $66

        ; ---- 4: nested: NEXT r8 = 2 (3 times) around UNEXT R = 1 (2 times)
        MOVI2   r8, 2
outer:  LIT8    1
        PUSH                    ; R = 1
        .align  16
inner:  INCR    r9
        UNEXT   inner           ; R dropped: $66 again
        NEXT    r8, outer       ; the pseudo-instruction: NEXT2 here

        ; ---- 5: NEXT2 with a counter of 0: the body once, no branch
        MOVI2   r10, 0
z:      INCR    r12
        NEXT2   r10, z

        .align  16
done:   CJMPL   A, done
