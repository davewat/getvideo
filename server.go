package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io/fs"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

type server struct {
	tools *tools
	q     *queue
	web   fs.FS
	port  int
}

func newServer(t *tools, q *queue, web fs.FS, port int) *server {
	return &server{tools: t, q: q, web: web, port: port}
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func httpErr(w http.ResponseWriter, code int, err error) {
	writeJSON(w, code, map[string]string{"error": err.Error()})
}

func (s *server) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/tools", func(w http.ResponseWriter, r *http.Request) {
		ctx, c := context.WithTimeout(r.Context(), 15*time.Second)
		defer c()
		writeJSON(w, 200, s.tools.status(ctx, r.URL.Query().Get("check") == "1"))
	})
	mux.HandleFunc("POST /api/tools/{name}/install", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("name")
		known := false
		for _, n := range toolNames {
			known = known || n == name
		}
		if !known {
			httpErr(w, 404, fmt.Errorf("unknown tool %q", name))
			return
		}
		// Runs detached from the request so closing the tab doesn't abort it.
		go func() { _ = s.tools.install(context.Background(), name) }()
		writeJSON(w, 202, map[string]string{"status": "started"})
	})
	mux.HandleFunc("GET /api/handbrake/presets", func(w http.ResponseWriter, r *http.Request) {
		g, err := s.tools.presets(r.Context())
		if err != nil {
			httpErr(w, 409, err)
			return
		}
		writeJSON(w, 200, g)
	})
	mux.HandleFunc("GET /api/jobs", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, s.q.list())
	})
	mux.HandleFunc("POST /api/jobs", func(w http.ResponseWriter, r *http.Request) {
		var j Job
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&j); err != nil {
			httpErr(w, 400, err)
			return
		}
		if err := s.q.add(&j); err != nil {
			httpErr(w, 400, err)
			return
		}
		writeJSON(w, 201, j)
	})
	mux.HandleFunc("POST /api/jobs/{id}/cancel", func(w http.ResponseWriter, r *http.Request) {
		s.ok(w, s.q.cancelJob(r.PathValue("id")))
	})
	mux.HandleFunc("POST /api/jobs/{id}/retry", func(w http.ResponseWriter, r *http.Request) {
		s.ok(w, s.q.retry(r.PathValue("id")))
	})
	mux.HandleFunc("DELETE /api/jobs/{id}", func(w http.ResponseWriter, r *http.Request) {
		s.ok(w, s.q.remove(r.PathValue("id")))
	})
	mux.HandleFunc("POST /api/reveal", func(w http.ResponseWriter, r *http.Request) {
		var b struct {
			Path string `json:"path"`
		}
		if err := json.NewDecoder(r.Body).Decode(&b); err != nil {
			httpErr(w, 400, err)
			return
		}
		if _, err := os.Stat(b.Path); err != nil {
			httpErr(w, 404, err)
			return
		}
		_ = exec.Command("open", "-R", b.Path).Start()
		writeJSON(w, 200, map[string]bool{"ok": true})
	})
	mux.HandleFunc("POST /api/pick-folder", func(w http.ResponseWriter, r *http.Request) {
		out, err := exec.CommandContext(r.Context(), "osascript", "-e",
			`POSIX path of (choose folder with prompt "Choose where to save the video")`).Output()
		if err != nil { // the user cancelled the dialog
			writeJSON(w, 200, map[string]string{"path": ""})
			return
		}
		writeJSON(w, 200, map[string]string{"path": strings.TrimRight(strings.TrimSpace(string(out)), "/")})
	})
	mux.HandleFunc("GET /api/events", s.events)
	mux.Handle("/", spa(s.web))
	return s.guard(mux)
}

func (s *server) ok(w http.ResponseWriter, found bool) {
	if !found {
		httpErr(w, 404, fmt.Errorf("not found or not allowed in its current state"))
		return
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}

func (s *server) events(w http.ResponseWriter, r *http.Request) {
	fl, ok := w.(http.Flusher)
	if !ok {
		httpErr(w, 500, fmt.Errorf("streaming unsupported"))
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	ch, unsub := s.q.subscribe()
	defer unsub()
	fmt.Fprint(w, ": hello\n\n")
	fl.Flush()
	tick := time.NewTicker(20 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case b := <-ch:
			fmt.Fprintf(w, "data: %s\n\n", b)
			fl.Flush()
		case <-tick.C:
			fmt.Fprint(w, ": ping\n\n")
			fl.Flush()
		}
	}
}

// guard keeps the API reachable only from this machine's own page: it rejects foreign Host
// headers (DNS rebinding) and requires a custom header on writes, which forces a CORS preflight
// for any other website that tries to drive the local service.
func (s *server) guard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.Host)
		if err != nil {
			host = r.Host
		}
		if host != "127.0.0.1" && host != "localhost" {
			http.Error(w, "forbidden host", http.StatusForbidden)
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			if r.Header.Get("X-GetVideo") != "1" {
				http.Error(w, "missing X-GetVideo header", http.StatusForbidden)
				return
			}
			if o := r.Header.Get("Origin"); o != "" && o != "http://127.0.0.1:"+fmt.Sprint(s.port) && o != "http://localhost:"+fmt.Sprint(s.port) {
				http.Error(w, "forbidden origin", http.StatusForbidden)
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

// spa serves the embedded React build, falling back to index.html for client routes.
func spa(fsys fs.FS) http.Handler {
	files := http.FileServerFS(fsys)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := strings.TrimPrefix(r.URL.Path, "/")
		if p != "" {
			if _, err := fs.Stat(fsys, p); err != nil {
				r.URL.Path = "/"
			}
		}
		files.ServeHTTP(w, r)
	})
}
