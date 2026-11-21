#!/bin/bash
# make.sh: puts the Makefiles in place, then runs make in mp32/cpu.
#
#   ./make.sh               rename every Makefile.txt to Makefile, then make test
#   ./make.sh test-stage1   the same, then make test-stage1 (any make target works)
#   ./make.sh clean         the same, then make clean
#
# Run it in Git Bash. It needs make and iverilog (with vvp) on the PATH.

set -e
cd "$(dirname "$0")"

# Claude writes new Makefiles as Makefile.txt; a newer one replaces the old Makefile.
for f in Makefile.txt stage*/Makefile.txt; do
    [ -f "$f" ] || continue
    mv -f "$f" "${f%.txt}"
    echo "$f -> ${f%.txt}"
done

for tool in make iverilog vvp; do
    if ! command -v "$tool" > /dev/null; then
        echo "$tool not found: install it or add it to the PATH" >&2
        exit 1
    fi
done

make "${@:-test}"
