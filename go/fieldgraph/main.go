// Command fieldgraph renders a struct/field read-write graph for a Go package,
// including call edges and file I/O boundaries.
package main

import (
	"bytes"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "fieldgraph:", err)
		os.Exit(1)
	}
}

type options struct {
	dir         string
	pkg         string
	out         string
	layout      string
	includeTest bool
	includeIO   bool
	showCalls   bool
	groupType   bool
	groupFile   bool
	focus       string
}

func run() error {
	cwd, err := os.Getwd()
	if err != nil {
		return fmt.Errorf("working dir: %w", err)
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		home = "."
	}

	dir := flag.String("dir", cwd, "module root of the analyzed project")
	pkg := flag.String("pkg", "./...", "package pattern to analyze")
	out := flag.String("out", "", "output base path; writes .dot and .svg (default: <tools>/go/out/<dir>)")
	tests := flag.Bool("tests", false, "include test files")
	withIO := flag.Bool("io", true, "include file read/write nodes")
	calls := flag.Bool("calls", false, "include call edges and the full function graph")
	group := flag.String("group", "file", "group sources by: file, type, func")
	layout := flag.String("layout", "", "Graphviz layout: dot, neato, sfdp, fdp (default: sfdp for file/type, dot for func)")
	focus := flag.String("focus", "", "only show structs whose name contains this text")
	flag.Parse()

	if *out == "" {
		dirName := filepath.Base(*dir)
		if absolute, absErr := filepath.Abs(*dir); absErr == nil {
			dirName = filepath.Base(absolute)
		}
		if dirName == "" || dirName == "." || dirName == string(filepath.Separator) {
			dirName = "graph"
		}
		*out = filepath.Join(home, "Projects", "orchengine-tools", "go", "out", dirName, "fieldgraph")
	}

	layoutName := *layout
	if layoutName == "" {
		layoutName = "sfdp"
		if *group == "func" {
			layoutName = "dot"
		}
	}

	base := strings.TrimSuffix(strings.TrimSuffix(*out, ".svg"), ".dot")
	opts := options{
		dir:         *dir,
		pkg:         *pkg,
		out:         base,
		layout:      layoutName,
		includeTest: *tests,
		includeIO:   *withIO,
		showCalls:   *calls,
		groupType:   *group == "type",
		groupFile:   *group == "file",
		focus:       *focus,
	}

	g, err := analyze(opts)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(opts.out), 0o755); err != nil {
		return fmt.Errorf("create output dir: %w", err)
	}

	dotPath := opts.out + ".dot"
	svgPath := opts.out + ".svg"
	if err := writeDOT(dotPath, g); err != nil {
		return err
	}

	args := []string{"-Tsvg", dotPath, "-o", svgPath}
	if opts.layout == "sfdp" || opts.layout == "neato" {
		args = append([]string{"-Goverlap=prism", "-Gsep=+8"}, args...)
	}
	cmd := exec.Command(opts.layout, args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s: %w: %s", opts.layout, err, strings.TrimSpace(stderr.String()))
	}

	fmt.Printf("functions: %d\n", g.count(nodeFunc))
	fmt.Printf("files:     %d\n", g.count(nodeFile))
	fmt.Printf("structs:   %d\n", g.count(nodeStruct))
	fmt.Printf("edges:     %d\n", len(g.edges))
	fmt.Printf("dot:       %s\nsvg:       %s\n", dotPath, svgPath)
	return nil
}
