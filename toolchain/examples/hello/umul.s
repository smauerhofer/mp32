; umul.s - unsigned 32 x 32 -> 64 multiply, Forth's UM*.
;
;   umul ( a b -- lo hi )

        .export umul

        .code
umul:   MUL                     ; S = hi, T = lo
        SWAP
        RET
