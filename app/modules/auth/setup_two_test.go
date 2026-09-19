package auth

import (
	"testing"

	"go.uber.org/zap"

	"iptv-spider-sh/global"
	"iptv-spider-sh/utils"
)

func TestValidateEpgAuthInfo(t *testing.T) {
	tests := []struct {
		name    string
		info    map[string]string
		wantErr bool
	}{
		{
			name: "complete",
			info: map[string]string{
				"SessionID": "session",
				"IpPort":    "218.83.188.231:8084",
				"framecode": "frame1002",
			},
		},
		{
			name:    "missing session",
			info:    map[string]string{"IpPort": "218.83.188.231:8084", "framecode": "frame1002"},
			wantErr: true,
		},
		{
			name:    "missing host",
			info:    map[string]string{"SessionID": "session", "framecode": "frame1002"},
			wantErr: true,
		},
		{
			name:    "missing frame",
			info:    map[string]string{"SessionID": "session", "IpPort": "218.83.188.231:8084"},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, _, _, err := validateEpgAuthInfo(tt.info)
			if (err != nil) != tt.wantErr {
				t.Fatalf("validateEpgAuthInfo() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

func TestEPGLoadBalanceNoRedirectNoPanic(t *testing.T) {
	// 页面没有 top.document.location 时（如上游 400/异常页），旧实现 uri=="" 且
	// url.Parse 返回 nil err，随后 err.Error() 触发 nil 指针 panic（.90 事故）。
	// 应安全返回 nil 且不 panic。
	if global.LOG == nil {
		global.LOG = zap.NewNop()
	}
	doc := utils.CreateHtmlDocByBytes("http://epg.example/", []byte(`<html><head></head><body><script>var x = 1;</script></body></html>`))
	if doc == nil {
		t.Fatal("failed to build test document")
	}
	c := &Client{}
	if got := c.epgLoadBalance(doc); got != nil {
		t.Fatalf("expected nil doc when no top.document.location, got %v", got)
	}
}
