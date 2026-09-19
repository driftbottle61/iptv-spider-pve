package utils

import (
	"bytes"
	"github.com/PuerkitoBio/goquery"
	"iptv-spider-sh/global"
	"net/url"
	"strings"
)

func CreateHtmlDocByBytes(uri string, resp []byte) *goquery.Document {
	doc, err := goquery.NewDocumentFromReader(bytes.NewReader(resp))
	if err != nil {
		global.LOG.Error(err.Error())
		return nil
	}
	doc.Url, _ = url.Parse(uri)
	if doc.Url == nil || doc.Url.Scheme == "" || doc.Url.Host == "" {
		return nil
	}
	return doc
}

func GetFromParamByHtml(d *goquery.Document, sec ...string) (uri, method string, formMap map[string]string) {
	if d == nil || d.Url == nil {
		return
	}
	s := "form"
	if len(sec) == 1 {
		s = sec[0]
	}
	nodes := d.Find(s)
	if len(nodes.Nodes) == 0 && s != "form" {
		nodes = d.Find("form")
	}
	if len(nodes.Nodes) == 0 {
		return
	}
	form := nodes.First()
	if len(nodes.Nodes) > 1 {
		// Prefer a form with an action and hidden authentication fields.
		nodes.EachWithBreak(func(_ int, candidate *goquery.Selection) bool {
			action := strings.TrimSpace(candidate.AttrOr("action", ""))
			hidden := candidate.Find("input[type=hidden]").Length()
			if action != "" && hidden > 0 {
				form = candidate
				return false
			}
			return true
		})
	}
	uri = form.AttrOr("action", "")
	if uri == "" {
		uri = d.Url.String()
	}
	if parsed, err := d.Url.Parse(uri); err == nil {
		uri = parsed.String()
	}
	method = form.AttrOr("method", "get")
	child := form.Children()
	formMap = map[string]string{}
	child.Each(func(_ int, s *goquery.Selection) {
		k := s.AttrOr("name", "")
		v := s.AttrOr("value", "")
		formMap[k] = v
	})
	return
}

func GetScriptsFormHtml(d *goquery.Document) []string {
	var scriptsArr []string
	scripts := d.Find("script")
	scripts.Each(func(_ int, s *goquery.Selection) {
		c := s.Nodes[0].FirstChild
		if c == nil {
			return
		}
		scriptsArr = append(scriptsArr, c.Data)
	})
	return scriptsArr
}
