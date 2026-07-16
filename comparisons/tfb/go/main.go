// TechEmpower-shaped peer: net/http + SQLite (json, plaintext, fortunes, db, queries).
package main

import (
	"database/sql"
	"encoding/json"
	"html"
	"log"
	"math/rand"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

type messageJSON struct {
	Message string `json:"message"`
}

type worldRow struct {
	ID           int `json:"id"`
	RandomNumber int `json:"randomNumber"`
}

type fortune struct {
	ID      int
	Message string
}

func main() {
	dbPath := env("DATABASE_PATH", "/tmp/proactr-tfb.sqlite")
	port := env("PORT", "18080")
	workers := envInt("WORKERS", 1) // GOMAXPROCS left alone; net/http is multi-core

	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()
	db.SetMaxOpenConns(max(workers*8, 16))
	db.SetMaxIdleConns(max(workers*4, 8))
	if err := db.Ping(); err != nil {
		log.Fatalf("ping %s: %v (run comparisons/tfb/schema/prepare.sh)", dbPath, err)
	}
	if _, err := db.Exec(`PRAGMA busy_timeout=5000; PRAGMA journal_mode=WAL;`); err != nil {
		log.Printf("pragma: %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/json", handleJSON)
	mux.HandleFunc("/plaintext", handlePlaintext)
	mux.HandleFunc("/fortunes", handleFortunes(db))
	mux.HandleFunc("/db", handleDB(db))
	mux.HandleFunc("/queries", handleQueries(db))

	addr := ":" + port
	log.Printf("go tfb peer on %s db=%s workers_hint=%d", addr, dbPath, workers)
	srv := &http.Server{
		Addr:              addr,
		Handler:           withServerHeader(mux),
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Fatal(srv.ListenAndServe())
}

func withServerHeader(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Server", "Go")
		next.ServeHTTP(w, r)
	})
}

func handleJSON(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(messageJSON{Message: "Hello, World!"})
}

func handlePlaintext(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain")
	_, _ = w.Write([]byte("Hello, World!"))
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

func handleDB(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := rand.Intn(10000) + 1
		var row worldRow
		err := db.QueryRow(`SELECT id, randomNumber FROM world WHERE id = ?`, id).
			Scan(&row.ID, &row.RandomNumber)
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(row)
	}
}

func handleQueries(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		n := 1
		if q := r.URL.Query().Get("queries"); q != "" {
			if v, err := strconv.Atoi(q); err == nil {
				n = v
			}
		}
		if n < 1 {
			n = 1
		}
		if n > 500 {
			n = 500
		}
		out := make([]worldRow, 0, n)
		for i := 0; i < n; i++ {
			id := rand.Intn(10000) + 1
			var row worldRow
			err := db.QueryRow(`SELECT id, randomNumber FROM world WHERE id = ?`, id).
				Scan(&row.ID, &row.RandomNumber)
			if err != nil {
				http.Error(w, err.Error(), 500)
				return
			}
			out = append(out, row)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(out)
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
