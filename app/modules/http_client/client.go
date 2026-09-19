package http_client

import (
	"fmt"
	"github.com/go-resty/resty/v2"
	"iptv-spider-sh/global"
	"net"
	"net/http"
	"strings"
	"time"
)

type HttpClient struct {
	client    *resty.Client
	userAgent string
	resp      *resty.Response
}

func (c *HttpClient) Request(uri, method string, form map[string]string) *HttpClient {
	r := c.client.R()
	method = strings.ToUpper(method)
	switch method {
	case "GET":
		r.SetQueryParams(form)
	case "POST":
		r.SetFormData(form)
	}
	global.LOG.Debug(fmt.Sprintf("%s %s", method, uri))
	var err error
	c.resp, err = r.Execute(method, uri)
	if err != nil {
		global.LOG.Error(fmt.Sprintf("%s %s", method, uri))
		global.LOG.Error(err.Error())
	}
	if c.resp != nil {
		global.LOG.Debug(fmt.Sprintf("Resp Body: %s", string(c.resp.Body())))
	}
	return c
}

func (c *HttpClient) GetResp() *resty.Response {
	return c.resp
}

func (c *HttpClient) GetRespBytes() []byte {
	if c.resp == nil {
		return nil
	}
	return c.resp.Body()
}

func NewHttpClient(opts ...HttpClientOption) *HttpClient {
	c := &HttpClient{
		userAgent: "webkit;Resolution(PAL,720P,1080P,2106P,4K)",
	}
	for _, opt := range opts {
		opt(c)
	}
	if c.client == nil {
		c.client = resty.New().SetTimeout(12 * time.Second)
	}
	c.afterAction()
	return c
}

func (c *HttpClient) afterAction() {
	// setUserAgent
	c.client.SetHeader("User-Agent", c.userAgent)
}

func (c *HttpClient) SetCookies(cookies ...*http.Cookie) {
	if len(cookies) <= 0 {
		return
	}
	// resty 的 Client.SetCookies 是纯追加语义：middleware 会把 c.Cookies 全部 AddCookie
	// 到每个请求的 Cookie 头，不按域名/名称去重。认证每次刷新会话都调 SetCookies 追加
	// 同名 JSESSIONID，跨 EPG 节点漂移（host 变化）后旧值仍不清，单头会累积几十上百个
	// 重复 Cookie、超 8KB 被上游门户以 400 拒收（2026-09-09 .90 回看 500 事故根因）。
	// 本客户端手工管理认证 Cookie：同名旧值全部清掉、只保留最新一次设置的即可。
	kept := c.client.Cookies[:0]
	for _, old := range c.client.Cookies {
		duplicate := false
		for _, nw := range cookies {
			if old != nil && nw != nil && old.Name == nw.Name {
				duplicate = true
				break
			}
		}
		if !duplicate {
			kept = append(kept, old)
		}
	}
	c.client.Cookies = append(kept, cookies...)
}

func (c *HttpClient) Cookies() []*http.Cookie {
	return c.client.Cookies
}

type HttpClientOption func(client *HttpClient)

func WithUserAgent(ua string) HttpClientOption {
	return func(c *HttpClient) {
		c.userAgent = ua
	}
}

func WithLocalAddr(addr string) HttpClientOption {
	return func(c *HttpClient) {
		tcpAddr, err := net.ResolveTCPAddr("tcp", addr)
		if err != nil {
			global.LOG.Warn("ResolveTCPAddr failed: " + addr)
		} else {
			global.LOG.Warn("ResolveTCPAddr success: " + addr)
		}
		c.client = resty.NewWithLocalAddr(tcpAddr).SetTimeout(12 * time.Second)
	}
}
