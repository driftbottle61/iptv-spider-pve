package api

import (
	"bytes"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestIsPrivateClient(t *testing.T) {
	tests := map[string]bool{
		"192.168.100.50": true,
		"192.168.88.1":   true,
		"10.0.0.1":       true,
		"172.16.0.1":     true,
		"127.0.0.1":      true,
		"8.8.8.8":        false,
		"1.1.1.1":        false,
	}
	for address, expected := range tests {
		if actual := isPrivateClient(net.ParseIP(address)); actual != expected {
			t.Fatalf("isPrivateClient(%s) = %v, want %v", address, actual, expected)
		}
	}
	if isPrivateClient(nil) {
		t.Fatal("isPrivateClient(nil) = true, want false")
	}
}

func TestRelayHLSTreatsTail416AsCleanEOF(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/playlist.m3u8":
			_, _ = fmt.Fprint(writer, "#EXTM3U\n#EXTINF:6,\nsegment-1.ts\n#EXTINF:6,\nsegment-2.ts\n")
		case "/segment-1.ts":
			_, _ = writer.Write(bytes.Repeat([]byte{0x47}, 188))
		case "/segment-2.ts":
			writer.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
		default:
			writer.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()

	var output bytes.Buffer
	written, err := relayHLS(t.Context(), server.URL+"/playlist.m3u8", &output)
	if err != nil {
		t.Fatalf("relayHLS returned tail error: %v", err)
	}
	if written != 188 || output.Len() != 188 {
		t.Fatalf("relayHLS wrote %d bytes, buffer=%d; want 188", written, output.Len())
	}
}

func TestCatchupTailWindowKeepsFullSegment(t *testing.T) {
	programStart := time.Unix(1_000, 0)
	programEnd := time.Unix(2_000, 0)
	requestedStart, requestedEnd := normalizeCatchupWindow(programStart.Unix(), programEnd.Unix(), programEnd.Add(-time.Second).Unix(), programEnd.Add(time.Hour).Unix())
	if requestedEnd != programEnd.Unix() {
		t.Fatalf("end=%d, want %d", requestedEnd, programEnd.Unix())
	}
	if requestedEnd-requestedStart != int64(catchupMinTail/time.Second) {
		t.Fatalf("tail window=%ds, want %s", requestedEnd-requestedStart, catchupMinTail)
	}
}
