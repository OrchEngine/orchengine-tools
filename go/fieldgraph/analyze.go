package main

import (
	"fmt"
	"go/ast"
	"go/token"
	"go/types"
	"path/filepath"
	"sort"
	"strings"

	"golang.org/x/tools/go/packages"
)

type nodeKind int

const (
	nodeFunc nodeKind = iota
	nodeStruct
	nodeFile
	nodeIO
)

type edgeKind int

const (
	edgeCall edgeKind = iota
	edgeRead
	edgeWrite
	edgeIORead
	edgeIOWrite
)

type node struct {
	ID      string
	Label   string
	Package string
	Detail  string
	Kind    nodeKind
	Target  bool
	Fields  []fieldRow
	Omitted int
}

type fieldRow struct {
	Name string
	Type string
	Port string
}

type edge struct {
	From    string
	To      string
	Port    string
	Kind    edgeKind
	Tooltip string
	Field   string
	Fields  []string
	Label   string
}

type graph struct {
	module string
	title  string
	target map[string]bool
	nodes  map[string]*node
	edges  []edge
	seen   map[string]bool
}

func newGraph() *graph {
	return &graph{
		nodes: make(map[string]*node),
		seen:  make(map[string]bool),
	}
}

func (g *graph) addNode(n *node) {
	if n == nil || n.ID == "" {
		return
	}
	if _, ok := g.nodes[n.ID]; !ok {
		g.nodes[n.ID] = n
	}
}

func (g *graph) addEdge(e edge) {
	key := fmt.Sprintf("%s|%s|%s|%d", e.From, e.To, e.Port, e.Kind)
	if g.seen[key] {
		return
	}
	g.seen[key] = true
	g.edges = append(g.edges, e)
}

func (g *graph) count(kind nodeKind) int {
	n := 0
	for _, item := range g.nodes {
		if item.Kind == kind {
			n++
		}
	}
	return n
}

type funcInfo struct {
	pkg    *packages.Package
	fn     *types.Func
	body   *ast.BlockStmt
	target bool
}

type analyzer struct {
	fset      *token.FileSet
	module    string
	target    map[string]bool
	boundary  map[string]bool
	pkgs      map[string]*packages.Package
	includeIO bool
	showCalls bool
	groupType bool
	groupFile bool
	g         *graph

	funcNodes   map[*types.Func]string
	structNodes map[*types.Named]string
	owners      map[*types.Var]*types.Named
	fieldPort   map[*types.Var]string
	funcs       []*funcInfo
}

func analyze(opts options) (*graph, error) {
	cfg := &packages.Config{
		Mode: packages.NeedName | packages.NeedFiles | packages.NeedCompiledGoFiles |
			packages.NeedImports | packages.NeedDeps | packages.NeedSyntax |
			packages.NeedTypes | packages.NeedTypesInfo | packages.NeedModule,
		Dir:   opts.dir,
		Tests: opts.includeTest,
	}
	roots, err := packages.Load(cfg, opts.pkg)
	if err != nil {
		return nil, fmt.Errorf("load %s: %w", opts.pkg, err)
	}
	if len(roots) == 0 {
		return nil, fmt.Errorf("no packages matched %q", opts.pkg)
	}
	if packages.PrintErrors(roots) > 0 {
		return nil, fmt.Errorf("packages contain errors")
	}

	a := &analyzer{
		fset:        roots[0].Fset,
		target:      make(map[string]bool),
		boundary:    make(map[string]bool),
		pkgs:        make(map[string]*packages.Package),
		includeIO:   opts.includeIO,
		showCalls:   opts.showCalls,
		groupType:   opts.groupType,
		groupFile:   opts.groupFile,
		g:           newGraph(),
		funcNodes:   make(map[*types.Func]string),
		structNodes: make(map[*types.Named]string),
		owners:      make(map[*types.Var]*types.Named),
		fieldPort:   make(map[*types.Var]string),
	}

	for _, root := range roots {
		if root.Module != nil && root.Module.Path != "" {
			a.module = root.Module.Path
			break
		}
	}
	if a.module == "" {
		return nil, fmt.Errorf("%s is not inside a Go module", opts.dir)
	}

	for _, root := range roots {
		if root.PkgPath != "" {
			a.target[root.PkgPath] = true
		}
	}
	for _, root := range roots {
		for path := range root.Imports {
			if path == a.module || strings.HasPrefix(path, a.module+"/") {
				a.boundary[path] = true
			}
		}
	}

	walkPackages(roots, func(p *packages.Package) {
		if p.PkgPath != "" {
			a.pkgs[p.PkgPath] = p
		}
	})

	a.collectStructs()
	a.collectFuncs()
	for _, fi := range a.funcs {
		a.walkFunc(fi)
	}
	if !a.showCalls {
		a.propagateIO()
	}
	a.prune()
	a.aggregateFields()
	if err := a.focus(opts.focus); err != nil {
		return nil, err
	}

	a.g.module = a.module
	title := opts.pkg + " — struct field reads/writes and file I/O"
	if a.groupFile {
		title = opts.pkg + " — file-level field reads/writes and file I/O"
	}
	if a.groupType {
		title = opts.pkg + " — type-level field reads/writes and file I/O"
	}
	if a.showCalls {
		title = opts.pkg + " — calls, field reads/writes, file I/O"
	}
	if opts.focus != "" {
		title += " (focus: " + opts.focus + ")"
	}
	a.g.title = title
	a.g.target = a.target
	return a.g, nil
}

func walkPackages(roots []*packages.Package, visit func(*packages.Package)) {
	seen := make(map[string]bool)
	var walk func(*packages.Package)
	walk = func(p *packages.Package) {
		if p == nil || seen[p.ID] {
			return
		}
		seen[p.ID] = true
		visit(p)
		for _, imported := range p.Imports {
			walk(imported)
		}
	}
	for _, root := range roots {
		walk(root)
	}
}

func (a *analyzer) inScope(path string) bool {
	return path != "" && (a.target[path] || a.boundary[path])
}

func (a *analyzer) emit(e edge) {
	if (a.groupType || a.groupFile) && e.From == e.To {
		return
	}
	a.g.addEdge(e)
}

func (a *analyzer) collectStructs() {
	paths := make([]string, 0, len(a.pkgs))
	for path := range a.pkgs {
		if a.inScope(path) {
			paths = append(paths, path)
		}
	}
	sort.Strings(paths)

	for _, path := range paths {
		pkg := a.pkgs[path]
		if pkg.Types == nil {
			continue
		}
		scope := pkg.Types.Scope()
		for _, name := range scope.Names() {
			typeName, ok := scope.Lookup(name).(*types.TypeName)
			if !ok {
				continue
			}
			named, ok := types.Unalias(typeName.Type()).(*types.Named)
			if !ok {
				continue
			}
			named = named.Origin()
			st, ok := named.Underlying().(*types.Struct)
			if !ok {
				continue
			}
			for i := 0; i < st.NumFields(); i++ {
				a.owners[st.Field(i)] = named
			}
			if a.target[path] {
				a.ensureStructNode(named)
			}
		}
	}
}

func (a *analyzer) ensureStructNode(named *types.Named) string {
	if named == nil {
		return ""
	}
	named = named.Origin()
	if id, ok := a.structNodes[named]; ok && id != "" {
		return id
	}
	obj := named.Obj()
	if obj == nil || obj.Pkg() == nil {
		return ""
	}
	path := obj.Pkg().Path()
	if !a.inScope(path) {
		return ""
	}

	id := "ty|" + path + "." + obj.Name()
	if _, ok := a.g.nodes[id]; ok {
		a.structNodes[named] = id
		return id
	}
	st, ok := named.Underlying().(*types.Struct)
	if !ok {
		return ""
	}

	n := &node{
		ID:      id,
		Label:   obj.Name(),
		Package: path,
		Detail:  path + "." + obj.Name(),
		Kind:    nodeStruct,
		Target:  a.target[path],
	}
	for i := 0; i < st.NumFields(); i++ {
		field := st.Field(i)
		port := fmt.Sprintf("p%d", i)
		a.fieldPort[field] = port
		n.Fields = append(n.Fields, fieldRow{
			Name: field.Name(),
			Type: clip(typeString(field.Type(), obj.Pkg()), 48),
			Port: port,
		})
	}
	a.g.addNode(n)
	a.structNodes[named] = id
	return id
}

func (a *analyzer) collectFuncs() {
	paths := make([]string, 0, len(a.pkgs))
	for path := range a.pkgs {
		if a.inScope(path) {
			paths = append(paths, path)
		}
	}
	sort.Strings(paths)

	for _, path := range paths {
		pkg := a.pkgs[path]
		if pkg.TypesInfo == nil {
			continue
		}
		for _, file := range pkg.Syntax {
			for _, decl := range file.Decls {
				fd, ok := decl.(*ast.FuncDecl)
				if !ok || fd.Body == nil {
					continue
				}
				fn, ok := pkg.TypesInfo.Defs[fd.Name].(*types.Func)
				if !ok {
					continue
				}
				fi := &funcInfo{pkg: pkg, fn: fn, body: fd.Body, target: a.target[path]}
				if fi.target {
					a.ensureFuncNode(fn)
				}
				a.funcs = append(a.funcs, fi)
			}
		}
	}
}

func (a *analyzer) ensureFuncNode(fn *types.Func) string {
	if fn == nil || fn.Pkg() == nil {
		return ""
	}
	path := fn.Pkg().Path()
	if !a.inScope(path) {
		return ""
	}
	if id, ok := a.funcNodes[fn]; ok {
		return id
	}
	if a.groupType {
		if id := a.receiverTypeNode(fn); id != "" {
			a.funcNodes[fn] = id
			return id
		}
	}
	if a.groupFile {
		if id := a.fileNode(fn); id != "" {
			a.funcNodes[fn] = id
			return id
		}
	}

	id := "fn|" + fn.FullName()
	if _, ok := a.g.nodes[id]; !ok {
		a.g.addNode(&node{
			ID:      id,
			Label:   funcLabel(fn),
			Package: path,
			Detail:  fn.FullName(),
			Kind:    nodeFunc,
			Target:  a.target[path],
		})
	}
	a.funcNodes[fn] = id
	return id
}

func (a *analyzer) receiverTypeNode(fn *types.Func) string {
	recv := fn.Signature().Recv()
	if recv == nil {
		return ""
	}
	t := recv.Type()
	if pointer, ok := t.(*types.Pointer); ok {
		t = pointer.Elem()
	}
	named, ok := types.Unalias(t).(*types.Named)
	if !ok {
		return ""
	}
	named = named.Origin()
	obj := named.Obj()
	if obj == nil || obj.Pkg() == nil || !a.target[obj.Pkg().Path()] {
		return ""
	}
	if _, ok := named.Underlying().(*types.Struct); !ok {
		return ""
	}
	return a.ensureStructNode(named)
}

func (a *analyzer) fileNode(fn *types.Func) string {
	if fn == nil || fn.Pkg() == nil {
		return ""
	}
	path := fn.Pkg().Path()
	if !a.target[path] {
		return ""
	}
	position := a.fset.Position(fn.Pos())
	if position.Filename == "" {
		return ""
	}
	base := filepath.Base(position.Filename)
	id := "file|" + path + "|" + base
	if _, ok := a.g.nodes[id]; !ok {
		a.g.addNode(&node{
			ID:      id,
			Label:   base,
			Package: path,
			Detail:  path + "/" + base,
			Kind:    nodeFile,
			Target:  true,
		})
	}
	return id
}

func (a *analyzer) walkFunc(fi *funcInfo) {
	var writes, readWrites map[*ast.SelectorExpr]bool
	if fi.target {
		writes, readWrites = collectWrites(fi.body)
	}

	ast.Inspect(fi.body, func(n ast.Node) bool {
		switch n := n.(type) {
		case *ast.CallExpr:
			a.recordCall(fi, n)
		case *ast.CompositeLit:
			if fi.target {
				a.recordLiteral(fi, n)
			}
		case *ast.SelectorExpr:
			if fi.target {
				a.recordField(fi, n, writes, readWrites)
			}
		}
		return true
	})
}

func (a *analyzer) recordCall(fi *funcInfo, call *ast.CallExpr) {
	callee := calleeFunc(fi.pkg.TypesInfo, call.Fun)
	if callee == nil {
		return
	}
	if kind, ok := ioKind(callee); ok {
		if a.includeIO {
			a.recordIO(fi, kind, call.Pos())
		}
		return
	}

	calleeID := a.ensureFuncNode(callee)
	if calleeID == "" {
		return
	}
	callerID := a.ensureFuncNode(fi.fn)
	if callerID == "" {
		return
	}
	a.emit(edge{
		From:    callerID,
		To:      calleeID,
		Kind:    edgeCall,
		Tooltip: a.tooltip(call.Pos()),
	})
}

func (a *analyzer) recordIO(fi *funcInfo, kind edgeKind, pos token.Pos) {
	callerID := a.ensureFuncNode(fi.fn)
	if callerID == "" {
		return
	}
	a.addIOEdge(callerID, kind, a.tooltip(pos))
}

func (a *analyzer) addIOEdge(fromID string, kind edgeKind, tooltip string) bool {
	if fromID == "" {
		return false
	}
	id, label := ioNode(kind)
	if _, ok := a.g.nodes[id]; !ok {
		a.g.addNode(&node{
			ID:     id,
			Label:  label,
			Detail: label,
			Kind:   nodeIO,
		})
	}
	before := len(a.g.edges)
	a.emit(edge{
		From:    fromID,
		To:      id,
		Kind:    kind,
		Tooltip: tooltip,
	})
	return len(a.g.edges) > before
}

func ioNode(kind edgeKind) (string, string) {
	if kind == edgeIOWrite {
		return "io|write", "file write"
	}
	return "io|read", "file read"
}

func (a *analyzer) propagateIO() {
	for {
		reach := a.ioReachability()
		changed := false
		for id, kinds := range reach {
			n := a.g.nodes[id]
			if n == nil || !n.Target {
				continue
			}
			for kind := range kinds {
				if a.addIOEdge(id, kind, "") {
					changed = true
				}
			}
		}
		if !changed {
			return
		}
	}
}

func (a *analyzer) ioReachability() map[string]map[edgeKind]bool {
	reverse := make(map[string][]string)
	reach := make(map[string]map[edgeKind]bool)
	var queue []string

	for _, e := range a.g.edges {
		switch e.Kind {
		case edgeCall:
			reverse[e.To] = append(reverse[e.To], e.From)
		case edgeIORead, edgeIOWrite:
			if reach[e.From] == nil {
				reach[e.From] = make(map[edgeKind]bool)
			}
			reach[e.From][e.Kind] = true
			queue = append(queue, e.From)
		}
	}

	for len(queue) > 0 {
		id := queue[0]
		queue = queue[1:]
		for _, caller := range reverse[id] {
			if reach[caller] == nil {
				reach[caller] = make(map[edgeKind]bool)
			}
			changed := false
			for kind := range reach[id] {
				if !reach[caller][kind] {
					reach[caller][kind] = true
					changed = true
				}
			}
			if changed {
				n := a.g.nodes[caller]
				if n == nil || !n.Target {
					queue = append(queue, caller)
				}
			}
		}
	}
	return reach
}

func (a *analyzer) recordField(fi *funcInfo, sel *ast.SelectorExpr, writes, readWrites map[*ast.SelectorExpr]bool) {
	selection := fi.pkg.TypesInfo.Selections[sel]
	if selection == nil || selection.Kind() != types.FieldVal {
		return
	}
	field, ok := selection.Obj().(*types.Var)
	if !ok {
		return
	}
	owner := a.owners[field]
	if owner == nil || owner.Obj().Pkg() == nil {
		return
	}
	if !a.inScope(owner.Obj().Pkg().Path()) {
		return
	}
	structID := a.ensureStructNode(owner)
	if structID == "" {
		return
	}
	funcID := a.ensureFuncNode(fi.fn)
	if funcID == "" {
		return
	}
	port := a.portFor(owner, field)
	if port == "" {
		return
	}

	kind := edgeRead
	if writes[sel] {
		kind = edgeWrite
	}
	a.emit(edge{
		From:    funcID,
		To:      structID,
		Port:    port,
		Kind:    kind,
		Field:   field.Name(),
		Tooltip: a.tooltip(sel.Pos()),
	})
	if readWrites[sel] {
		a.emit(edge{
			From:    funcID,
			To:      structID,
			Port:    port,
			Kind:    edgeRead,
			Field:   field.Name(),
			Tooltip: a.tooltip(sel.Pos()),
		})
	}
}

func (a *analyzer) recordLiteral(fi *funcInfo, lit *ast.CompositeLit) {
	named := structTypeOf(fi.pkg.TypesInfo.TypeOf(lit))
	if named == nil {
		return
	}
	st, ok := named.Underlying().(*types.Struct)
	if !ok {
		return
	}
	owner := named.Origin()
	if owner.Obj().Pkg() == nil || !a.inScope(owner.Obj().Pkg().Path()) {
		return
	}

	for _, elt := range lit.Elts {
		kv, ok := elt.(*ast.KeyValueExpr)
		if !ok {
			continue
		}
		key, ok := kv.Key.(*ast.Ident)
		if !ok {
			continue
		}
		field := fieldByName(st, key.Name)
		if field == nil {
			continue
		}
		structID := a.ensureStructNode(owner)
		if structID == "" {
			continue
		}
		funcID := a.ensureFuncNode(fi.fn)
		if funcID == "" {
			continue
		}
		port := a.portFor(owner, field)
		if port == "" {
			continue
		}
		a.emit(edge{
			From:    funcID,
			To:      structID,
			Port:    port,
			Kind:    edgeWrite,
			Field:   field.Name(),
			Tooltip: a.tooltip(kv.Pos()),
		})
	}
}

func (a *analyzer) portFor(owner *types.Named, field *types.Var) string {
	if port := a.fieldPort[field]; port != "" {
		return port
	}
	st, ok := owner.Underlying().(*types.Struct)
	if !ok {
		return ""
	}
	for i := 0; i < st.NumFields(); i++ {
		candidate := st.Field(i)
		if candidate == field || candidate.Name() == field.Name() {
			port := fmt.Sprintf("p%d", i)
			a.fieldPort[field] = port
			return port
		}
	}
	return ""
}

func (a *analyzer) prune() {
	directBoundary := make(map[string]bool)
	for _, e := range a.g.edges {
		if e.Kind != edgeCall {
			continue
		}
		from := a.g.nodes[e.From]
		to := a.g.nodes[e.To]
		if from != nil && from.Target && to != nil && !to.Target {
			directBoundary[e.To] = true
		}
	}

	dataFuncs := make(map[string]bool)
	for _, e := range a.g.edges {
		if e.Kind == edgeRead || e.Kind == edgeWrite {
			dataFuncs[e.From] = true
		}
	}
	ioFuncs := make(map[string]bool)
	if !a.showCalls {
		for id := range a.ioReachability() {
			ioFuncs[id] = true
		}
	}

	keepFunc := func(id string) bool {
		n := a.g.nodes[id]
		if n == nil || n.Kind != nodeFunc {
			return false
		}
		if n.Target {
			if a.showCalls {
				return true
			}
			return dataFuncs[id] || ioFuncs[id]
		}
		return a.showCalls && directBoundary[id]
	}

	sourceKept := func(id string) bool {
		n := a.g.nodes[id]
		if n == nil {
			return false
		}
		if n.Kind == nodeFile {
			if a.showCalls {
				return true
			}
			return dataFuncs[id] || ioFuncs[id]
		}
		if n.Target {
			if a.groupType && n.Kind == nodeStruct {
				return true
			}
			if n.Kind == nodeFunc {
				return keepFunc(id)
			}
			return true
		}
		return a.showCalls && directBoundary[id]
	}

	usedStruct := make(map[string]bool)
	usedPort := make(map[string]map[string]bool)
	usedIO := make(map[string]bool)
	for _, e := range a.g.edges {
		if !sourceKept(e.From) {
			continue
		}
		switch e.Kind {
		case edgeRead, edgeWrite:
			usedStruct[e.To] = true
			if usedPort[e.To] == nil {
				usedPort[e.To] = make(map[string]bool)
			}
			usedPort[e.To][e.Port] = true
		case edgeIORead, edgeIOWrite:
			usedIO[e.To] = true
		}
	}

	keep := func(id string) bool {
		n := a.g.nodes[id]
		if n == nil {
			return false
		}
		switch n.Kind {
		case nodeFunc:
			return keepFunc(id)
		case nodeFile:
			return sourceKept(id)
		case nodeStruct:
			if n.Target && a.groupType {
				return true
			}
			if a.showCalls && n.Target {
				return true
			}
			return usedStruct[id]
		case nodeIO:
			return usedIO[id]
		}
		return false
	}

	nodes := make(map[string]*node, len(a.g.nodes))
	for id, n := range a.g.nodes {
		if !keep(id) {
			continue
		}
		if n.Kind == nodeStruct {
			a.trimFields(n, usedPort[id])
		}
		nodes[id] = n
	}
	edges := a.g.edges[:0]
	for _, e := range a.g.edges {
		if !a.showCalls && e.Kind == edgeCall {
			continue
		}
		if keep(e.From) && keep(e.To) {
			edges = append(edges, e)
		}
	}
	a.g.nodes = nodes
	a.g.edges = edges
}

func (a *analyzer) trimFields(n *node, used map[string]bool) {
	if a.groupType && n.Target {
		return
	}
	if len(used) == 0 {
		n.Omitted = len(n.Fields)
		n.Fields = nil
		return
	}
	fields := make([]fieldRow, 0, len(used))
	for _, field := range n.Fields {
		if used[field.Port] {
			fields = append(fields, field)
		}
	}
	n.Omitted = len(n.Fields) - len(fields)
	n.Fields = fields
}

func (a *analyzer) aggregateFields() {
	groups := make(map[string]*edge)
	var others []edge
	for _, e := range a.g.edges {
		if e.Kind != edgeRead && e.Kind != edgeWrite {
			others = append(others, e)
			continue
		}
		key := fmt.Sprintf("%s|%s|%d", e.From, e.To, e.Kind)
		group, ok := groups[key]
		if !ok {
			cloned := e
			cloned.Port = ""
			cloned.Fields = nil
			cloned.Label = ""
			group = &cloned
			groups[key] = group
		}
		if e.Field != "" {
			group.Fields = appendUnique(group.Fields, e.Field)
		}
	}

	keys := make([]string, 0, len(groups))
	for key := range groups {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	edges := make([]edge, 0, len(others)+len(keys))
	edges = append(edges, others...)
	for _, key := range keys {
		e := groups[key]
		sort.Strings(e.Fields)
		e.Label = fieldLabel(e.Kind, e.Fields)
		if len(e.Fields) > 0 {
			fields := strings.Join(e.Fields, ", ")
			if e.Tooltip != "" {
				e.Tooltip += " | "
			}
			e.Tooltip += fields
		}
		edges = append(edges, *e)
	}
	a.g.edges = edges
}

func (a *analyzer) focus(needle string) error {
	if needle == "" {
		return nil
	}
	needle = strings.ToLower(needle)
	focusNodes := make(map[string]bool)
	for id, n := range a.g.nodes {
		if n.Kind == nodeStruct && strings.Contains(strings.ToLower(n.Label), needle) {
			focusNodes[id] = true
		}
	}
	if len(focusNodes) == 0 {
		return fmt.Errorf("no struct matches %q", needle)
	}

	kept := make(map[string]bool)
	for id := range focusNodes {
		kept[id] = true
	}
	edges := make([]edge, 0, len(a.g.edges))
	for _, e := range a.g.edges {
		if !focusNodes[e.From] && !focusNodes[e.To] {
			continue
		}
		kept[e.From] = true
		kept[e.To] = true
		edges = append(edges, e)
	}

	nodes := make(map[string]*node, len(kept))
	for id := range kept {
		if n := a.g.nodes[id]; n != nil {
			nodes[id] = n
		}
	}
	a.g.nodes = nodes
	a.g.edges = edges
	return nil
}

func appendUnique(values []string, value string) []string {
	for _, existing := range values {
		if existing == value {
			return values
		}
	}
	return append(values, value)
}

func fieldLabel(kind edgeKind, fields []string) string {
	verb := "read"
	if kind == edgeWrite {
		verb = "write"
	}
	if len(fields) == 0 {
		return verb
	}
	shown := fields
	if len(shown) > 2 {
		shown = append(append([]string(nil), shown[:2]...), fmt.Sprintf("+%d", len(fields)-2))
	}
	return clip(verb+" "+strings.Join(shown, ", "), 72)
}

func collectWrites(body *ast.BlockStmt) (map[*ast.SelectorExpr]bool, map[*ast.SelectorExpr]bool) {
	writes := make(map[*ast.SelectorExpr]bool)
	readWrites := make(map[*ast.SelectorExpr]bool)
	ast.Inspect(body, func(n ast.Node) bool {
		switch stmt := n.(type) {
		case *ast.AssignStmt:
			for _, lhs := range stmt.Lhs {
				if sel := assignedSelector(lhs); sel != nil {
					writes[sel] = true
					if stmt.Tok != token.ASSIGN {
						readWrites[sel] = true
					}
				}
			}
		case *ast.IncDecStmt:
			if sel := assignedSelector(stmt.X); sel != nil {
				writes[sel] = true
				readWrites[sel] = true
			}
		}
		return true
	})
	return writes, readWrites
}

func assignedSelector(e ast.Expr) *ast.SelectorExpr {
	for {
		switch x := e.(type) {
		case *ast.ParenExpr:
			e = x.X
		case *ast.SelectorExpr:
			return x
		case *ast.IndexExpr, *ast.IndexListExpr, *ast.StarExpr:
			return nil
		default:
			return nil
		}
	}
}

func calleeFunc(info *types.Info, e ast.Expr) *types.Func {
	e = unparen(e)
	switch x := e.(type) {
	case *ast.Ident:
		if fn, ok := info.Uses[x].(*types.Func); ok {
			return fn
		}
	case *ast.SelectorExpr:
		if selection := info.Selections[x]; selection != nil {
			if fn, ok := selection.Obj().(*types.Func); ok {
				return fn
			}
		}
		if fn, ok := info.Uses[x.Sel].(*types.Func); ok {
			return fn
		}
	case *ast.IndexExpr:
		return calleeFunc(info, x.X)
	case *ast.IndexListExpr:
		return calleeFunc(info, x.X)
	}
	return nil
}

func unparen(e ast.Expr) ast.Expr {
	for {
		p, ok := e.(*ast.ParenExpr)
		if !ok {
			return e
		}
		e = p.X
	}
}

func ioKind(fn *types.Func) (edgeKind, bool) {
	if fn == nil || fn.Pkg() == nil {
		return 0, false
	}
	switch fn.Pkg().Path() + "." + fn.Name() {
	case "os.ReadFile", "os.Open":
		return edgeIORead, true
	case "os.WriteFile", "os.Create":
		return edgeIOWrite, true
	}
	return 0, false
}

func structTypeOf(t types.Type) *types.Named {
	if t == nil {
		return nil
	}
	t = types.Unalias(t)
	switch x := t.(type) {
	case *types.Pointer:
		return structTypeOf(x.Elem())
	case *types.Named:
		if _, ok := x.Underlying().(*types.Struct); ok {
			return x.Origin()
		}
		return structTypeOf(x.Underlying())
	case *types.Slice:
		return structTypeOf(x.Elem())
	case *types.Array:
		return structTypeOf(x.Elem())
	}
	return nil
}

func fieldByName(st *types.Struct, name string) *types.Var {
	for i := 0; i < st.NumFields(); i++ {
		if st.Field(i).Name() == name {
			return st.Field(i)
		}
	}
	return nil
}

func (a *analyzer) tooltip(pos token.Pos) string {
	if !pos.IsValid() {
		return ""
	}
	position := a.fset.Position(pos)
	if position.Filename == "" {
		return ""
	}
	return fmt.Sprintf("%s:%d", filepath.Base(position.Filename), position.Line)
}

func funcLabel(fn *types.Func) string {
	if fn == nil {
		return ""
	}
	if recv := fn.Signature().Recv(); recv != nil {
		t := recv.Type()
		if pointer, ok := t.(*types.Pointer); ok {
			t = pointer.Elem()
		}
		t = types.Unalias(t)
		if named, ok := t.(*types.Named); ok {
			return named.Obj().Name() + "." + fn.Name()
		}
		return typeString(t, nil) + "." + fn.Name()
	}
	return fn.Name()
}

func typeString(t types.Type, from *types.Package) string {
	if t == nil {
		return "?"
	}
	return types.TypeString(t, func(p *types.Package) string {
		if p == nil || p == from {
			return ""
		}
		return p.Name()
	})
}

func clip(value string, width int) string {
	runes := []rune(value)
	if len(runes) <= width {
		return value
	}
	return string(runes[:width-1]) + "…"
}
