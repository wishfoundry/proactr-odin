#!/usr/bin/env odin
// Portable builder for the WASI demo.
//   odin run examples/wasi_demo/build.odin -file
//   odin run examples/wasi_demo/build.odin -file -- --no-run
// Discovers `odin` and `wasmtime` on PATH (and env overrides), without
// hardcoding Homebrew paths.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

EXE_SUFFIX :: "" when ODIN_OS != .Windows else ".exe"

main :: proc() {
	no_run := false
	for a in os.args[1:] {
		if a == "--no-run" {
			no_run = true
		}
	}

	demo_dir := demo_directory()
	fmt.printf("demo_dir=%s\n", demo_dir)
	fmt.printf("ODIN_ROOT=%s\n", ODIN_ROOT)

	odin_exe, odin_ok := find_tool("odin", {"ODIN", "ODIN_EXE"})
	if !odin_ok {
		fmt.eprintln("error: could not find `odin` on PATH (set ODIN or ODIN_EXE)")
		os.exit(2)
	}
	fmt.printf("odin=%s\n", odin_exe)

	// Build only main.odin (-file) so this build.odin is not part of the package.
	main_src := path_join(demo_dir, "main.odin")
	out_wasm := path_join(demo_dir, "wasi_demo.wasm")
	cmd := []string{
		odin_exe,
		"build",
		main_src,
		"-file",
		"-target:wasi_wasm32",
		fmt.tprintf("-out:%s", out_wasm),
		"-o:speed",
	}
	fmt.printf("run: %s\n", strings.join(cmd, " "))
	if code := run_cmd(cmd, demo_dir); code != 0 {
		fmt.eprintf("odin build failed (exit %d)\n", code)
		os.exit(code)
	}
	if !os.exists(out_wasm) {
		fmt.eprintf("error: expected output missing: %s\n", out_wasm)
		os.exit(2)
	}
	fmt.printf("built %s\n", out_wasm)

	if no_run {
		fmt.println("skip run (--no-run)")
		return
	}

	wasmtime, wt_ok := find_tool("wasmtime", {"WASMTIME", "WASMTIME_EXE"})
	if !wt_ok {
		fmt.eprintln("error: wasmtime not found on PATH (install wasmtime, or set WASMTIME)")
		fmt.eprintln("built wasm only; re-run without --no-run after installing wasmtime")
		os.exit(2)
	}
	fmt.printf("wasmtime=%s\n", wasmtime)
	code := run_cmd([]string{wasmtime, out_wasm}, demo_dir)
	if code != 0 {
		fmt.eprintf("wasmtime failed (exit %d)\n", code)
		os.exit(code)
	}
}

// --- path discovery ----------------------------------------------------------

path_join :: proc(parts: ..string) -> string {
	s, _ := filepath.join(parts, context.temp_allocator)
	return s
}

path_clean :: proc(p: string) -> string {
	s, _ := filepath.clean(p, context.temp_allocator)
	return s
}

// Directory containing this demo's main.odin (examples/wasi_demo).
demo_directory :: proc() -> string {
	cwd, err := os.get_working_directory(context.temp_allocator)
	if err != nil {
		cwd = "."
	}
	if os.exists(path_join(cwd, "main.odin")) &&
	   (strings.contains(cwd, "wasi_demo") || os.exists(path_join(cwd, "build.odin"))) {
		return cwd
	}
	// Fall back: relative to cwd for `odin run examples/wasi_demo/build.odin -file`.
	cand := path_join(cwd, "examples", "wasi_demo")
	if os.exists(path_join(cand, "main.odin")) {
		return cand
	}
	return cwd
}

// Search PATH + env overrides for an executable. Never hardcodes Homebrew prefixes.
find_tool :: proc(name: string, env_keys: []string) -> (path: string, ok: bool) {
	for key in env_keys {
		if v := os.get_env(key, context.temp_allocator); v != "" {
			if os.exists(v) && os.is_file(v) {
				return v, true
			}
			// Allow bare name that is on PATH
			if p, p_ok := which(v); p_ok {
				return p, true
			}
		}
	}
	return which(name)
}

which :: proc(name: string) -> (path: string, ok: bool) {
	if strings.contains(name, "/") || strings.contains(name, "\\") {
		if os.exists(name) {
			return name, true
		}
		return "", false
	}

	path_env := os.get_env("PATH", context.temp_allocator)
	if path_env == "" {
		return "", false
	}

	sep: string
	when ODIN_OS == .Windows {
		sep = ";"
	} else {
		sep = ":"
	}

	// Portable user install locations — not Homebrew-specific.
	extra := make([dynamic]string, context.temp_allocator)
	if home := os.get_env("HOME", context.temp_allocator); home != "" {
		append(&extra, path_join(home, ".local", "bin"))
		append(&extra, path_join(home, ".cargo", "bin"))
	}
	if home := os.get_env("USERPROFILE", context.temp_allocator); home != "" {
		append(&extra, path_join(home, ".local", "bin"))
		append(&extra, path_join(home, ".cargo", "bin"))
	}
	// ODIN_ROOT/../bin (common when odin lives next to libexec)
	if ODIN_ROOT != "" {
		append(&extra, path_clean(path_join(ODIN_ROOT, "..", "bin")))
		append(&extra, path_clean(path_join(ODIN_ROOT, "bin")))
	}

	dirs := make([dynamic]string, context.temp_allocator)
	for d in strings.split(path_env, sep, context.temp_allocator) {
		if d != "" {
			append(&dirs, d)
		}
	}
	for d in extra {
		append(&dirs, d)
	}

	name_exe := fmt.tprintf("%s%s", name, EXE_SUFFIX)
	candidates := []string{name_exe, name}
	for dir in dirs {
		for c in candidates {
			p := path_join(dir, c)
			if os.exists(p) && os.is_file(p) {
				return p, true
			}
		}
	}
	return "", false
}

run_cmd :: proc(cmd: []string, work_dir: string) -> int {
	state, stdout, stderr, err := os.process_exec(
		{
			command     = cmd,
			working_dir = work_dir,
		},
		context.temp_allocator,
	)
	if len(stdout) > 0 {
		_, _ = os.write(os.stdout, stdout)
	}
	if len(stderr) > 0 {
		_, _ = os.write(os.stderr, stderr)
	}
	if err != nil {
		fmt.eprintf("process_exec error: %v\n", err)
		return 2
	}
	if !state.exited {
		return 2
	}
	return state.exit_code
}
