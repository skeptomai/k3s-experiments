package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"sync/atomic"
	"time"
)

var active int64

func main() {
	pod := os.Getenv("POD_NAME")
	if pod == "" {
		pod, _ = os.Hostname()
	}

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Pod-Name", pod)
		json.NewEncoder(w).Encode(map[string]any{
			"pod":    pod,
			"active": atomic.LoadInt64(&active),
			"ts":     time.Now().UTC().Format(time.RFC3339Nano),
		})
	})

	// /slow?s=N  — holds the connection for N seconds (default 20).
	// Increments the active counter for the duration so the IPVS least-connection
	// scheduler can see this pod as loaded and route new connections elsewhere.
	http.HandleFunc("/slow", func(w http.ResponseWriter, r *http.Request) {
		sec := 20
		if s := r.URL.Query().Get("s"); s != "" {
			if n, err := strconv.Atoi(s); err == nil && n >= 1 && n <= 120 {
				sec = n
			}
		}
		n := atomic.AddInt64(&active, 1)
		defer atomic.AddInt64(&active, -1)

		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("X-Pod-Name", pod)
		fmt.Fprintf(w, "pod=%-40s  hold=%3ds  active_on_pod=%d\n", pod, sec, n)
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		// Use context so the active counter decrements immediately when the
		// client disconnects (e.g. demo script kills the curl process).
		timer := time.NewTimer(time.Duration(sec) * time.Second)
		defer timer.Stop()
		select {
		case <-r.Context().Done():
		case <-timer.C:
			fmt.Fprintf(w, "pod=%-40s  done\n", pod)
		}
	})

	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	fmt.Printf("pod=%s  listening :8080\n", pod)
	if err := http.ListenAndServe(":8080", nil); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
