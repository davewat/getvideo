// getvideo: a single-binary service for macOS, Windows and Linux. It installs and updates yt-dlp,
// HandBrakeCLI and ffmpeg, then runs download -> transcode -> move jobs,
// driven from a React page served on localhost.
package main

import (
	"context"
	"embed"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"time"
)

//go:embed all:web
var webFS embed.FS

// version is stamped by build.sh.
var version = "dev"

func main() {
	port := flag.Int("port", 8765, "localhost port")
	noOpen := flag.Bool("no-open", false, "do not open the browser on start")
	dataDir := flag.String("data", "", "data directory (default: the platform's application-data folder)")
	flag.Parse()

	dir := *dataDir
	if dir == "" {
		var err error
		if dir, err = defaultDataDir(); err != nil {
			log.Fatal(err)
		}
	}
	tools, err := newTools(filepath.Join(dir, "bin"))
	if err != nil {
		log.Fatal(err)
	}
	q, err := newQueue(dir, tools)
	if err != nil {
		log.Fatal(err)
	}
	sub, _ := fs.Sub(webFS, "web")
	srv := newServer(tools, q, sub, *port)

	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", *port))
	if err != nil {
		log.Fatal(err)
	}
	httpSrv := &http.Server{Handler: srv.handler(), ReadHeaderTimeout: 10 * time.Second}
	url := fmt.Sprintf("http://127.0.0.1:%d", *port)
	log.Printf("getvideo %s listening on %s (data: %s)", version, url, dir)
	if !*noOpen {
		openBrowser(url)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	go func() {
		<-ctx.Done()
		q.shutdown()
		sctx, c := context.WithTimeout(context.Background(), 3*time.Second)
		defer c()
		_ = httpSrv.Shutdown(sctx)
	}()
	if err := httpSrv.Serve(ln); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}
