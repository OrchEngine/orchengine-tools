# Allocation, Ownership, and Capability Rules

**Scope:** `OrchEngine/orchengine-tools`.

Each rule is a statement and its reason, followed by a direct example. The rules are the
contract; the examples show the shape they forbid and the shape they require. Rules are numbered
in reading order; do not renumber.

## Rules

**1. A capability lives at the boundary, never on a data type.**
A capability is a handle to authority: an `Allocator`, `std.Io` (files, network, clocks,
randomness, concurrency), an `Io.Writer`/`Reader`, a `Dir`, a `File`, a `Clock`, or anything else
that lets the holder allocate, do I/O, or read the environment. A stored handle grants that
authority to every method, and it stays valid only while the provider lives and only if the
provider is thread-safe when shared — facts known only where the provider is created. So only a
type that is itself part of the boundary may store one: the root, a job, a builder, or a struct
created and destroyed inside one call. Tests and benches own their scope and may store one. A data,
config, plan, event, or record type is built from data and outlives that boundary, so it takes the
capability as a parameter on the call that needs it; a field there asserts a lifetime and
thread-safety contract the type cannot check.

**2. One `init`, one `deinit`, and the signature follows storage.**
If release is not reachable from the type, the caller must read the parent function to know how to
clean up; that knowledge does not survive a refactor, and under an arena the leak is silent. If the
type stores its allocator, taking another one in `deinit` offers a second release path through a
handle that may not be the one that allocated. One constructor and one destructor, matching how the
capability is held, make ownership a property of the type.

**3. An arena lives in one named scope, is never copied, and its handle never outlives it.**
An arena is created at a boundary, used inside it, and deinited or reset at its end. The boundary is
named where the arena is created: per request, per job, per command, per generated workflow, per
bench iteration. A scope that repeats resets rather than deinits; an arena that is not the process
root and has no stated end is a leak with extra steps. The handle stores `&arena`, so returning
`arena.allocator()` from a function whose arena is local, storing an `ArenaAllocator` by value,
copying an arena after taking its handle, or keeping a slice past `deinit` all point the handle at
state that is no longer the live one: allocations land in a list nobody frees, or `deinit` frees a
different list, and the type system cannot tell the copies apart. A nested lifetime gets its own
sub-arena, which bounds the scope and keeps growth out of the parent — but when its child is another
arena's allocator, its `deinit` is a no-op at the parent: it gives a clear logical lifetime, not
returned memory. To actually reclaim, the sub-arena's child must be an allocator that frees, or the
parent must `reset`.

**4. A stateful handle passes by pointer; only an owning wrapper holds it by value.**
Copying a handle that carries a cursor, buffer, or position creates two independent states over the
same resource; one copy can advance or flush state the other still believes is pending. An owning
wrapper is the exception, because it is the single place that holds the state.

**5. A capability reachable from several threads must be thread-safe.**
A handle carries no thread-safety guarantee, and arenas are not thread-safe. Sharing a per-job arena
across workers is a data race on the arena's state, not only a lifetime bug.

**6. Release unconditionally, and order arena allocations so the release can take effect.**
A function frees what it allocates on every path, whatever allocator it received: an arena turns
`free` into a no-op, not into permission to skip it. Under an arena only the most recent allocation
can be freed or remapped, so order large temporaries last and free them as soon as they are done.
Do not use `free` as general reclamation: for anything that is not last, it does nothing.

**7. A type either owns a closed list of allocations and deinits infallibly, or it is a view.**
`deinit` promises the type can release everything it owns, which is only true when the owned memory
is reachable from its fields as a closed list. If a field can own memory the type cannot see, the
list cannot be written and the `deinit` is either incomplete (leaks) or frees memory it does not own
(double free); if the fields alias other owners, a `deinit` would free memory it does not own. In
both cases the type is a view, and the honest API documents what must outlive it. For the types that
do own, `deinit` releases what they own and returns `void`: teardown that can fail — flush, commit,
fsync, close — is a named method (`finish`, `commit`, `close`) the caller invokes before `deinit`,
and `deinit` remains safe afterwards. `defer` cannot propagate an error, so a fallible `deinit`
either swallows its error, which is silent data loss, or forces every caller to hand-write teardown
on every path, which is what rule 6 exists to prevent. Allocating in `deinit` creates a second owner
and an `OutOfMemory` with nowhere to go.

**8. Every allocation set has a named owner, and the signature says so.**
Memory stays valid only while some value keeps it alive. Name that value in the API: either return
an owner type the caller deinits, or take an arena whose lifetime the caller controls. "The
allocator" alone does not say when the memory dies — the same handle can be a request arena, a job
arena, or a test allocator, and the same function is called with all three. The return is either an
owner type — `Owned(T)`, `Parsed(T)`, or any type with a `deinit` — or the function name ends in
`Leaky`. Ownership that is invisible in the signature is discovered by leaking, and the signature is
the only place a caller looks, so the contract has to be there.

**9. Ownership moves by emptying the source; anything unmarked is a borrow.**
A transfer gives the receiver an owner type or an owned slice and leaves the source unable to
release that memory again: `toOwnedSlice` resets the list, `take` clears the optional. A borrow
returns or passes a view and transfers nothing, so the borrower must not free it or keep it past
the owner's release. Zig copies structs, so a move is a protocol rather than a language feature:
the emptying step is what makes it a move, and the name (`toOwnedSlice`, `take`, `into`) is the
only signal at the call site. Without it, a transfer leaves two owners of one allocation — a double
free on a real allocator, invisible under an arena — and a borrow mistaken for a transfer is freed
through a pointer the owner still uses. A partly finished transfer is the leak case: when a later
transfer fails, the ones that already succeeded are owned by nobody, and their sources were
emptied, so no `deinit` can reach them.

**10. Temporary allocation is `scratch`: local, bounded, and owned by the outer function.**
`scratch` names memory that dies with the call; `allocator` names memory the caller keeps. A
function that allocates only for its own duration builds the bound locally: a
`FixedBufferAllocator` over a stack buffer with an asserted size, or a `BufferFirstAllocator` over
an educated guess with `scratch` as the fallback. The wrapper is never a parameter, a field, or a
return type — that moves the buffer's lifetime to the caller and makes the bound their problem —
and an overflow is an error, never a silent truncation. When several functions share the scratch,
the outer function creates and frees it and the inner functions take it as a parameter, so each can
be called alone; a field instead widens the type's state, and a nested call wipes the outer call's
state. When it is a parameter, `scratch` follows the allocator-first convention: first, or
immediately after `self`.

**11. Repeated work must not grow memory.**
A repeated operation on a reused region must reach a steady state. Growth across identical runs is
a leak or retained scratch; it does not appear in a single-run measurement and compounds in a
long-lived process.

**12. Every owner is tested on a leak-checking allocator.**
Test owners with `std.testing.allocator`, not inside an arena. An arena absorbs leaks and turns
double frees into no-ops, so an arena-wrapped test cannot see them; a leak-checking allocator
reports leaks, double and invalid frees, and writes after free with the allocation's stack trace.

## Examples

### 1. Capability storage

```zig
// Violation: a record type carries authority it cannot vouch for.
const Event = struct {
    allocator: Allocator,     // every method can now allocate
    io: std.Io,               // and perform I/O
    name: []const u8,
};

// Correct: the capability lives at the boundary; the record is data.
const App = struct {
    allocator: Allocator,
    io: std.Io,
};

const Event = struct { name: []const u8 };

// Also correct: a call-scoped struct, alive for exactly one call.
const Validator = struct {
    allocator: Allocator,
    nodes: std.StringHashMap(NodeInfo),
};
```

### 2. Destructor signature

```zig
// Stores the allocator: deinit takes none.
const Sink = struct {
    allocator: Allocator,
    rows: std.ArrayList(Row) = .empty,

    pub fn deinit(self: *Sink) void {
        self.rows.deinit(self.allocator);
    }
};

// Violation: stores an allocator and releases through a second one.
fn deinit(self: *PoolRuntime, allocator: Allocator) void {
    // self.allocator is never read; the parameter may be a different handle.
    allocator.free(self.queue_buffer);
    allocator.destroy(self);
}
```

### 3. Arena lifetime

```zig
// Violation: &arena is on the stack that just ended.
fn makeAllocator() Allocator {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    return arena.allocator();
}

// Correct: one boundary, one end; the arena outlives the handle.
var arena = std.heap.ArenaAllocator.init(init.gpa);
defer arena.deinit();
const allocator = arena.allocator();
try runCommand(allocator);   // nothing outlives this block

// A repeating scope resets instead of deiniting.
for (workflows) |workflow| {
    _ = arena.reset(.retain_capacity);
    try generate(&arena, workflow);
}

// Violation: the value is copied after a handle was taken.
self.arena = arena;                   // self.arena is a second ArenaAllocator
const allocator = arena.allocator();  // points at the original, not the copy

// A sub-arena over an arena parent: a logical lifetime, not memory back.
var sub = std.heap.ArenaAllocator.init(parent_arena.allocator());
defer sub.deinit();   // parent_arena.free(node) is a no-op unless it is last

// Reclaims on deinit: the child frees.
var sub = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer sub.deinit();
```

### 4. Stateful handles

```zig
// Violation: the copy has its own cursor; each flush writes the same buffer twice.
fn write(writer: std.Io.Writer, text: []const u8) !void {
    try writer.writeAll(text);
}

// Correct: one state, passed by pointer.
fn write(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeAll(text);
}
```

### 5. Thread safety

```zig
// Violation: one arena shared by workers; its cursor and node list race.
var arena = std.heap.ArenaAllocator.init(init.gpa);
for (workers) |worker| worker.arena = &arena;

// Correct: a thread-safe shared allocator, a per-job arena.
for (workers) |worker| {
    worker.arena = std.heap.ArenaAllocator.init(init.gpa);
}
```

### 6. Release and order

```zig
// Violation: skipping the release because the caller might pass an arena.
if (allocator.ptr != arena_allocator.ptr) allocator.free(buffer);

// Correct: release unconditionally; under an arena the call is a no-op.
defer allocator.free(buffer);

// Correct order: allocate small first, large last, free in reverse.
const small = try allocator.alloc(u8, 64);
defer allocator.free(small);            // runs last
const large = try allocator.alloc(u8, 4096);
defer allocator.free(large);            // runs first, while it is the last allocation
```

### 7. Owner, view, and the destructor contract

```zig
// Owner: every allocation is reachable from a field, and deinit cannot fail.
const Ast = struct {
    nodes: []Node,
    extra: []Extra,
    tokens: []Token,

    pub fn deinit(self: Ast, gpa: Allocator) void {
        gpa.free(self.nodes);
        gpa.free(self.extra);
        gpa.free(self.tokens);
    }
};

// View: aliases and hidden owners, so there is no deinit to write.
const Plan = struct {
    name: []const u8,       // aliases Workflow
    nodes: []const Node,    // lives in the caller's arena
    // outputs[].type_ref may own a chain Plan cannot see
};

// Violation: fallible teardown behind a name that callers defer.
pub fn deinit(self: *Sink) !void {
    try self.database.commit();
    self.database.close();
}

// Correct: release is infallible; teardown that can fail is separate.
pub fn deinit(self: *Sink) void {
    self.database.close();
}

pub fn finish(self: *Sink) !void {
    try self.database.commit();
}

// Caller:
try sink.finish();
defer sink.deinit();
```

### 8. Named owner

```zig
// Unnamed: the allocator says nothing about the lifetime.
fn build(allocator: Allocator, workflow: *const Workflow) !Plan;

// The plan has two keepers: the arena for `nodes`, the workflow for `name`.
// Name them, or make the plan own everything.
fn buildOwned(allocator: Allocator, workflow: *const Workflow) !Owned(Plan);

// or state the borrow where the caller looks:
/// `workflow` must outlive the returned plan.
fn build(allocator: Allocator, workflow: *const Workflow) !Plan;

// Invisible: the caller cannot tell whether to free it.
fn render(allocator: Allocator, plan: *const Plan) ![]u8;

// Visible in the type.
fn render(allocator: Allocator, plan: *const Plan) !Owned([]u8);

// Visible in the name.
fn renderLeaky(allocator: Allocator, plan: *const Plan) []u8;
```

### 9. Transfer and borrow

```zig
// Transfer: toOwnedSlice empties the list, so the deferred release is a no-op.
var list: std.ArrayList(u8) = .empty;
defer list.deinit(allocator);
try list.appendSlice(allocator, "name");
return list.toOwnedSlice(allocator);

// Borrow: the caller must not free this.
fn nodeSlice(plan: *const Plan) []const Node {
    return plan.nodes;
}

// Violation: two transfers in one literal. If the second fails, the first is stranded.
return .{
    .nodes = try nodes.toOwnedSlice(allocator),
    .edges = try edges.toOwnedSlice(allocator),
};
```

### 10. Scratch

```zig
// Asserted bound: no allocator parameter at all.
fn writeName(writer: *std.Io.Writer, name: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const scratch = fba.allocator();
    try writeNameInto(scratch, writer, name);
}

// Educated guess: the only parameter is `scratch`, first, and the wrapper is local.
fn writeName(scratch: Allocator, writer: *std.Io.Writer, name: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var bfa = std.heap.BufferFirstAllocator.init(&buffer, scratch);
    try writeNameInto(bfa.allocator(), writer, name);
}

// Forbidden: the caller owns a buffer whose size only the callee knows.
fn writeName(bfa: *std.heap.BufferFirstAllocator, name: []const u8) !void;

// Outer: owns the scratch and frees it.
pub fn build(allocator: Allocator, workflow: *const Workflow, catalog: *const Catalog) !Plan {
    var list: diagnostics.List = .empty;
    defer list.deinit(allocator);
    return buildWithDiagnostics(allocator, workflow, catalog, &list);
}

// Inner: takes the scratch, so it can be called without the outer prologue.
pub fn buildWithDiagnostics(
    allocator: Allocator,
    workflow: *const Workflow,
    catalog: *const Catalog,
    list: *diagnostics.List,
) !Plan;
```

### 11. Repeated work

```zig
// Steady state: one arena, reset per item, no growth across runs.
var arena = std.heap.ArenaAllocator.init(gpa);
defer arena.deinit();
for (items) |item| {
    _ = arena.reset(.retain_capacity);
    try run(&arena, item);
}
```

### 12. Leak-checking allocator

```zig
// Weak: the arena absorbs the leak.
test "normalize name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try NormalizeName.run(arena.allocator(), .{ .name = "  Ada  " });
}

// Strong: the same leak is reported with its allocation site.
test "normalize name" {
    const out = try NormalizeName.run(std.testing.allocator, .{ .name = "  Ada  " });
    defer std.testing.allocator.free(out.normalized);
}
```

## Enforcement

| Rule | Check |
|---|---|
| 1 | allowlist of `path:Type.field`; review that the type is part of the boundary |
| 2 | stored allocator and `deinit` arity agree |
| 3 | `returned_stack_reference` (heuristic); arena scope review; sub-arena child can free |
| 4 | stateful handle passed as a pointer |
| 5 | TSan; shutdown tests |
| 6 | release on every path, temporaries last |
| 7 | closed list or documented view; `deinit` returns `void`; fail-every-allocation test |
| 8 | owner named in the signature; return type has `deinit`, or name ends in `Leaky` |
| 9 | `checkAllAllocationFailures` + `std.testing.allocator` |
| 10 | `allocator-first-param` + local bound review + reentrancy test |
| 11 | repeated-run memory check |
| 12 | `std.testing.allocator` owner tests |

## Open questions

1. What definition of "owner" can a linter key on, so rules 1 and 2 are checkable rather than
   judged?
2. Can "a closed list of frees" (rule 7) be approximated mechanically, or is it always a judgement
   about a type declaration?
3. Is "a field serves one function in one call" (rule 10) decidable, or always review?
4. What counts as an "asserted bound" for rule 10 — a comptime constant, a checked precondition at
   entry, or either?
