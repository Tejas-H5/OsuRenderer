debug-build: $(wildcard ./*.odin)
	odin build . -out:out/debug/program.exe -o=none -strict-style -debug

debug-run: debug-build
	out/debug/program.exe


release-build: $(wildcard ./*.odin)
	odin build . -out:out/release/program.exe -o=speed -strict-style

release-run: release-build
	out/release/program.exe