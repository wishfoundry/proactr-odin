// Minimal sqlite3 C bindings for the TFB fortunes peer.
package main

import "core:c"

when ODIN_OS == .Darwin || ODIN_OS == .Linux {
	foreign import sqlite3 "system:sqlite3"
} else {
	#panic("tfb proactr fortunes requires sqlite3 on Darwin/Linux")
}

SQLITE_OK :: 0
SQLITE_ROW :: 100
SQLITE_DONE :: 101
SQLITE_OPEN_READONLY :: 0x00000001
SQLITE_OPEN_READWRITE :: 0x00000002
SQLITE_OPEN_NOMUTEX :: 0x00008000

sqlite3_t :: struct {}
sqlite3_stmt :: struct {}

@(default_calling_convention = "c")
foreign sqlite3 {
	sqlite3_open_v2 :: proc(
		filename: cstring,
		ppDb:     ^^sqlite3_t,
		flags:    c.int,
		zVfs:     cstring,
	) -> c.int ---
	sqlite3_close :: proc(db: ^sqlite3_t) -> c.int ---
	sqlite3_busy_timeout :: proc(db: ^sqlite3_t, ms: c.int) -> c.int ---
	sqlite3_exec :: proc(
		db:       ^sqlite3_t,
		sql:      cstring,
		callback: rawptr,
		arg:      rawptr,
		errmsg:   ^cstring,
	) -> c.int ---
	sqlite3_prepare_v2 :: proc(
		db:     ^sqlite3_t,
		zSql:   cstring,
		nByte:  c.int,
		ppStmt: ^^sqlite3_stmt,
		pzTail: ^cstring,
	) -> c.int ---
	sqlite3_step :: proc(stmt: ^sqlite3_stmt) -> c.int ---
	sqlite3_reset :: proc(stmt: ^sqlite3_stmt) -> c.int ---
	sqlite3_finalize :: proc(stmt: ^sqlite3_stmt) -> c.int ---
	sqlite3_column_int :: proc(stmt: ^sqlite3_stmt, iCol: c.int) -> c.int ---
	sqlite3_column_text :: proc(stmt: ^sqlite3_stmt, iCol: c.int) -> cstring ---
	sqlite3_column_bytes :: proc(stmt: ^sqlite3_stmt, iCol: c.int) -> c.int ---
	sqlite3_errmsg :: proc(db: ^sqlite3_t) -> cstring ---
}
