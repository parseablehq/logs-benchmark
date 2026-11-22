package systems

import (
	"fmt"
	"reflect"
	"testing"
	"time"

	"github.com/VictoriaMetrics/easyproto"
	"github.com/golang/snappy"

	"github.com/VictoriaMetrics/logs-benchmark/internal/source/synthetic"
)

// testEntries returns three records over two interleaved streams.
func testEntries() []LogEntry {
	hostA := &synthetic.HostInfo{Name: "host-a", Consts: []synthetic.Field{{Name: "zone", Value: "us-east1-b"}}}
	hostB := &synthetic.HostInfo{Name: "host-b", Consts: []synthetic.Field{{Name: "zone", Value: "us-east1-c"}}}
	for _, host := range []*synthetic.HostInfo{hostA, hostB} {
		host.ConstJSON = []byte(`,"zone":"` + host.Consts[0].Value + `"`)
	}
	app := &synthetic.AppInfo{
		Name:      `api "quoted"`,
		Consts:    []synthetic.Field{{Name: "replicas", Value: "3", Numeric: true}},
		ConstJSON: []byte(`,"replicas":3`),
		Lines: []synthetic.PoolField{
			{Name: "cache_status"},
			{Name: "duration_ms", Numeric: true},
		},
	}
	ts := time.Date(2026, 9, 27, 12, 0, 0, 123456789, time.UTC)
	record := func(host *synthetic.HostInfo, level, message, cache, duration string) synthetic.Record {
		return synthetic.Record{
			Host: host, App: app, Level: level, Message: message,
			LineVals: []string{cache, duration},
		}
	}
	return []LogEntry{
		{Rec: record(hostA, "info", "first", "hit", "12"), Ts: ts},
		{Rec: record(hostB, "error", "second", "miss", "0"), Ts: ts.Add(time.Second)},
		{Rec: record(hostA, "warning", "third", "bypass", "4999"), Ts: ts.Add(2 * time.Second)},
	}
}

func TestGroupByStream(t *testing.T) {
	groups := groupByStream(testEntries())
	var got [][]string
	for _, group := range groups {
		var messages []string
		for _, entry := range group {
			messages = append(messages, entry.Rec.Message)
		}
		got = append(got, messages)
	}
	want := [][]string{{"first", "third"}, {"second"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("unexpected groups: got %q; want %q", got, want)
	}
}

type lokiEntry struct {
	Seconds int64
	Nanos   int32
	Line    string
}

type lokiStream struct {
	Labels  string
	Entries []lokiEntry
}

func TestLokiPrepareBatch(t *testing.T) {
	entries := testEntries()
	batch, err := (&loki{}).PrepareBatch(entries)
	if err != nil {
		t.Fatalf("PrepareBatch: %v", err)
	}
	if batch.Lines != len(entries) {
		t.Fatalf("unexpected Lines: got %d; want %d", batch.Lines, len(entries))
	}
	protobuf, err := snappy.Decode(nil, batch.Body)
	if err != nil {
		t.Fatalf("the body is not snappy-compressed: %v", err)
	}
	got, err := decodeLokiPush(protobuf)
	if err != nil {
		t.Fatalf("cannot decode the request: %v", err)
	}

	entry := func(source LogEntry) lokiEntry {
		return lokiEntry{
			Seconds: source.Ts.Unix(),
			Nanos:   int32(source.Ts.Nanosecond()),
			Line:    string(synthetic.AppendJSON(nil, source.Rec, source.Ts)),
		}
	}
	want := []lokiStream{
		{Labels: `{app="api \"quoted\"", host="host-a"}`, Entries: []lokiEntry{entry(entries[0]), entry(entries[2])}},
		{Labels: `{app="api \"quoted\"", host="host-b"}`, Entries: []lokiEntry{entry(entries[1])}},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("unexpected request:\ngot  %+v\nwant %+v", got, want)
	}
}

func decodeLokiPush(src []byte) ([]lokiStream, error) {
	var streams []lokiStream
	err := forEachField(src, func(field *easyproto.FieldContext) error {
		if field.FieldNum != 1 {
			return fmt.Errorf("PushRequest: unexpected field %d", field.FieldNum)
		}
		data, _ := field.MessageData()
		var stream lokiStream
		err := forEachField(data, func(field *easyproto.FieldContext) error {
			switch field.FieldNum {
			case 1:
				stream.Labels, _ = field.String()
				return nil
			case 2:
				data, _ := field.MessageData()
				var entry lokiEntry
				err := forEachField(data, func(field *easyproto.FieldContext) error {
					switch field.FieldNum {
					case 1:
						data, _ := field.MessageData()
						return forEachField(data, func(field *easyproto.FieldContext) error {
							switch field.FieldNum {
							case 1:
								entry.Seconds, _ = field.Int64()
								return nil
							case 2:
								entry.Nanos, _ = field.Int32()
								return nil
							}
							return fmt.Errorf("Timestamp: unexpected field %d", field.FieldNum)
						})
					case 2:
						entry.Line, _ = field.String()
						return nil
					}
					return fmt.Errorf("EntryAdapter: unexpected field %d", field.FieldNum)
				})
				stream.Entries = append(stream.Entries, entry)
				return err
			}
			return fmt.Errorf("StreamAdapter: unexpected field %d", field.FieldNum)
		})
		streams = append(streams, stream)
		return err
	})
	return streams, err
}

func forEachField(src []byte, fn func(*easyproto.FieldContext) error) error {
	var field easyproto.FieldContext
	for len(src) > 0 {
		var err error
		src, err = field.NextField(src)
		if err != nil {
			return err
		}
		if err := fn(&field); err != nil {
			return err
		}
	}
	return nil
}
