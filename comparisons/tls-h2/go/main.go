// TLS/H2 peer for comparisons/tls-h2 matrix (net/http; HTTP/2 on TLS automatic).
// Instrumentation: GET /_matrix/stats (reqs + bytes written via ResponseWriter wrap).
package main

import (
	"crypto/tls"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"sync/atomic"
)

var (
	metricReqs  atomic.Uint64
	metricBytes atomic.Uint64
)

func makePayload(n int) []byte {
	const pat = "0123456789abcdef0123456789ABCDEF0123456789abcdef0123456789ABCDEF"
	b := make([]byte, n)
	for i := 0; i < n; i++ {
		b[i] = pat[i%len(pat)]
	}
	return b
}

type countingWriter struct {
	http.ResponseWriter
	n int
}

func (w *countingWriter) Write(p []byte) (int, error) {
	n, err := w.ResponseWriter.Write(p)
	w.n += n
	return n, err
}

// Flush / push if underlying supports (H2).
func (w *countingWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func withMetrics(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		cw := &countingWriter{ResponseWriter: w}
		next(cw, r)
		metricReqs.Add(1)
		metricBytes.Add(uint64(cw.n))
	}
}

func plain(body []byte) http.HandlerFunc {
	return withMetrics(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("Server", "Go")
		_, _ = w.Write(body)
	})
}

func main() {
	port := env("PORT", "18443")
	workers := envInt("WORKERS", 8)
	cert := env("CERT_FILE", "certs/cert.pem")
	key := env("KEY_FILE", "certs/key.pem")
	_ = os.Setenv("GOMAXPROCS", strconv.Itoa(workers))

	p4k := makePayload(4 * 1024)
	p64k := makePayload(64 * 1024)
	p1m := makePayload(1024 * 1024)

	mux := http.NewServeMux()
	mux.HandleFunc("/plaintext", plain([]byte("Hello, World!")))
	mux.HandleFunc("/api/tiny", plain([]byte("Hello, World!")))
	mux.HandleFunc("/s/4k", plain(p4k))
	mux.HandleFunc("/s/64k", plain(p64k))
	mux.HandleFunc("/s/1m", plain(p1m))
	mux.HandleFunc("/sse", plain([]byte("event: ping\ndata: 1\n\nevent: ping\ndata: 2\n\n")))
	mux.HandleFunc("/_matrix/stats", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		fmt.Fprintf(w, "peer=go\nreqs=%d\nbytes=%d\ntls=crypto/tls\nio=net/http\n",
			metricReqs.Load(), metricBytes.Load())
	})
	mux.HandleFunc("/_matrix/reset", func(w http.ResponseWriter, r *http.Request) {
		metricReqs.Store(0)
		metricBytes.Store(0)
		w.Write([]byte("ok\n"))
	})

	addr := ":" + port
	log.Printf("go tls-h2 on %s cert=%s GOMAXPROCS=%d io=net/http tls=crypto/tls alpn=h2|http/1.1 instrument=reqs+bytes",
		addr, cert, workers)
	srv := &http.Server{
		Addr:    addr,
		Handler: mux,
		TLSConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
		},
	}
	log.Fatal(srv.ListenAndServeTLS(cert, key))
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
