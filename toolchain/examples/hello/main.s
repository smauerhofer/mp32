; main.s - a first program for the mp32: 1000 / 7 * 6, with the arithmetic
; taken from the library math.lib (udiv.s, umul.s).
;
; The processor starts at $F0000000, the block RAM: the linker puts CODE there
; first, so 'reset' is the first instruction. The result (852 = $354) ends up in
; r1 and in T; the program then stops in a loop.

        .import udiv, umul

; push a constant: ( -- n )
.macro PUSHLIT n
        DUP
        LIT     n
.endmacro

        .code
reset:  LEA     pstack_top      ; the stacks live in BSS, in the block RAM
        MOVR    PSP, T
        LEA     rstack_top
        MOVR    RSP, T

        PUSHLIT 1000
        PUSHLIT 7
        CALL    udiv            ; ( 1000 7 -- 142 )
        PUSHLIT 6
        CALL    umul            ; ( 142 6 -- 852 0 )
        DROP                    ; ( 852 )
        MOVR    r1, T

        .align  16              ; keep the loop in one line: CJMPL needs it
halt:   CJMPL   A, halt

        .bss
pstack:     .res 252            ; parameter stack, grows down
pstack_top: .res 4
rstack:     .res 252            ; return stack, grows down
rstack_top: .res 4
