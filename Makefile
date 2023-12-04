debug-build: $(wildcard ./*.odin)
	odin build . -out:out/debug/program.exe -o=none -strict-style -debug

debug-run:
	out/debug/program.exe

debug-build-run: debug-build debug-run

release-build: $(wildcard ./*.odin)
	odin build . -out:out/release/program.exe -o=speed -strict-style

release-run:
	out/release/program.exe

release-build-run: release-build release-run