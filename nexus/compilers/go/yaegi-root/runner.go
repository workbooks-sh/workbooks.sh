package main

import (
	"fmt"
	"os"

	"github.com/traefik/yaegi/interp"
	"github.com/traefik/yaegi/stdlib"
)

// yaegi-runner (wb-fm0.5): interpret an untrusted Go program ENTIRELY in the wasm sandbox.
// argv[1] = path to the Go source; the program's own I/O flows over stdin/stdout/stderr.
func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: yaegi-run <file.go>")
		os.Exit(2)
	}
	src, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, "read:", err)
		os.Exit(2)
	}
	// Give the interpreted program a clean os.Args: drop the source path so it sees
	// [prog, <user args…>] — the universal CLI ABI, same as a compiled binary would.
	progArgs := append([]string{"prog"}, os.Args[2:]...)
	os.Args = progArgs
	i := interp.New(interp.Options{Args: progArgs, Stdin: os.Stdin, Stdout: os.Stdout, Stderr: os.Stderr})
	if err := i.Use(stdlib.Symbols); err != nil {
		fmt.Fprintln(os.Stderr, "use:", err)
		os.Exit(2)
	}
	if _, err := i.Eval(string(src)); err != nil {
		fmt.Fprintln(os.Stderr, "eval:", err)
		os.Exit(1)
	}
}
