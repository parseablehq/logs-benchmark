package systems

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestParseablePrepareBatch(t *testing.T) {
	entries := testEntries()
	s := &parseable{}
	b, err := s.PrepareBatch(entries)
	if err != nil {
		t.Fatalf("PrepareBatch: %v", err)
	}
	if b.Lines != len(entries) {
		t.Fatalf("unexpected Lines: got %d; want %d", b.Lines, len(entries))
	}
	var got []map[string]any
	if err := json.Unmarshal(b.Body, &got); err != nil {
		t.Fatalf("body is not a JSON array: %v\n%s", err, b.Body)
	}
	if len(got) != len(entries) {
		t.Fatalf("unexpected records: got %d; want %d", len(got), len(entries))
	}
	if got[1]["host"] != "host-b" || got[1]["message"] != "second" || got[1]["duration_ms"] != float64(0) {
		t.Fatalf("unexpected second record: %#v", got[1])
	}
}

func TestParseableSendAndStoredRows(t *testing.T) {
	const username, password, stream = "bench-user", "bench-password", "bench-stream"
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/v1/ingest", func(w http.ResponseWriter, r *http.Request) {
		user, pass, ok := r.BasicAuth()
		if !ok || user != username || pass != password {
			t.Errorf("unexpected basic auth: user=%q pass=%q ok=%v", user, pass, ok)
		}
		if got := r.Header.Get("X-P-Stream"); got != stream {
			t.Errorf("X-P-Stream=%q; want %q", got, stream)
		}
		if got := r.Header.Get("Content-Type"); got != "application/json" {
			t.Errorf("Content-Type=%q; want application/json", got)
		}
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("GET /api/v1/logstream/bench-stream/stats", func(w http.ResponseWriter, r *http.Request) {
		user, pass, ok := r.BasicAuth()
		if !ok || user != username || pass != password {
			t.Errorf("unexpected stats basic auth: user=%q pass=%q ok=%v", user, pass, ok)
		}
		_, _ = w.Write([]byte(`{"ingestion":{"lifetime_count":12345}}`))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	s := &parseable{addr: srv.URL, username: username, password: password, stream: stream}
	if _, err := s.Send(context.Background(), Batch{Body: []byte(`[]`)}); err != nil {
		t.Fatalf("Send: %v", err)
	}
	rows, err := s.StoredRows(context.Background())
	if err != nil {
		t.Fatalf("StoredRows: %v", err)
	}
	if rows == nil || *rows != 12345 {
		t.Fatalf("StoredRows=%v; want 12345", rows)
	}
}

func TestNewParseableFromEnvironment(t *testing.T) {
	t.Setenv("PARSEABLE_USERNAME", "user")
	t.Setenv("PARSEABLE_PASSWORD", "pass")
	t.Setenv("PARSEABLE_STREAM", "events")
	s, err := newParseable("http://parseable/")
	if err != nil {
		t.Fatalf("newParseable: %v", err)
	}
	if s.addr != "http://parseable" || s.stream != "events" {
		t.Fatalf("unexpected client: %#v", s)
	}
}
