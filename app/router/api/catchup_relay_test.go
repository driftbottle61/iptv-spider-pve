package api

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// 回归：上游对刚重认证/刚签发播放列表偶发返回 400（实测 2026-09-13、09-16、09-19 各一次），
// 若不算可重试，整条回放流会以 bytes=0 直接失败（客户端表现为"第一次点回放没反应"）。
func TestRetryableRelayErrorIncludesBadRequest(t *testing.T) {
	cases := map[int]bool{
		400: true, 401: true, 403: true, 404: true, 429: true, 500: true, 503: true,
		302: false, 416: false, 200: false,
	}
	for status, want := range cases {
		err := &hlsRelayError{status: status, err: fmt.Errorf("HLS request returned %d", status)}
		if got := retryableRelayError(err); got != want {
			t.Errorf("retryableRelayError(status=%d) = %v, want %v", status, got, want)
		}
	}
	if retryableRelayError(context.Canceled) {
		t.Error("context.Canceled 不应可重试（客户端已断开）")
	}
	if retryableRelayError(errors.New("upstream returned empty response")) {
		t.Error("普通错误不应可重试")
	}
}

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
