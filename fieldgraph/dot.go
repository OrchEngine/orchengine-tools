package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"
	"strings"
)

func writeDOT(path string, g *graph) error {
	file, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("create %s: %w", path, err)
	}
	defer file.Close()

	w := bufio.NewWriter(file)
	fmt.Fprintln(w, "digraph fieldgraph {")
	fmt.Fprintf(w, "\tgraph [rankdir=LR, bgcolor=\"white\", fontname=\"Helvetica\", fontsize=10, labelloc=t, label=%s, nodesep=0.4, ranksep=0.7, compound=true, labelfloat=true];\n", dotQuote(g.title))
	fmt.Fprintln(w, "\tnode [fontname=\"Helvetica\", fontsize=9];")
	fmt.Fprintln(w, "\tedge [fontname=\"Helvetica\", fontsize=7, arrowsize=0.7];")

	writeLegend(w)
	writeClusters(w, g)
	writeEdges(w, g)

	fmt.Fprintln(w, "}")
	if err := w.Flush(); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	return nil
}

func writeLegend(w io.Writer) {
	fmt.Fprintln(w, "\tsubgraph cluster_legend {")
	fmt.Fprintln(w, "\t\tlabel=\"legend\"; style=\"rounded\"; color=\"#d0d7de\"; fontsize=9;")
	fmt.Fprint(w, "\t\tlegend [shape=plaintext, label=<<TABLE BORDER=\"0\" CELLBORDER=\"0\" CELLSPACING=\"0\" CELLPADDING=\"3\">")
	fmt.Fprint(w, "<TR><TD ALIGN=\"LEFT\"><FONT COLOR=\"#8c959f\">&#9632;</FONT> function</TD></TR>")
	fmt.Fprint(w, "<TR><TD ALIGN=\"LEFT\"><FONT COLOR=\"#8250df\">&#9632;</FONT> file (methods + functions)</TD></TR>")
	fmt.Fprint(w, "<TR><TD ALIGN=\"LEFT\"><FONT COLOR=\"#6aa84f\">&#9632;</FONT> struct and fields</TD></TR>")
	fmt.Fprint(w, "<TR><TD ALIGN=\"LEFT\"><FONT COLOR=\"#1a73e8\">&#9472;</FONT> read field</TD></TR>")
	fmt.Fprint(w, "<TR><TD ALIGN=\"LEFT\"><FONT COLOR=\"#d93025\">&#9472;</FONT> write field</TD></TR>")
	fmt.Fprint(w, "<TR><TD ALIGN=\"LEFT\"><FONT COLOR=\"#e37400\">&#9472;</FONT> file read/write</TD></TR>")
	fmt.Fprintln(w, "</TABLE>>];")
	fmt.Fprintln(w, "\t}")
}

func writeClusters(w io.Writer, g *graph) {
	byPackage := make(map[string][]string)
	var ioNodes []string
	for id, n := range g.nodes {
		if n.Kind == nodeIO {
			ioNodes = append(ioNodes, id)
			continue
		}
		byPackage[n.Package] = append(byPackage[n.Package], id)
	}

	packages := make([]string, 0, len(byPackage))
	for path := range byPackage {
		packages = append(packages, path)
	}
	sort.Strings(packages)

	for index, path := range packages {
		fmt.Fprintf(w, "\tsubgraph cluster_%d {\n", index)
		fmt.Fprintf(w, "\t\tlabel=%s;\n", dotQuote(shortPackage(path, g.module)))
		color := "#c9d1d9"
		style := "rounded"
		if g.target[path] {
			color = "#57606a"
			style = "rounded,bold"
		}
		fmt.Fprintf(w, "\t\tstyle=%s; color=%s;\n", dotQuote(style), dotQuote(color))

		ids := byPackage[path]
		sort.Strings(ids)
		for _, id := range ids {
			writeNode(w, g.nodes[id], "\t\t")
		}
		fmt.Fprintln(w, "\t}")
	}

	if len(ioNodes) > 0 {
		sort.Strings(ioNodes)
		fmt.Fprintln(w, "\tsubgraph cluster_io {")
		fmt.Fprintln(w, "\t\tlabel=\"file I/O\"; style=\"rounded\"; color=\"#e37400\";")
		for _, id := range ioNodes {
			writeNode(w, g.nodes[id], "\t\t")
		}
		fmt.Fprintln(w, "\t}")
	}
}

func writeNode(w io.Writer, n *node, indent string) {
	switch n.Kind {
	case nodeFunc:
		fmt.Fprintf(w, "%s%s [shape=box, style=\"rounded,filled\", fillcolor=\"#eef2f7\", color=\"#8c959f\", label=%s, tooltip=%s];\n",
			indent, dotID(n.ID), dotQuote(n.Label), dotQuote(n.Detail))
	case nodeStruct:
		fmt.Fprintf(w, "%s%s [shape=plaintext, label=%s, tooltip=%s];\n",
			indent, dotID(n.ID), structLabel(n), dotQuote(n.Detail))
	case nodeFile:
		fmt.Fprintf(w, "%s%s [shape=box, style=\"filled,rounded\", fillcolor=\"#f3e8fd\", color=\"#8250df\", label=%s, tooltip=%s];\n",
			indent, dotID(n.ID), dotQuote(n.Label), dotQuote(n.Detail))
	case nodeIO:
		fmt.Fprintf(w, "%s%s [shape=note, style=\"filled\", fillcolor=\"#fff3cd\", color=\"#e37400\", label=%s];\n",
			indent, dotID(n.ID), dotQuote(n.Label))
	}
}

func structLabel(n *node) string {
	var b strings.Builder
	b.WriteString(`<<TABLE BORDER="0" CELLBORDER="0" CELLSPACING="0" CELLPADDING="3">`)
	fmt.Fprintf(&b, `<TR><TD BGCOLOR="#d9ead3" ALIGN="LEFT"><B>%s</B></TD></TR>`, htmlEscape(n.Label))
	if len(n.Fields) == 0 {
		if n.Omitted > 0 {
			b.WriteString(`<TR><TD ALIGN="LEFT"><I>(no field access)</I></TD></TR>`)
		} else {
			b.WriteString(`<TR><TD ALIGN="LEFT"><I>(no fields)</I></TD></TR>`)
		}
	}
	for _, field := range n.Fields {
		fmt.Fprintf(&b, `<TR><TD PORT="%s" ALIGN="LEFT">%s <FONT COLOR="#57606a">%s</FONT></TD></TR>`,
			field.Port, htmlEscape(field.Name), htmlEscape(field.Type))
	}
	if n.Omitted > 0 && len(n.Fields) > 0 {
		fmt.Fprintf(&b, `<TR><TD ALIGN="LEFT"><I>&#8230; %d more fields</I></TD></TR>`, n.Omitted)
	}
	b.WriteString(`</TABLE>>`)
	return b.String()
}

func writeEdges(w io.Writer, g *graph) {
	edges := make([]edge, len(g.edges))
	copy(edges, g.edges)
	sort.SliceStable(edges, func(i, j int) bool {
		if edges[i].From != edges[j].From {
			return edges[i].From < edges[j].From
		}
		if edges[i].To != edges[j].To {
			return edges[i].To < edges[j].To
		}
		if edges[i].Port != edges[j].Port {
			return edges[i].Port < edges[j].Port
		}
		return edges[i].Kind < edges[j].Kind
	})

	for _, e := range edges {
		to := dotID(e.To)
		if e.Port != "" {
			to += ":" + e.Port
		}
		attrs := edgeAttrs(e)
		if e.Tooltip != "" {
			attrs += ", tooltip=" + dotQuote(e.Tooltip)
		}
		fmt.Fprintf(w, "\t%s -> %s [%s];\n", dotID(e.From), to, attrs)
	}
}

func edgeAttrs(e edge) string {
	label := e.Label
	switch e.Kind {
	case edgeCall:
		return `color="#8c959f", penwidth=1`
	case edgeRead:
		if label == "" {
			label = "read"
		}
		return fmt.Sprintf(`color="#1a73e8", penwidth=1.2, label=%s`, dotQuote(label))
	case edgeWrite:
		if label == "" {
			label = "write"
		}
		return fmt.Sprintf(`color="#d93025", penwidth=1.6, label=%s`, dotQuote(label))
	case edgeIORead:
		return `color="#e37400", style=dashed, penwidth=1.2, label="reads file"`
	case edgeIOWrite:
		return `color="#e37400", style=dashed, penwidth=1.2, label="writes file"`
	default:
		return `color="#8c959f"`
	}
}

func shortPackage(path, module string) string {
	if module != "" {
		if path == module {
			return "."
		}
		if strings.HasPrefix(path, module+"/") {
			return strings.TrimPrefix(path, module+"/")
		}
	}
	if index := strings.LastIndex(path, "/"); index >= 0 {
		return path[index+1:]
	}
	return path
}

func dotID(value string) string {
	return strconv.Quote(value)
}

func dotQuote(value string) string {
	return strconv.Quote(value)
}

var htmlReplacer = strings.NewReplacer(
	"&", "&amp;",
	"<", "&lt;",
	">", "&gt;",
	`"`, "&quot;",
)

func htmlEscape(value string) string {
	return htmlReplacer.Replace(value)
}
