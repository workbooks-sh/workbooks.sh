// yaegi-runner WITH GoPath (the go-mod reclaim variant of compilers/go/yaegi-root/runner.go).
// Identical to the shipped runner EXCEPT it threads interp.Options{GoPath: env(WBGOPATH)} so the
// interpreter resolves third-party imports from on-disk GOPATH/src — the one runner change the
// resolved.json reclaim recipe calls for. Cross-compiled to wasm32-wasip1 by the NATIVE Go toolchain
// (trusted one-time provisioning); at runtime it INTERPRETS untrusted Go entirely in the wasm sandbox.
package main

import (
	"fmt"
	"os"

	"github.com/traefik/yaegi/interp"
	"github.com/traefik/yaegi/stdlib"
)

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
	progArgs := append([]string{"prog"}, os.Args[2:]...)
	os.Args = progArgs
	i := interp.New(interp.Options{
		GoPath: os.Getenv("WBGOPATH"),
		Args:   progArgs,
		Stdin:  os.Stdin,
		Stdout: os.Stdout,
		Stderr: os.Stderr,
	})
	if err := i.Use(stdlib.Symbols); err != nil {
		fmt.Fprintln(os.Stderr, "use:", err)
		os.Exit(2)
	}
	if _, err := i.Eval(string(src)); err != nil {
		fmt.Fprintln(os.Stderr, "eval:", err)
		os.Exit(1)
	}
}
