package http_client

import (
	"net/http"
	"testing"
)

func TestSetCookiesReplacesSameName(t *testing.T) {
	c := NewHttpClient()
	c.SetCookies(&http.Cookie{Name: "JSESSIONID", Value: "v1", Domain: "a:8084", Path: "/"})
	if got := len(c.Cookies()); got != 1 {
		t.Fatalf("cookies len = %d, want 1", got)
	}
	// 会话刷新且 EPG 节点漂移（host 变化）：同名旧值仍须被替换，避免 Cookie 头无限累积
	c.SetCookies(&http.Cookie{Name: "JSESSIONID", Value: "v2", Domain: "b:8084", Path: "/"})
	if got := len(c.Cookies()); got != 1 {
		t.Fatalf("cookies len after replace = %d, want 1", got)
	}
	if c.Cookies()[0].Value != "v2" {
		t.Fatalf("cookie value = %q, want v2", c.Cookies()[0].Value)
	}
}

func TestSetCookiesKeepsDifferentNames(t *testing.T) {
	c := NewHttpClient()
	c.SetCookies(&http.Cookie{Name: "JSESSIONID", Value: "s1"})
	c.SetCookies(&http.Cookie{Name: "Other", Value: "o1"})
	if got := len(c.Cookies()); got != 2 {
		t.Fatalf("cookies len = %d, want 2", got)
	}
}
