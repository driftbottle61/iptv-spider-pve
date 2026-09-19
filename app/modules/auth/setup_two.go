package auth

import (
	"encoding/hex"
	"fmt"
	"github.com/PuerkitoBio/goquery"
	"github.com/robertkrimen/otto"
	"iptv-spider-sh/global"
	"iptv-spider-sh/utils"
	"net/url"
	"strings"
)

func (c *Client) epgIndex(doc *goquery.Document) *goquery.Document {
	if doc == nil || doc.Url == nil {
		global.LOG.Error("EPG入口页面为空")
		return nil
	}
	uri, method, formMap := utils.GetFromParamByHtml(doc, "form#epgform")
	if formMap == nil || uri == "" {
		global.LOG.Error("EPG入口缺少有效表单")
		return nil
	}
	// 保存 Token
	c.UserToken = formMap["UserToken"]
	resp := c.httpClient.Request(uri, method, formMap)
	return utils.CreateHtmlDocByBytes(uri, resp.GetRespBytes())
}

func (c *Client) epgLoadBalance(doc *goquery.Document) *goquery.Document {
	if doc == nil || doc.Url == nil {
		return nil
	}
	var uri string
	scs := utils.GetScriptsFormHtml(doc)
	for _, sc := range scs {
		if !strings.Contains(sc, "top.document.location") {
			continue
		}
		sArr := strings.Split(sc, "\n")
		for _, s := range sArr {
			if !strings.Contains(s, "top.document.location") {
				continue
			}
			index := strings.Index(s, "'")
			last := strings.LastIndex(s, "'")
			if index < 0 || last < 0 {
				global.LOG.Error("No top.document.location")
				return nil
			}
			uri = s[index+1 : last]
		}
	}
	if uri == "" {
		// uri 为空时 url.Parse 返回的 err 是 nil，直接走 err.Error() 会 nil 指针 panic
		// （2026-09-09 .90 回看 500 事故根因之一：Cookie 头超 8KB 被门户 400 拒收后
		// 页面无 top.document.location，此处 panic → iris recover → 500）
		global.LOG.Error("EPG负载均衡页面未返回 top.document.location 跳转地址")
		return nil
	}
	u, err := url.Parse(uri)
	if err != nil {
		global.LOG.Error(fmt.Sprintf("解析EPG负载均衡跳转地址失败: %s, err=%v", uri, err))
		return nil
	}
	if u.Scheme == "" || u.Host == "" {
		global.LOG.Error(fmt.Sprintf("EPG负载均衡跳转地址不完整: %s", uri))
		return nil
	}
	c.EPGLoginHost = u.Host
	resp := c.httpClient.Request(uri, "GET", nil)
	return utils.CreateHtmlDocByBytes(uri, resp.GetRespBytes())
}

func (c *Client) epgPortalAuth(doc *goquery.Document) (*goquery.Document, error) {
	if doc == nil || doc.Url == nil {
		return nil, fmt.Errorf("EPG认证页面为空")
	}
	uri, method, formMap := utils.GetFromParamByHtml(doc, "form")
	if formMap == nil || uri == "" {
		return nil, fmt.Errorf("EPG认证页面缺少有效表单")
	}

	r := utils.RSA{}
	r.LoadPriKey(utils.GetRSAPriKey())

	token := formMap["UserToken"]
	plainData := utils.InsertStrInUserToken(token)
	if plainData == "" {
		global.LOG.Error("InsertStrInUserToken: plainData is empty, Token: " + token)
		return nil, fmt.Errorf("token is empty")
	}
	stbInfo := hex.EncodeToString(r.PriEncrypt([]byte(plainData)))
	formMap["stbtype"] = c.stbType
	formMap["stbinfo"] = strings.ToUpper(stbInfo)

	resp := c.httpClient.Request(uri, method, formMap)
	respDoc := utils.CreateHtmlDocByBytes(uri, resp.GetRespBytes())

	//jsSetConfig('SessionID','777ABD76B5E1C3554016FBA0EFDA2F66');
	//jsSetConfig('framecode','frame1413');
	//jsSetConfig('IpPort','218.83.165.40:8084');
	//jsSetConfig('EPGDefaultChannelNo','0');

	infoMap := c.parseEpgAuthInfo(respDoc)
	sessionID, ipPort, frameCode, err := validateEpgAuthInfo(infoMap)
	if err != nil {
		return nil, err
	}
	c.JSESSIONID = sessionID
	c.EPGHostUrl = fmt.Sprintf("http://%s/iptvepg/%s", ipPort, frameCode)

	return respDoc, nil
}

func validateEpgAuthInfo(infoMap map[string]string) (string, string, string, error) {
	sessionID := strings.TrimSpace(infoMap["SessionID"])
	ipPort := strings.TrimSpace(infoMap["IpPort"])
	frameCode := strings.TrimSpace(infoMap["framecode"])
	if sessionID == "" || ipPort == "" || frameCode == "" {
		return "", "", "", fmt.Errorf("EPG authentication response incomplete: SessionID=%t IpPort=%t framecode=%t",
			sessionID != "", ipPort != "", frameCode != "")
	}
	return sessionID, ipPort, frameCode, nil
}

func (c *Client) parseEpgAuthInfo(doc *goquery.Document) map[string]string {
	cache := map[string]string{}
	c.jsVM.Reset()
	c.jsVM.RunScriptForHtml(doc)
	c.jsVM.Set("jsSetConfig", func(call otto.FunctionCall) otto.Value {
		k := call.Argument(0).String()
		v := call.Argument(1).String()
		cache[k] = v
		return otto.Value{}
	})
	scs := utils.GetScriptsFormHtml(doc)
	for _, sc := range scs {
		sArr := strings.Split(sc, "\n")
		for _, s := range sArr {
			if !strings.Contains(s, "jsSetConfig") {
				continue
			}
			c.jsVM.RunScript(s)
		}
	}
	return cache
}

func (c *Client) epgGetPortal() {
	// http://218.83.165.40:8084/iptvepg/frame1413/portal.jsp
	p := "portal.jsp"
	uri := fmt.Sprintf("%s/%s", c.EPGHostUrl, p)
	c.httpClient.Request(uri, "GET", nil)
}
