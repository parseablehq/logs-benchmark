package systems

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"

	"github.com/VictoriaMetrics/logs-benchmark/internal/source/synthetic"
)

const defaultParseableStream = "logs-bench"

// parseable sends JSON arrays to Parseable's native JSON ingestion endpoint.
// Credentials and the destination dataset come from environment variables so
// they can be supplied by Kubernetes Secrets without appearing in pod args.
type parseable struct {
	addr     string
	username string
	password string
	stream   string
}

func newParseable(addr string) (*parseable, error) {
	username := os.Getenv("PARSEABLE_USERNAME")
	password := os.Getenv("PARSEABLE_PASSWORD")
	if username == "" || password == "" {
		return nil, fmt.Errorf("PARSEABLE_USERNAME and PARSEABLE_PASSWORD must be set")
	}
	stream := os.Getenv("PARSEABLE_STREAM")
	if stream == "" {
		stream = defaultParseableStream
	}
	return &parseable{
		addr:     strings.TrimRight(addr, "/"),
		username: username,
		password: password,
		stream:   stream,
	}, nil
}

func (s *parseable) authenticate(req *http.Request) {
	req.SetBasicAuth(s.username, s.password)
}

func (s *parseable) WaitReady() error {
	return waitHTTP(s.addr+"/api/v1/readiness", status2xx)
}

// PrepareBatch encodes the same flat structured records used by the other JSON
// adapters as one JSON array. Parseable accepts either a single object or an
// array at /api/v1/ingest.
func (s *parseable) PrepareBatch(entries []LogEntry) (Batch, error) {
	buf := make([]byte, 0, len(entries)*1024)
	buf = append(buf, '[')
	for i, e := range entries {
		if i > 0 {
			buf = append(buf, ',')
		}
		buf = synthetic.AppendJSON(buf, e.Rec, e.Ts)
	}
	buf = append(buf, ']')
	return Batch{Body: buf, Lines: len(entries)}, nil
}

func (s *parseable) Send(ctx context.Context, b Batch) (int, error) {
	mutate := func(req *http.Request) {
		s.authenticate(req)
		req.Header.Set("X-P-Stream", s.stream)
	}
	_, _, retries, err := doReqWith(ctx, http.MethodPost, s.addr+"/api/v1/ingest", "application/json", b.Body, mutate)
	return retries, err
}

// Queries is intentionally empty for the ingestion-only benchmark. The
// querier still polls StoredRows every 15 seconds when queryInterval is zero.
func (s *parseable) Queries(QueryParams) []Query { return nil }

// StoredRows uses Parseable's stream statistics rather than a COUNT(*) query,
// avoiding a data scan while the target is CPU-saturated. lifetime_count is
// the exact number of events accepted into the stream's staging writer.
func (s *parseable) StoredRows(ctx context.Context) (*int64, error) {
	reqURL := s.addr + "/api/v1/logstream/" + url.PathEscape(s.stream) + "/stats"
	body, err := doQueryWith(ctx, http.MethodGet, reqURL, "", nil, s.authenticate)
	if err != nil {
		return nil, err
	}
	var result struct {
		Ingestion struct {
			LifetimeCount uint64 `json:"lifetime_count"`
		} `json:"ingestion"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, fmt.Errorf("parse stream stats: %w: %s", err, truncate(string(body), 200))
	}
	if result.Ingestion.LifetimeCount > uint64(^uint64(0)>>1) {
		return nil, fmt.Errorf("stream stats lifetime_count overflows int64: %d", result.Ingestion.LifetimeCount)
	}
	n := int64(result.Ingestion.LifetimeCount)
	return &n, nil
}
