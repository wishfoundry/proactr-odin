// Plain text size ladder + fortunes (epoll/net poller — not io_uring).
package main

import (
	"database/sql"
	"html"
	"log"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

type fortune struct {
	ID      int
	Message string
}

func makePayload(n int) []byte {
	const pat = "0123456789abcdef0123456789ABCDEF0123456789abcdef0123456789ABCDEF"
	b := make([]byte, n)
	for i := 0; i < n; i++ {
		b[i] = pat[i%len(pat)]
	}
	return b
}

func main() {
	dbPath := env("DATABASE_PATH", "/tmp/proactr-tfb.sqlite")
	port := env("PORT", "18080")
	workers := envInt("WORKERS", 1)

	p4k := makePayload(4 * 1024)
	p64k := makePayload(64 * 1024)
	p1m := makePayload(1024 * 1024)
	p4m := makePayload(4 * 1024 * 1024)

	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()
	db.SetMaxOpenConns(max(workers*8, 16))
	db.SetMaxIdleConns(max(workers*4, 8))
	if err := db.Ping(); err != nil {
		log.Fatalf("ping %s: %v", dbPath, err)
	}
	_, _ = db.Exec(`PRAGMA busy_timeout=5000; PRAGMA journal_mode=WAL;`)

	mux := http.NewServeMux()
	mux.HandleFunc("/plaintext", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		_, _ = w.Write([]byte("Hello, World!"))
	})
	mux.HandleFunc("/s/4k", plainBytes(p4k))
	mux.HandleFunc("/s/64k", plainBytes(p64k))
	mux.HandleFunc("/s/1m", plainBytes(p1m))
	mux.HandleFunc("/s/4m", plainBytes(p4m))
	mux.HandleFunc("/fortunes", handleFortunes(db))

	addr := ":" + port
	log.Printf("go tfb peer on %s db=%s io=net/http(epoll) workers_hint=%d", addr, dbPath, workers)
	srv := &http.Server{
		Addr:              addr,
		Handler:           withServer(mux, "Go"),
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Fatal(srv.ListenAndServe())
}

func plainBytes(body []byte) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		_, _ = w.Write(body)
	}
}

func withServer(next http.Handler, name string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Server", name)
		next.ServeHTTP(w, r)
	})
}

func handleFortunes(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		rows, err := db.Query(`SELECT id, message FROM fortune`)
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		defer rows.Close()
		list := make([]fortune, 0, 16)
		for rows.Next() {
			var f fortune
			if err := rows.Scan(&f.ID, &f.Message); err != nil {
				http.Error(w, err.Error(), 500)
				return
			}
			list = append(list, f)
		}
		list = append(list, fortune{ID: 0, Message: "Additional fortune added at request time."})
		sort.Slice(list, func(i, j int) bool { return list[i].Message < list[j].Message })

		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		var b strings.Builder
		b.Grow(2048)
		b.WriteString("<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table>")
		b.WriteString("<tr><th>id</th><th>message</th></tr>")
		for _, f := range list {
			b.WriteString("<tr><td>")
			b.WriteString(strconv.Itoa(f.ID))
			b.WriteString("</td><td>")
			b.WriteString(html.EscapeString(f.Message))
			b.WriteString("</td></tr>")
		}
		b.WriteString("</table></body></html>")
		_, _ = w.Write([]byte(b.String()))
	}
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envInt(k string, def int) int {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
