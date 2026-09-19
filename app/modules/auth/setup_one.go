package auth

import (
	"fmt"
	"github.com/PuerkitoBio/goquery"
	"github.com/robertkrimen/otto"
	"iptv-spider-sh/global"
	"iptv-spider-sh/model"
	"iptv-spider-sh/utils"
)

func (c *Client) pre4kLogAuth() *goquery.Document {
	u := fmt.Sprintf("http://%s/iptv3a/4kLogAuth.do", c.pre4kLogAuthAddr)
	resp := c.httpClient.Request(u, "get", map[string]string{
		"Action":     "Login",
		"UserID":     c.userID,
		"SN":         c.sn,
		"Type":       "iptv4k",
		"Mode":       "MENU.SMG-4K",
		"FCCSupport": "1",
	})
	return utils.CreateHtmlDocByBytes(u, resp.GetRespBytes())
}

func (c *Client) r4kLogAuth(doc *goquery.Document) *goquery.Document {
	if doc == nil || doc.Url == nil {
		global.LOG.Error("R4K认证页面为空")
		return nil
	}
	uri, method, formMap := utils.GetFromParamByHtml(doc)
	if formMap == nil || uri == "" {
		global.LOG.Error("认证页面缺少唯一的 form 表单")
		return nil
	}
	resp := c.httpClient.Request(uri, method, formMap)
	respDoc := utils.CreateHtmlDocByBytes(uri, resp.GetRespBytes())
	c.R4kLoginHost = respDoc.Url.Host
	return respDoc
}

func (c *Client) ottAuth(doc *goquery.Document) *goquery.Document {
	if doc == nil || doc.Url == nil {
		global.LOG.Error("认证服务器未返回有效页面")
		return nil
	}
	c.jsVM.RunScriptForHtml(doc)
	encryptToken := c.jsVM.GetString("encrytoken")
	AuthModel := model.NewAuthenticator(encryptToken, c.userID, c.sn, c.ip, c.macAddr)

	uri, method, formMap := utils.GetFromParamByHtml(doc)
	if formMap == nil || uri == "" {
		global.LOG.Error("认证页面缺少唯一的 form 表单")
		return nil
	}
	formMap["authenticator"] = AuthModel.GetEncryptString()
	resp := c.httpClient.Request(uri, method, formMap)
	return utils.CreateHtmlDocByBytes(uri, resp.GetRespBytes())
}

func (c *Client) processChannel(doc *goquery.Document) []model.Channel {
	var channels []model.Channel
	c.jsVM.Reset()
	c.jsVM.RunScriptForHtml(doc)

	c.jsVM.Set("AddChannel", func(call otto.FunctionCall) otto.Value {
		channelStr := call.Argument(0).String()
		channels = append(channels, GetChannelFormString(channelStr))
		return otto.Value{}
	})
	c.jsVM.RunScript(`
		for (var i = 0; i < channelArray.length; i++) {
			AddChannel(channelArray[i]);
		}
	`)
	return channels
}
