# The mp32 toolchain: assembler (mp32as), librarian (mp32ar), linker (mp32ld),
# boot image maker (mp32img).
# Needs the .NET 10 SDK (it comes with Visual Studio 2026).

CONFIG ?= Release
RID ?= win-x64

all: build

build:
	dotnet build Mp32.Toolchain.slnx -c $(CONFIG)

test:
	dotnet test Mp32.Toolchain.slnx -c $(CONFIG)

# the four tools as executables in bin/
publish:
	dotnet publish src/Mp32.Assembler -c $(CONFIG) -r $(RID) --self-contained false -o bin
	dotnet publish src/Mp32.Librarian -c $(CONFIG) -r $(RID) --self-contained false -o bin
	dotnet publish src/Mp32.Linker    -c $(CONFIG) -r $(RID) --self-contained false -o bin
	dotnet publish src/Mp32.Image     -c $(CONFIG) -r $(RID) --self-contained false -o bin

example: publish
	$(MAKE) -C examples/hello -f Makefile.txt

clean:
	dotnet clean Mp32.Toolchain.slnx
	rm -rf bin
	$(MAKE) -C examples/hello -f Makefile.txt clean

.PHONY: all build test publish example clean
