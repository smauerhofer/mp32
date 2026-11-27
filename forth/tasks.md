# The tasks of the mp32 FORTH machine

Several FORTH tasks, as polyFORTH has them: **cooperative** and **round robin**. A
task runs until it calls `PAUSE` (by itself, or inside `KEY`, `EMIT`, `MS`, `GET`,
...); then the next task that is awake runs. No timer takes the processor away from
a task, so the tasks need no locks for the dictionary, the heap (CONS) or a
variable: between two `PAUSE`s a task is alone. Only the interrupt handlers come in
between, and they touch only their queues and the globals.

The layout of a task (its user area, its buffers, its stacks) is in `memory.md`, the
offsets in `memmap.inc`.

## The ring

The tasks are a ring through their user areas: `LINK` holds the next task's UP. COLD
makes OPERATOR, linked to itself. `TASK` / `TERMINAL` put a new task into the ring
right after OPERATOR. `STATUS` says whether a task is awake (1) or asleep (0).

    OPERATOR --LINK--> TIMER --LINK--> LOGGER --LINK--> OPERATOR ...

r31 (UP) is the running task. `PAUSE` goes round the ring from it to the next one
that is awake. If it gets round to where it started and no task is awake, it waits
for an interrupt (`WAIT`): an interrupt is the only thing that can wake a task then.
So an idle machine does not spin.

## What PAUSE saves

The processor keeps more of a task in registers than most do: T, S, R, and the
stack registers. A task between two words (at a call to `PAUSE`) owns:

| what | where it goes |
|---|---|
| T, S | pushed onto its parameter stack (two `DUP`s) |
| R (PAUSE's return address) | pushed onto its return stack (`PUSH`) |
| PSP, RSP, FP | `U_SPSAVE`, `U_RPSAVE`, `U_FPSAVE` |
| PSPL .. RSPH | already in its user area: only loaded, never saved |
| r0 .. r29 | nothing: they are scratch across a call, by convention |
| ST (the flags) | nothing: no flags live across a call |
| L, HLIM | nothing: the same for all tasks |

A sketch (not yet assembled; the loop's tests in words):

    PAUSE:  DUP                     ; S into memory, T into S
            DUP                     ; T into memory: T and S are saved
            PUSH                    ; R, where the task goes on, onto the return stack
            MOVR    T, PSP
            STR3    T, r31, U_SPSAVE
            MOVR    T, RSP
            STR3    T, r31, U_RPSAVE
            MOVR    T, FP
            STR3    T, r31, U_FPSAVE
            ; the next task that is awake:
            ;   r31 = LINK; while STATUS = 0: r31 = LINK
            ;   (round once with none awake: WAIT, then on)
            CLI                     ; no interrupt while the stacks change hands
            LDR3    T, r31, U_PSPL
            MOVR    PSPL, T         ; ... the same for PSPH, RSPL, RSPH
            LDR3    T, r31, U_FPSAVE
            MOVR    FP, T
            LDR3    T, r31, U_RPSAVE
            MOVR    RSP, T
            LDR3    T, r31, U_SPSAVE
            MOVR    PSP, T
            SEI
            POP                     ; R = where this task goes on (T: nothing)
            DROP
            DROP                    ; T, S back
            RET                     ; into the task

The `CLI` .. `SEI` keeps an interrupt out while the limits already belong to the new
task and a pointer still to the old one: a push of the handler there would trap. The
scan of the ring before it may be interrupted: the handler then runs on the old
task's return stack, which is still whole.

About 35 instructions from one task to the next. At 42 MHz, with the cache, that is
on the order of a microsecond: a task that calls `PAUSE` in every loop costs little.

## A new task

`ACTIVATE` makes a task's stacks look as if it had called `PAUSE` itself: on its
return stack the address of the code after `ACTIVATE`, on its parameter stack two
cells for T and S; `U_SPSAVE`, `U_RPSAVE` set, `STATUS` 1. The next round of `PAUSE`
starts it.

## Waking tasks from interrupts

A task waiting for input does not poll. `KEY` with the input queue empty puts its UP
into `IN-WAIT`, sets its `STATUS` to 0 and calls `PAUSE`. The serial port's handler
and the keyboard's handler put the character into the queue and, if `IN-WAIT` is not
0, set that task's `STATUS` to 1. `EMIT` with the output queue full does the same with
`OUT-WAIT` and the TX handler. A handler writes nothing but a `STATUS` (and its
queue): it never switches tasks itself.

## The words (polyFORTH style)

| word | stack | what |
|---|---|---|
| `TASK` | ( "name" -- ) | a background task: user area and stacks in the dictionary, put into the ring, asleep. `name` gives its UP |
| `TERMINAL` | ( "name" -- ) | the same, with TIB, WORD, HOLD and PAD: a task that can run the interpreter |
| `BUILD` | ( task -- ) | (again) its user area: stacks empty, limits, `BASE` 10, the buffers |
| `ACTIVATE` | ( task -- ) | the rest of the definition becomes the task's code; it starts at its next turn |
| `PAUSE` | ( -- ) | the next task that is awake runs |
| `STOP` | ( -- ) | the running task goes to sleep, then `PAUSE` |
| `WAKE` | ( task -- ) | `STATUS` 1 |
| `SLEEP` | ( task -- ) | `STATUS` 0 |
| `HALT` | ( task -- ) | it stops for good: `ACTIVATE` with `STOP` as its code |
| `GET` | ( facility -- ) | waits (with `PAUSE`) until the facility is free, then owns it |
| `GRAB` | ( facility -- ) | as `GET`, without the first `PAUSE` |
| `RELEASE` | ( facility -- ) | frees it, if this task owns it |
| `HIS` | ( task user -- addr ) | that task's copy of a user variable: `TIMER BASE HIS @` |
| `.TASKS` | ( -- ) | the ring: each task's name and whether it is awake |
| `USER` | ( "name" -- ) | a new user variable: the next free cell of every user area |

The facilities are `SCREEN`, `SERIAL` and `KEYS` (globals): a background task that
prints does `SCREEN GET ... SCREEN RELEASE`, so its lines do not run into
OPERATOR's.

An example, once it is there:

    TASK TIMER
    : TICKER  TIMER ACTIVATE  BEGIN  FRAMES @ 60 MOD 0= IF  [CHAR] . EMIT  THEN
              PAUSE  AGAIN ;
    TICKER                      \ a dot every second, while OPERATOR goes on
    TIMER HALT

## Later

- a second terminal: the serial port and the keyboard as two terminal tasks, each
  with its own `'KEY` and `'EMIT` (the user area has them already). Today both go
  through the one input queue, to whichever task waits in `KEY`.
- `MS` on `TICKS`, so a task can sleep for a time.
