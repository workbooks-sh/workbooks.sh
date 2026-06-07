package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strings"
)

// A tiny WASI CLI: prefixes each stdin line with argv[0] (default ">").
// Proves argv + stdin -> stdout under TinyGo wasip1.
func main() {
	prefix := ">"
	if len(os.Args) > 1 {
		prefix = os.Args[1]
	}
	data, _ := io.ReadAll(bufio.NewReader(os.Stdin))
	for _, line := range strings.Split(strings.TrimRight(string(data), "\n"), "\n") {
		fmt.Printf("%s %s\n", prefix, line)
	}
}
