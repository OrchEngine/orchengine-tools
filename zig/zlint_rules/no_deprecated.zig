//! ## What This Rule Does
//! Flags deprecated Zig standard-library APIs and points at their replacements.
//!
//! The rule carries a curated table of the deprecations in the Zig 0.17.1
//! standard library. It understands both fully-qualified paths such as
//! `std.fmt.bufPrint` and aliases such as:
//!
//! ```zig
//! const fmt = std.fmt;
//! const mem = std.mem;
//!
//! _ = fmt.bufPrint(...); // reported
//! _ = mem.indexOf(...); // reported
//! ```
//!
//! Direct path renames are autofixed when the replacement is a drop-in
//! expression. Deprecations whose replacement changes the call shape (for
//! example `std.fmt.allocPrint` moving to `allocator.print`) are reported with
//! guidance but are not automatically rewritten.
//!
//! ### Limitations
//! ZLint does not have a type checker. Deprecations of instance methods are
//! matched by method name, which is best-effort: a user-defined
//! `readAlloc` or `getLastOrNull` method may be reported. Deprecations that
//! only apply to default struct initialization (for example
//! `std.HashMapUnmanaged{}`) are not detected.
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! const std = @import("std");
//!
//! fn render(value: u32) ![]u8 {
//!     var buffer: [32]u8 = undefined;
//!     return std.fmt.bufPrint(&buffer, "{d}", .{value});
//! }
//!
//! fn find(haystack: []const u8) ?usize {
//!     return std.mem.indexOf(u8, haystack, "needle");
//! }
//!
//! fn join(allocator: std.mem.Allocator) ![]u8 {
//!     return std.fs.path.resolve(allocator, &.{ "a", "b" });
//! }
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! const std = @import("std");
//!
//! fn render(value: u32) ![]u8 {
//!     var buffer: [32]u8 = undefined;
//!     return std.mem.print(&buffer, "{d}", .{value});
//! }
//!
//! fn find(haystack: []const u8) ?usize {
//!     return std.mem.find(u8, haystack, "needle");
//! }
//!
//! fn join(allocator: std.mem.Allocator) ![]u8 {
//!     return std.Io.Dir.path.resolveAlloc(allocator, &.{ "a", "b" });
//! }
//! ```

const std = @import("std");
const mem = std.mem;
const zlint = @import("zlint");

const Semantic = zlint.Semantic;
const Ast = Semantic.Ast;
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const LinterContext = zlint.linter.lint_context;
const Rule = zlint.linter.rule.Rule;
const NodeWrapper = zlint.linter.rule.NodeWrapper;
const ast_utils = zlint.linter.ast_utils;
const Error = zlint.Error;
const Span = zlint.span.Span;
const LabeledSpan = zlint.span.LabeledSpan;

const NoDeprecated = @This();
pub const meta: Rule.Meta = .{
    .name = "no-deprecated",
    .category = .suspicious,
    .default = .off,
};

const Deprecation = struct {
    /// Path relative to `std`, e.g. `mem.indexOf` or `builtin`.
    path: []const u8,
    /// Replacement relative to `std` when `is_std_path` is true.
    replacement: []const u8 = "",
    /// Is `replacement` a std API path?
    is_std_path: bool = true,
    /// Can `replacement` be applied without changing the call shape?
    /// Extra guidance for the user.
    note: []const u8 = "",
};

const MemberDeprecation = struct {
    name: []const u8,
    replacement: []const u8 = "",
    note: []const u8 = "",
};

const DeprecationKv = struct { []const u8, Deprecation };
const MemberKv = struct { []const u8, MemberDeprecation };

// The table is generated from the deprecation comments in Zig 0.17.1's
// `lib/std`. Keep entries sorted by module so future Zig bumps are easy to
// audit.
const deprecations = [_]Deprecation{
    // std (top level)
    .{ .path = "DynamicBitSet", .replacement = "bit_set.DynamicManaged" },
    .{ .path = "DynamicBitSetUnmanaged", .replacement = "bit_set.Dynamic" },
    .{ .path = "StaticBitSet", .replacement = "bit_set.Static" },
    .{ .path = "ArrayHashMapUnmanaged", .replacement = "array_hash_map.Custom" },
    .{ .path = "AutoArrayHashMapUnmanaged", .replacement = "array_hash_map.Auto" },
    .{ .path = "StringArrayHashMapUnmanaged", .replacement = "array_hash_map.String" },
    .{ .path = "ArrayListAligned", .replacement = "array_list.Aligned" },
    .{ .path = "ArrayListAlignedUnmanaged", .replacement = "array_list.Aligned" },
    .{ .path = "ArrayListUnmanaged", .replacement = "ArrayList" },
    .{ .path = "builtin", .replacement = "lang", .note = "`std.lang` is the new name for `std.builtin`." },
    .{ .path = "debug.runtime_safety", .replacement = "lang.Optimize.runtimeSafety", .note = "`runtimeSafety` is a method; call it on the module's optimize mode." },

    // std.mem
    .{ .path = "mem.copyForwards", .replacement = "@memmove", .is_std_path = false, .note = "Use `@memmove` when source and destination may overlap." },
    .{ .path = "mem.copyBackwards", .replacement = "@memmove", .is_std_path = false, .note = "Use `@memmove` when source and destination may overlap." },
    .{ .path = "mem.indexOfDiff", .replacement = "mem.findDiff" },
    .{ .path = "mem.indexOfSentinel", .replacement = "mem.findSentinel" },
    .{ .path = "mem.indexOfScalar", .replacement = "mem.findScalar" },
    .{ .path = "mem.lastIndexOfScalar", .replacement = "mem.findScalarLast" },
    .{ .path = "mem.indexOfScalarPos", .replacement = "mem.findScalarPos" },
    .{ .path = "mem.indexOfAny", .replacement = "mem.findAny" },
    .{ .path = "mem.lastIndexOfAny", .replacement = "mem.findLastAny" },
    .{ .path = "mem.indexOfAnyPos", .replacement = "mem.findAnyPos" },
    .{ .path = "mem.indexOfNone", .replacement = "mem.findNone" },
    .{ .path = "mem.lastIndexOfNone", .replacement = "mem.findLastNone" },
    .{ .path = "mem.indexOf", .replacement = "mem.find" },
    .{ .path = "mem.lastIndexOfLinear", .replacement = "mem.findLastLinear" },
    .{ .path = "mem.lastIndexOf", .replacement = "mem.findLast" },
    .{ .path = "mem.indexOfPos", .replacement = "mem.findPos" },
    .{ .path = "mem.byteSwapAllFields", .replacement = "mem.byteSwap" },
    .{ .path = "mem.byteSwapAllFieldsAligned", .replacement = "mem.byteSwapAligned" },
    .{ .path = "mem.indexOfMin", .replacement = "mem.findMin" },
    .{ .path = "mem.indexOfMinMax", .replacement = "mem.findMinMax" },

    // std.fmt
    .{ .path = "fmt.BufPrintError", .replacement = "mem.PrintError" },
    .{ .path = "fmt.bufPrint", .replacement = "mem.print" },
    .{ .path = "fmt.bufPrintSentinel", .replacement = "mem.printSentinel" },
    .{ .path = "fmt.allocPrint", .replacement = "Allocator.print", .is_std_path = false, .note = "Call `allocator.print(...)` instead." },
    .{ .path = "fmt.allocPrintSentinel", .replacement = "Allocator.printSentinel", .is_std_path = false, .note = "Call `allocator.printSentinel(...)` instead." },

    // std.fs
    .{ .path = "fs.path", .replacement = "Io.Dir.path" },
    .{ .path = "fs.path.resolve", .replacement = "Io.Dir.path.resolveAlloc" },
    .{ .path = "fs.path.resolveWindows", .replacement = "Io.Dir.path.resolveAllocWindows" },
    .{ .path = "fs.path.resolvePosix", .replacement = "Io.Dir.path.resolveAllocPosix" },
    .{ .path = "fs.path.relative", .replacement = "Io.Dir.path.relativeAlloc" },
    .{ .path = "fs.path.relativePosix", .replacement = "Io.Dir.path.relativeAllocPosix" },
    .{ .path = "fs.path.relativeWindows", .replacement = "Io.Dir.path.relativeAllocWindows" },
    .{ .path = "fs.path.WindowsPath", .replacement = "Io.Dir.path.WindowsPath2", .note = "`WindowsPath2` is generic; pass the element type." },
    .{ .path = "fs.path.windowsParsePath", .replacement = "Io.Dir.path.parsePathWindows", .note = "`parsePathWindows` is generic; pass the element type." },
    .{ .path = "fs.path.diskDesignator", .replacement = "Io.Dir.path.parsePath", .note = "`parsePath` returns a parsed path, not a designator slice." },
    .{ .path = "fs.path.diskDesignatorWindows", .replacement = "Io.Dir.path.parsePathWindows", .note = "`parsePathWindows` returns a parsed path, not a designator slice." },
    .{ .path = "fs.base64_alphabet", .replacement = "base64.url_safe_alphabet_chars" },
    .{ .path = "fs.base64_encoder", .replacement = "base64.url_safe.Encoder" },
    .{ .path = "fs.base64_decoder", .replacement = "base64.url_safe.Decoder" },
    .{ .path = "fs.max_path_bytes", .replacement = "Io.Dir.max_path_bytes" },
    .{ .path = "fs.max_name_bytes", .replacement = "Io.Dir.max_name_bytes" },

    // std.heap
    .{ .path = "heap.DebugAllocatorConfig", .replacement = "heap.SafeAllocator.Options" },
    .{ .path = "heap.DebugAllocator", .replacement = "heap.SafeAllocator" },
    .{ .path = "heap.Check", .note = "`heap.Check` has no replacement." },

    // std.array_hash_map / std.array_list / std.bit_set
    .{ .path = "array_hash_map.ArrayHashMap", .replacement = "array_hash_map.Custom" },
    .{ .path = "array_list.Managed", .replacement = "ArrayList", .note = "`std.ArrayList` is unmanaged; pass the allocator explicitly." },
    .{ .path = "array_list.AlignedManaged", .replacement = "array_list.Aligned" },
    .{ .path = "bit_set.StaticBitSet", .replacement = "bit_set.Static" },
    .{ .path = "bit_set.IntegerBitSet", .replacement = "bit_set.Integer" },
    .{ .path = "bit_set.ArrayBitSet", .replacement = "bit_set.Array" },
    .{ .path = "bit_set.DynamicBitSetUnmanaged", .replacement = "bit_set.Dynamic" },
    .{ .path = "bit_set.DynamicBitSet", .replacement = "bit_set.DynamicManaged" },
    .{ .path = "bit_set.DynamicManaged", .replacement = "bit_set.Dynamic", .note = "`Dynamic` takes the allocator as a parameter." },

    // std.lang / std.meta / std.unicode / std.zig
    .{ .path = "lang.OptimizeMode", .replacement = "lang.Optimize" },
    .{ .path = "lang.Optimize.Debug", .replacement = ".debug", .is_std_path = false },
    .{ .path = "lang.Optimize.ReleaseSafe", .replacement = ".safe", .is_std_path = false },
    .{ .path = "lang.Optimize.ReleaseFast", .replacement = ".fast", .is_std_path = false },
    .{ .path = "lang.Optimize.ReleaseSmall", .replacement = ".small", .is_std_path = false },
    .{ .path = "meta.fieldInfo", .replacement = "@typeInfo", .is_std_path = false },
    .{ .path = "meta.fieldNames", .replacement = "@typeInfo", .is_std_path = false },
    .{ .path = "meta.fieldTypes", .replacement = "@typeInfo", .is_std_path = false },
    .{ .path = "meta.declarationInfo", .replacement = "@hasDecl", .is_std_path = false },
    .{ .path = "meta.fields", .replacement = "@typeInfo", .is_std_path = false },
    .{ .path = "unicode.utf8Decode", .note = "Use `utf8Decode2`, `utf8Decode3`, or `utf8Decode4` based on the byte length." },
    .{ .path = "unicode.wtf8Decode", .note = "Use the length-specific WTF-8 decoder." },
    .{ .path = "zig.AllocPrintCmdOptions", .note = "Use `std.Io.Subprocess`." },
    .{ .path = "zig.allocPrintCmd", .note = "Use `std.Io.Subprocess`." },

    // std.tar
    .{ .path = "tar.PipeOptions", .replacement = "tar.ExtractOptions" },
    .{ .path = "tar.pipeToFileSystem", .replacement = "tar.extract" },

    // std.testing
    .{ .path = "testing.TmpDir.parent_dir_path", .note = "Use `std.testing.tmpDir`." },

    // std.Target
    .{ .path = "Target.Cpu.Arch.isAARCH64", .replacement = "Target.Cpu.Arch.isAarch64" },
    .{ .path = "Target.Cpu.Arch.isLoongArch", .replacement = "Target.Cpu.Arch.isLoongarch" },
    .{ .path = "Target.Cpu.Arch.isRISCV", .replacement = "Target.Cpu.Arch.isRiscv" },
    .{ .path = "Target.Cpu.Arch.isMIPS", .replacement = "Target.Cpu.Arch.isMips" },
    .{ .path = "Target.Cpu.Arch.isMIPS32", .replacement = "Target.Cpu.Arch.isMips32" },
    .{ .path = "Target.Cpu.Arch.isMIPS64", .replacement = "Target.Cpu.Arch.isMips64" },
    .{ .path = "Target.Cpu.Arch.isPowerPC", .replacement = "Target.Cpu.Arch.isPowerpc" },
    .{ .path = "Target.Cpu.Arch.isPowerPC32", .replacement = "Target.Cpu.Arch.isPowerpc32" },
    .{ .path = "Target.Cpu.Arch.isPowerPC64", .replacement = "Target.Cpu.Arch.isPowerpc64" },
    .{ .path = "Target.Cpu.Arch.isSPARC", .replacement = "Target.Cpu.Arch.isSparc" },
    .{ .path = "Target.Cpu.Arch.isSpirV", .replacement = "Target.Cpu.Arch.isSpirv" },
    .{ .path = "Target.Cpu.Arch.isBSD", .note = "Check the concrete OS tags instead." },
    .{ .path = "Target.Query.allocDescription", .replacement = "Target.Query.zigTriple" },
    .{ .path = "Target.Query.setGnuLibCVersion", .note = "Set `query.glibc_version` directly." },
    .{ .path = "Target.hurdTupleSimple", .replacement = "zig.target.hurdTupleSimple" },
    .{ .path = "Target.hurdTuple", .replacement = "zig.target.hurdTuple" },
    .{ .path = "Target.linuxTripleSimple", .replacement = "zig.target.linuxTripleSimple" },
    .{ .path = "Target.linuxTriple", .replacement = "zig.target.linuxTriple" },

    // std.elf
    .{ .path = "elf.SHT_NULL", .replacement = "@intFromEnum(std.elf.SHT.NULL)", .is_std_path = false },
    .{ .path = "elf.SHT_PROGBITS", .replacement = "@intFromEnum(std.elf.SHT.PROGBITS)", .is_std_path = false },
    .{ .path = "elf.SHT_SYMTAB", .replacement = "@intFromEnum(std.elf.SHT.SYMTAB)", .is_std_path = false },
    .{ .path = "elf.SHT_STRTAB", .replacement = "@intFromEnum(std.elf.SHT.STRTAB)", .is_std_path = false },
    .{ .path = "elf.SHT_RELA", .replacement = "@intFromEnum(std.elf.SHT.RELA)", .is_std_path = false },
    .{ .path = "elf.SHT_HASH", .replacement = "@intFromEnum(std.elf.SHT.HASH)", .is_std_path = false },
    .{ .path = "elf.SHT_DYNAMIC", .replacement = "@intFromEnum(std.elf.SHT.DYNAMIC)", .is_std_path = false },
    .{ .path = "elf.SHT_NOTE", .replacement = "@intFromEnum(std.elf.SHT.NOTE)", .is_std_path = false },
    .{ .path = "elf.SHT_NOBITS", .replacement = "@intFromEnum(std.elf.SHT.NOBITS)", .is_std_path = false },
    .{ .path = "elf.SHT_REL", .replacement = "@intFromEnum(std.elf.SHT.REL)", .is_std_path = false },
    .{ .path = "elf.SHT_SHLIB", .replacement = "@intFromEnum(std.elf.SHT.SHLIB)", .is_std_path = false },
    .{ .path = "elf.SHT_DYNSYM", .replacement = "@intFromEnum(std.elf.SHT.DYNSYM)", .is_std_path = false },
    .{ .path = "elf.SHT_INIT_ARRAY", .replacement = "@intFromEnum(std.elf.SHT.INIT_ARRAY)", .is_std_path = false },
    .{ .path = "elf.SHT_FINI_ARRAY", .replacement = "@intFromEnum(std.elf.SHT.FINI_ARRAY)", .is_std_path = false },
    .{ .path = "elf.SHT_PREINIT_ARRAY", .replacement = "@intFromEnum(std.elf.SHT.PREINIT_ARRAY)", .is_std_path = false },
    .{ .path = "elf.SHT_GROUP", .replacement = "@intFromEnum(std.elf.SHT.GROUP)", .is_std_path = false },
    .{ .path = "elf.SHT_SYMTAB_SHNDX", .replacement = "@intFromEnum(std.elf.SHT.SYMTAB_SHNDX)", .is_std_path = false },
    .{ .path = "elf.SHT_RELR", .replacement = "@intFromEnum(std.elf.SHT.RELR)", .is_std_path = false },
    .{ .path = "elf.SHT_NUM", .replacement = "elf.SHT.NUM" },
    .{ .path = "elf.SHT_LOOS", .replacement = "@intFromEnum(std.elf.SHT.LOOS)", .is_std_path = false },
    .{ .path = "elf.SHT_LLVM_ADDRSIG", .replacement = "@intFromEnum(std.elf.SHT.LLVM_ADDRSIG)", .is_std_path = false },
    .{ .path = "elf.SHT_GNU_HASH", .replacement = "@intFromEnum(std.elf.SHT.GNU_HASH)", .is_std_path = false },
    .{ .path = "elf.SHT_GNU_VERDEF", .replacement = "@intFromEnum(std.elf.SHT.GNU_VERDEF)", .is_std_path = false },
    .{ .path = "elf.SHT_GNU_VERNEED", .replacement = "@intFromEnum(std.elf.SHT.GNU_VERNEED)", .is_std_path = false },
    .{ .path = "elf.SHT_GNU_VERSYM", .replacement = "@intFromEnum(std.elf.SHT.GNU_VERSYM)", .is_std_path = false },
    .{ .path = "elf.SHT_HIOS", .replacement = "@intFromEnum(std.elf.SHT.HIOS)", .is_std_path = false },
    .{ .path = "elf.SHT_LOPROC", .replacement = "@intFromEnum(std.elf.SHT.LOPROC)", .is_std_path = false },
    .{ .path = "elf.SHT_X86_64_UNWIND", .replacement = "@intFromEnum(std.elf.SHT.X86_64_UNWIND)", .is_std_path = false },
    .{ .path = "elf.SHT_HIPROC", .replacement = "@intFromEnum(std.elf.SHT.HIPROC)", .is_std_path = false },
    .{ .path = "elf.SHT_LOUSER", .replacement = "@intFromEnum(std.elf.SHT.LOUSER)", .is_std_path = false },
    .{ .path = "elf.SHT_HIUSER", .replacement = "@intFromEnum(std.elf.SHT.HIUSER)", .is_std_path = false },
    .{ .path = "elf.STB_LOCAL", .replacement = "@intFromEnum(std.elf.STB.LOCAL)", .is_std_path = false },
    .{ .path = "elf.STB_GLOBAL", .replacement = "@intFromEnum(std.elf.STB.GLOBAL)", .is_std_path = false },
    .{ .path = "elf.STB_WEAK", .replacement = "@intFromEnum(std.elf.STB.WEAK)", .is_std_path = false },
    .{ .path = "elf.STB_LOOS", .replacement = "@intFromEnum(std.elf.STB.LOOS)", .is_std_path = false },
    .{ .path = "elf.STB_GNU_UNIQUE", .replacement = "@intFromEnum(std.elf.STB.GNU_UNIQUE)", .is_std_path = false },
    .{ .path = "elf.STB_HIOS", .replacement = "@intFromEnum(std.elf.STB.HIOS)", .is_std_path = false },
    .{ .path = "elf.STB_LOPROC", .replacement = "@intFromEnum(std.elf.STB.LOPROC)", .is_std_path = false },
    .{ .path = "elf.STB_HIPROC", .replacement = "@intFromEnum(std.elf.STB.HIPROC)", .is_std_path = false },
    .{ .path = "elf.STB_MIPS_SPLIT_COMMON", .replacement = "@intFromEnum(std.elf.STB.MIPS_SPLIT_COMMON)", .is_std_path = false },
    .{ .path = "elf.STB_NUM", .replacement = "elf.STB.NUM" },
    .{ .path = "elf.STT_NOTYPE", .replacement = "@intFromEnum(std.elf.STT.NOTYPE)", .is_std_path = false },
    .{ .path = "elf.STT_OBJECT", .replacement = "@intFromEnum(std.elf.STT.OBJECT)", .is_std_path = false },
    .{ .path = "elf.STT_FUNC", .replacement = "@intFromEnum(std.elf.STT.FUNC)", .is_std_path = false },
    .{ .path = "elf.STT_SECTION", .replacement = "@intFromEnum(std.elf.STT.SECTION)", .is_std_path = false },
    .{ .path = "elf.STT_FILE", .replacement = "@intFromEnum(std.elf.STT.FILE)", .is_std_path = false },
    .{ .path = "elf.STT_COMMON", .replacement = "@intFromEnum(std.elf.STT.COMMON)", .is_std_path = false },
    .{ .path = "elf.STT_TLS", .replacement = "@intFromEnum(std.elf.STT.TLS)", .is_std_path = false },
    .{ .path = "elf.STT_LOOS", .replacement = "@intFromEnum(std.elf.STT.LOOS)", .is_std_path = false },
    .{ .path = "elf.STT_GNU_IFUNC", .replacement = "@intFromEnum(std.elf.STT.GNU_IFUNC)", .is_std_path = false },
    .{ .path = "elf.STT_HIOS", .replacement = "@intFromEnum(std.elf.STT.HIOS)", .is_std_path = false },
    .{ .path = "elf.STT_LOPROC", .replacement = "@intFromEnum(std.elf.STT.LOPROC)", .is_std_path = false },
    .{ .path = "elf.STT_HIPROC", .replacement = "@intFromEnum(std.elf.STT.HIPROC)", .is_std_path = false },
    .{ .path = "elf.STT_SPARC_REGISTER", .replacement = "@intFromEnum(std.elf.STT.SPARC_REGISTER)", .is_std_path = false },
    .{ .path = "elf.STT_PARISC_MILLICODE", .replacement = "@intFromEnum(std.elf.STT.PARISC_MILLICODE)", .is_std_path = false },
    .{ .path = "elf.STT_HP_OPAQUE", .replacement = "@intFromEnum(std.elf.STT.HP_OPAQUE)", .is_std_path = false },
    .{ .path = "elf.STT_HP_STUB", .replacement = "@intFromEnum(std.elf.STT.HP_STUB)", .is_std_path = false },
    .{ .path = "elf.STT_ARM_TFUNC", .replacement = "@intFromEnum(std.elf.STT.ARM_TFUNC)", .is_std_path = false },
    .{ .path = "elf.STT_ARM_16BIT", .replacement = "@intFromEnum(std.elf.STT.ARM_16BIT)", .is_std_path = false },
    .{ .path = "elf.STT_NUM", .replacement = "elf.STT.NUM" },
    .{ .path = "elf.EI_CLASS", .replacement = "elf.EI.CLASS" },
    .{ .path = "elf.EI_DATA", .replacement = "elf.EI.DATA" },
    .{ .path = "elf.EI_VERSION", .replacement = "elf.EI.VERSION" },
    .{ .path = "elf.EI_OSABI", .replacement = "elf.EI.OSABI" },
    .{ .path = "elf.EI_ABIVERSION", .replacement = "elf.EI.ABIVERSION" },
    .{ .path = "elf.EI_PAD", .replacement = "elf.EI.PAD" },
    .{ .path = "elf.EI_NIDENT", .replacement = "elf.EI.NIDENT" },
    .{ .path = "elf.Elf32_Xword", .replacement = "elf.Xword" },
    .{ .path = "elf.Elf32_Sxword", .replacement = "elf.Sxword" },
    .{ .path = "elf.Elf64_Xword", .replacement = "elf.Xword" },
    .{ .path = "elf.Elf64_Sxword", .replacement = "elf.Sxword" },
    .{ .path = "elf.Elf32_Addr", .replacement = "elf.Elf32.Addr" },
    .{ .path = "elf.Elf64_Addr", .replacement = "elf.Elf64.Addr" },
    .{ .path = "elf.Elf32_Off", .replacement = "elf.Elf32.Off" },
    .{ .path = "elf.Elf64_Off", .replacement = "elf.Elf64.Off" },
    .{ .path = "elf.Elf32_Section", .replacement = "elf.Section" },
    .{ .path = "elf.Elf64_Section", .replacement = "elf.Section" },
    .{ .path = "elf.Elf32_Ehdr", .replacement = "elf.Elf32.Ehdr" },
    .{ .path = "elf.Elf64_Ehdr", .replacement = "elf.Elf64.Ehdr" },
    .{ .path = "elf.Elf32_Shdr", .replacement = "elf.Elf32.Shdr" },
    .{ .path = "elf.Elf64_Shdr", .replacement = "elf.Elf64.Shdr" },
    .{ .path = "elf.Elf32_Chdr", .replacement = "elf.Elf32.Chdr" },
    .{ .path = "elf.Elf64_Chdr", .replacement = "elf.Elf64.Chdr" },
    .{ .path = "elf.Elf32_Sym", .replacement = "elf.Elf32.Sym" },
    .{ .path = "elf.Elf64_Sym", .replacement = "elf.Elf64.Sym" },
    .{ .path = "elf.Elf32_Verneed", .replacement = "elf.Verneed" },
    .{ .path = "elf.Elf64_Verneed", .replacement = "elf.Verneed" },
    .{ .path = "elf.Ehdr", .replacement = "elf.ElfN.Ehdr" },
    .{ .path = "elf.Chdr", .replacement = "elf.ElfN.Chdr" },
    .{ .path = "elf.Sym", .replacement = "elf.ElfN.Sym" },
    .{ .path = "elf.Addr", .replacement = "elf.ElfN.Addr" },
    .{ .path = "elf.ELFCLASSNONE", .replacement = "@intFromEnum(std.elf.CLASS.NONE)", .is_std_path = false },
    .{ .path = "elf.ELFCLASS32", .replacement = "@intFromEnum(std.elf.CLASS.@\"32\")", .is_std_path = false },
    .{ .path = "elf.ELFCLASS64", .replacement = "@intFromEnum(std.elf.CLASS.@\"64\")", .is_std_path = false },
    .{ .path = "elf.ELFCLASSNUM", .replacement = "@intFromEnum(std.elf.CLASS.NUM)", .is_std_path = false },
    .{ .path = "elf.ELFDATANONE", .replacement = "@intFromEnum(std.elf.DATA.NONE)", .is_std_path = false },
    .{ .path = "elf.ELFDATA2LSB", .replacement = "@intFromEnum(std.elf.DATA.@\"2LSB\")", .is_std_path = false },
    .{ .path = "elf.ELFDATA2MSB", .replacement = "@intFromEnum(std.elf.DATA.@\"2MSB\")", .is_std_path = false },
    .{ .path = "elf.ELFDATANUM", .replacement = "@intFromEnum(std.elf.DATA.NUM)", .is_std_path = false },
};

const members = [_]MemberDeprecation{
    // Method/property renames that are unambiguous by name.
    .{ .name = "getLastOrNull", .replacement = "last" },
    .{ .name = "getLast", .note = "Index `items[items.len - 1]` directly." },
    .{ .name = "readAlloc", .replacement = "readAllocAll" },
    .{ .name = "sendMany", .replacement = "sendManyTimeout", .note = "Pass a `std.Io.Timeout.none` timeout." },
    .{ .name = "isAARCH64", .replacement = "isAarch64" },
    .{ .name = "isLoongArch", .replacement = "isLoongarch" },
    .{ .name = "isRISCV", .replacement = "isRiscv" },
    .{ .name = "isMIPS", .replacement = "isMips" },
    .{ .name = "isMIPS32", .replacement = "isMips32" },
    .{ .name = "isMIPS64", .replacement = "isMips64" },
    .{ .name = "isPowerPC", .replacement = "isPowerpc" },
    .{ .name = "isPowerPC32", .replacement = "isPowerpc32" },
    .{ .name = "isPowerPC64", .replacement = "isPowerpc64" },
    .{ .name = "isSPARC", .replacement = "isSparc" },
    .{ .name = "isSpirV", .replacement = "isSpirv" },
    .{ .name = "isBSD", .note = "Check the concrete OS tags instead." },
    .{ .name = "allocDescription", .replacement = "zigTriple" },
    .{ .name = "setGnuLibCVersion", .note = "Set `glibc_version` directly." },
    .{ .name = "enableTestRunnerMode", .replacement = "enableProtocolMode" },
    .{ .name = "addArtifactArg", .replacement = "addArtifactArg2", .note = "The `*2` replacement takes a `PathArgOptions` value; pass `.{}` or options explicitly." },
    .{ .name = "addPrefixedArtifactArg", .replacement = "addArtifactArg2", .note = "The `*2` replacement takes a `PathArgOptions` value; pass `.{}` or options explicitly." },
    .{ .name = "addOutputFileArg", .replacement = "addOutputFileArg2", .note = "The `*2` replacement takes a `PathArgOptions` value; pass `.{}` or options explicitly." },
    .{ .name = "addPrefixedOutputFileArg", .replacement = "addOutputFileArg2", .note = "The `*2` replacement takes a `PathArgOptions` value; pass `.{}` or options explicitly." },
    .{ .name = "addFileContentArg", .replacement = "addFileContentArg2", .note = "The `*2` replacement takes a `PathArgOptions` value; pass `.{}` or options explicitly." },
    .{ .name = "addPrefixedFileContentArg", .replacement = "addFileContentArg2", .note = "The `*2` replacement takes a `PathArgOptions` value; pass `.{}` or options explicitly." },
    .{ .name = "addOutputDirectoryArg", .replacement = "addOutputDirectoryArg2", .note = "The `*2` replacement takes a `PathArgOptions` value; pass `.{}` or options explicitly." },
    .{ .name = "addPrefixedOutputDirectoryArg", .replacement = "addOutputDirectoryArg2", .note = "The `*2` replacement takes a `PathArgOptions` value; pass `.{}` or options explicitly." },
    .{ .name = "addDirectoryArg", .replacement = "addDirectoryArg2", .note = "The `*2` replacement takes a `PathArgOptions` value; pass `.{}` or options explicitly." },
    .{ .name = "addPrefixedDirectoryArg", .replacement = "addDirectoryArg2", .note = "The `*2` replacement takes a `PathArgOptions` value; pass `.{}` or options explicitly." },
    .{ .name = "addDecoratedDirectoryArg", .replacement = "addDirectoryArg2", .note = "The `*2` replacement takes a `PathArgOptions` value; pass `.{}` or options explicitly." },
    .{ .name = "addDepFileOutputArg", .replacement = "addDepFileOutputArg2", .note = "The `*2` replacement takes a `PathArgOptions` value; pass `.{}` or options explicitly." },
    .{ .name = "addPrefixedDepFileOutputArg", .replacement = "addDepFileOutputArg2", .note = "The `*2` replacement takes a `PathArgOptions` value; pass `.{}` or options explicitly." },
    .{ .name = "runAllowFail", .replacement = "runFallible", .note = "`runFallible` returns a `RunResult`, not a string." },
    .{ .name = "lazyDependency", .replacement = "dependencyLazy", .note = "`dependencyLazy` returns an error union instead of an optional." },
};

const deprecation_map = std.StaticStringMap(Deprecation).initComptime(blk: {
    var kvs: [deprecations.len]DeprecationKv = undefined;
    for (deprecations, 0..) |entry, i| kvs[i] = .{ entry.path, entry };
    break :blk kvs;
});

const member_map = std.StaticStringMap(MemberDeprecation).initComptime(blk: {
    var kvs: [members.len]MemberKv = undefined;
    for (members, 0..) |entry, i| kvs[i] = .{ entry.name, entry };
    break :blk kvs;
});

const Chain = struct {
    node: Node.Index,
    leftmost: Node.Index,
    segments: [8][]const u8 = undefined,
    tokens: [8]TokenIndex = undefined,
    len: usize = 0,

    fn startsWith(self: Chain, prefix: []const u8) bool {
        return self.len > 0 and mem.eql(u8, self.segments[0], prefix);
    }
};

const Expansion = struct {
    /// Path below `std`.
    rel: [12][]const u8 = undefined,
    rel_len: usize = 0,
    /// How many `rel` segments came from the alias target.
    alias_prefix_len: usize = 0,
    literal_std: bool = false,
};

const Match = struct {
    entry: Deprecation,
    /// Number of dotted segments in the matched key.
    matched_len: usize,
    /// Offset in the joined path where the matched key ends.
    matched_end: usize,
};

fn getChain(ctx: *LinterContext, node: Node.Index) ?Chain {
    const ast = ctx.ast();
    var chain: Chain = .{ .node = node, .leftmost = .root };
    var curr = node;

    while (true) {
        switch (ast.nodeTag(curr)) {
            .field_access => {
                if (chain.len == chain.segments.len) return null;
                const data = ast.nodeData(curr).node_and_token;
                const token: TokenIndex = data[1];
                chain.segments[chain.len] = ctx.semantic.tokenSlice(token);
                chain.tokens[chain.len] = token;
                chain.len += 1;
                curr = data[0];
            },
            .identifier => {
                if (chain.len == chain.segments.len) return null;
                const token = ast.nodeMainToken(curr);
                chain.segments[chain.len] = ctx.semantic.tokenSlice(token);
                chain.tokens[chain.len] = token;
                chain.len += 1;
                chain.leftmost = curr;
                break;
            },
            else => return null,
        }
    }

    mem.reverse([]const u8, chain.segments[0..chain.len]);
    mem.reverse(TokenIndex, chain.tokens[0..chain.len]);
    return chain;
}

fn expandChain(ctx: *LinterContext, chain: Chain) ?Expansion {
    var exp: Expansion = .{};

    if (chain.startsWith("std")) {
        exp.literal_std = true;
        for (chain.segments[1..chain.len]) |segment| {
            if (exp.rel_len == exp.rel.len) return null;
            exp.rel[exp.rel_len] = segment;
            exp.rel_len += 1;
        }
        return if (exp.rel_len == 0) null else exp;
    }

    const init = ast_utils.resolveConstAlias(ctx, chain.leftmost) orelse return null;
    const target = getChain(ctx, init) orelse return null;
    if (!target.startsWith("std")) return null;

    for (target.segments[1..target.len]) |segment| {
        if (exp.rel_len == exp.rel.len) return null;
        exp.rel[exp.rel_len] = segment;
        exp.rel_len += 1;
    }
    exp.alias_prefix_len = target.len - 1;

    for (chain.segments[1..chain.len]) |segment| {
        if (exp.rel_len == exp.rel.len) return null;
        exp.rel[exp.rel_len] = segment;
        exp.rel_len += 1;
    }

    return if (exp.rel_len == 0) null else exp;
}

fn joinSegments(buf: []u8, segments: []const []const u8) ?[]const u8 {
    var len: usize = 0;
    for (segments, 0..) |segment, i| {
        if (i != 0) {
            if (len == buf.len) return null;
            buf[len] = '.';
            len += 1;
        }
        if (len + segment.len > buf.len) return null;
        @memcpy(buf[len..][0..segment.len], segment);
        len += segment.len;
    }
    return buf[0..len];
}

fn findMatch(path: []const u8) ?Match {
    var end = path.len;
    while (true) {
        if (deprecation_map.get(path[0..end])) |entry| {
            return .{
                .entry = entry,
                .matched_len = mem.count(u8, path[0..end], ".") + 1,
                .matched_end = end,
            };
        }
        const dot = mem.findScalarLast(u8, path[0..end], '.') orelse return null;
        end = dot;
    }
}

fn sourcePrefixCount(chain: Chain, exp: Expansion, matched_len: usize) usize {
    if (exp.literal_std) return matched_len + 1;
    if (matched_len >= exp.alias_prefix_len) {
        return 1 + (matched_len - exp.alias_prefix_len);
    }
    return chain.len;
}

fn isSameNamespace(entry: Deprecation, matched_key: []const u8) bool {
    const matched_dot = mem.findScalarLast(u8, matched_key, '.') orelse return false;
    const replacement_dot = mem.findScalarLast(u8, entry.replacement, '.') orelse return false;
    return mem.eql(u8, matched_key[0..matched_dot], entry.replacement[0..replacement_dot]);
}

fn lastReplacementSegment(entry: Deprecation) []const u8 {
    const dot = mem.findScalarLast(u8, entry.replacement, '.') orelse return entry.replacement;
    return entry.replacement[dot + 1 ..];
}

fn buildAbsolute(buf: []u8, replacement: []const u8, remaining: []const []const u8) ?[]const u8 {
    var len: usize = 0;
    const std_prefix = "std.";
    if (len + std_prefix.len + replacement.len > buf.len) return null;
    @memcpy(buf[len..][0..std_prefix.len], std_prefix);
    len += std_prefix.len;
    @memcpy(buf[len..][0..replacement.len], replacement);
    len += replacement.len;

    for (remaining) |segment| {
        if (len == buf.len) return null;
        buf[len] = '.';
        len += 1;
        if (len + segment.len > buf.len) return null;
        @memcpy(buf[len..][0..segment.len], segment);
        len += segment.len;
    }

    return buf[0..len];
}

fn buildDisplay(
    buf: []u8,
    source_prefix: []const u8,
    matched_key: []const u8,
    entry: Deprecation,
    remaining: []const []const u8,
) ?[]const u8 {
    if (entry.replacement.len == 0) return "";
    if (!entry.is_std_path) return entry.replacement;

    if (isSameNamespace(entry, matched_key)) {
        const dot = mem.findScalarLast(u8, source_prefix, '.') orelse return entry.replacement;
        const replacement = lastReplacementSegment(entry);
        const prefix_len = dot + 1;
        if (prefix_len + replacement.len > buf.len) return null;
        @memcpy(buf[0..prefix_len], source_prefix[0..prefix_len]);
        @memcpy(buf[prefix_len..][0..replacement.len], replacement);
        return buf[0 .. prefix_len + replacement.len];
    }

    return buildAbsolute(buf, entry.replacement, remaining);
}

fn reportPath(
    ctx: *LinterContext,
    chain: Chain,
    exp: Expansion,
    path: []const u8,
    match: Match,
) void {
    const prefix_count = sourcePrefixCount(chain, exp, match.matched_len);
    if (prefix_count == 0 or prefix_count > chain.len) return;

    const start = ctx.semantic.tokenSpan(chain.tokens[0]).start;
    const end = ctx.semantic.tokenSpan(chain.tokens[prefix_count - 1]).end;
    const span = Span.new(start, end);
    const source_prefix = ctx.source.text()[start..end];
    const matched_key = path[0..match.matched_end];
    const remaining = exp.rel[match.matched_len..exp.rel_len];

    var display_buf: [224]u8 = undefined;
    const display = buildDisplay(&display_buf, source_prefix, matched_key, match.entry, remaining) orelse "";
    // An alias can point at a deprecated namespace, e.g.
    // `const path = std.fs.path; path.join(...)`. The source prefix is only
    // `path`; name the namespace it resolves to so the message is actionable.
    const alias_namespace_only = !exp.literal_std and prefix_count == 1 and exp.alias_prefix_len > 0;

    const e = if (alias_namespace_only)
        if (display.len == 0)
            ctx.diagnosticf(
                "`{s}` resolves to deprecated `std.{s}`.",
                .{ source_prefix, matched_key },
                .{LabeledSpan.unlabeled(span)},
            )
        else
            ctx.diagnosticf(
                "`{s}` resolves to deprecated `std.{s}`; use `{s}` instead.",
                .{ source_prefix, matched_key, display },
                .{LabeledSpan.unlabeled(span)},
            )
    else if (display.len == 0)
        ctx.diagnosticf(
            "`{s}` is deprecated.",
            .{source_prefix},
            .{LabeledSpan.unlabeled(span)},
        )
    else
        ctx.diagnosticf(
            "`{s}` is deprecated; use `{s}` instead.",
            .{ source_prefix, display },
            .{LabeledSpan.unlabeled(span)},
        );

    ctx.report(e);
}

fn reportMember(ctx: *LinterContext, chain: Chain, member: MemberDeprecation) void {
    const token = chain.tokens[chain.len - 1];
    const span = ctx.semantic.tokenSpan(token);
    const source_prefix = ctx.semantic.tokenSlice(token);

    const e = if (member.replacement.len == 0)
        ctx.diagnosticf(
            "`{s}` is deprecated.",
            .{source_prefix},
            .{LabeledSpan.unlabeled(span)},
        )
    else
        ctx.diagnosticf(
            "`{s}` is deprecated; use `{s}` instead.",
            .{ source_prefix, member.replacement },
            .{LabeledSpan.unlabeled(span)},
        );

    ctx.report(e);
}

pub fn runOnNode(_: *const NoDeprecated, wrapper: NodeWrapper, ctx: *LinterContext) void {
    if (ctx.ast().nodeTag(wrapper.idx) != .field_access) return;
    // Only inspect the outermost field access in a chain. The nested
    // `std.builtin` inside `std.builtin.mode` would otherwise be reported as a
    // second, overlapping diagnostic.
    if (ctx.links().getParent(wrapper.idx)) |parent| {
        if (ctx.ast().nodeTag(parent) == .field_access and
            ctx.ast().nodeData(parent).node_and_token[0] == wrapper.idx)
        {
            return;
        }
    }

    const chain = getChain(ctx, wrapper.idx) orelse return;
    const exp = expandChain(ctx, chain) orelse {
        maybeReportMember(ctx, chain);
        return;
    };

    var path_buf: [192]u8 = undefined;
    const path = joinSegments(&path_buf, exp.rel[0..exp.rel_len]) orelse {
        maybeReportMember(ctx, chain);
        return;
    };

    if (findMatch(path)) |match| {
        reportPath(ctx, chain, exp, path, match);
        return;
    }

    maybeReportMember(ctx, chain);
}

fn maybeReportMember(ctx: *LinterContext, chain: Chain) void {
    if (chain.len < 2) return;
    const name = chain.segments[chain.len - 1];
    const member = member_map.get(name) orelse return;
    reportMember(ctx, chain, member);
}

pub fn rule(self: *NoDeprecated) Rule {
    return Rule.init(self);
}

const support = @import("tests/no_deprecated_support.zig");
test NoDeprecated {
    const t = std.testing;
    var rule_impl = NoDeprecated{};
    const rule_value = rule_impl.rule();

    const pass = &[_][:0]const u8{
        \\fn foo() void {
        \\    _ = 1;
        \\}
        \\
        ,
        \\const std = @import("std");
        \\fn find(haystack: []const u8) ?usize {
        \\    return std.mem.find(u8, haystack, "needle");
        \\}
        \\
        ,
        \\const builtin = @import("builtin");
        \\fn mode() void {
        \\    _ = builtin.mode;
        \\}
        \\
        ,
        \\const fmt = struct {
        \\    fn bufPrint() void {}
        \\};
        \\fn render() void {
        \\    fmt.bufPrint();
        \\}
        \\
        ,
        \\fn copy(reader: Reader) !void {
        \\    _ = try reader.readAllocAll(1);
        \\}
        \\
        ,
    };

    for (pass) |source| {
        try support.expectPass(t.allocator, rule_value, source);
    }

    const fail = &[_]struct {
        source: [:0]const u8,
        count: usize,
    }{
        .{
            .source =
            \\const std = @import("std");
            \\fn render(value: u32) ![]u8 {
            \\    var buffer: [32]u8 = undefined;
            \\    return std.fmt.bufPrint(&buffer, "{d}", .{value});
            \\}
            \\
            ,
            .count = 1,
        },
        .{
            .source =
            \\const std = @import("std");
            \\fn find(haystack: []const u8) ?usize {
            \\    return std.mem.indexOf(u8, haystack, "needle");
            \\}
            \\
            ,
            .count = 1,
        },
        .{
            .source =
            \\const std = @import("std");
            \\const fmt = std.fmt;
            \\fn render(value: u32) ![]u8 {
            \\    var buffer: [32]u8 = undefined;
            \\    return fmt.bufPrint(&buffer, "{d}", .{value});
            \\}
            \\
            ,
            .count = 1,
        },
        .{
            .source =
            \\const std = @import("std");
            \\fn mode() void {
            \\    _ = std.builtin.mode;
            \\}
            \\
            ,
            .count = 1,
        },
        .{
            .source =
            \\const std = @import("std");
            \\fn separator() []const u8 {
            \\    return std.fs.path.sep_str;
            \\}
            \\
            ,
            .count = 1,
        },
        .{
            .source =
            \\const std = @import("std");
            \\const List = std.ArrayListUnmanaged(u8);
            \\fn foo(list: *List) void { _ = list; }
            \\
            ,
            .count = 1,
        },
        .{
            .source =
            \\fn arch(arch: Arch) bool {
            \\    return arch.isAARCH64();
            \\}
            \\
            ,
            .count = 1,
        },
        .{
            .source =
            \\const std = @import("std");
            \\fn tag(header: std.elf.Ehdr) u16 {
            \\    _ = header;
            \\    return std.elf.SHT_PROGBITS;
            \\}
            \\
            ,
            .count = 2,
        },
    };

    for (fail) |case| {
        try support.expectFailCount(t.allocator, rule_value, case.source, case.count);
    }
}
