package m3u

import (
	"fmt"
	"go.uber.org/zap/buffer"
	"iptv-spider-sh/model"
)

type Writer struct {
	buf buffer.Buffer
}

func (m *Writer) WriteHeaderWithInfo(xmlUrl string) {
	// http://10.0.0.10:34400/xmltv/xteve.xml
	if xmlUrl == "" {
		m.WriteHeader()
		return
	}
	m.buf.WriteString(fmt.Sprintf(`#EXTM3U url-tvg="%s" x-tvg-url="%s"`, xmlUrl, xmlUrl))
	m.buf.WriteString("\n")
}

func (m *Writer) WriteHeader() {
	m.buf.WriteString("#EXTM3U \n")
}

func (m *Writer) Write(uri string, info model.ChannelInfo, ext model.M3u8Mapping) {
	var groups = ext.CustomGroups
	if groups == "" {
		groups = ext.AutoGroups
	}
	m.buf.WriteString("\n")
	m.buf.WriteString(fmt.Sprintf(`#EXTINF:-1 tvg-id="%s" tvg-name="%s" tvg-logo="%s"`, info.MixNo, info.CommName, ext.Logo))
	m.buf.WriteString(fmt.Sprintf(` group-title="%s"`, groups))
	m.buf.WriteString(fmt.Sprintf(",%s\n%s", info.Name, uri))
}

func (m *Writer) WriteCatchup(uri string, info model.ChannelInfo, ext model.M3u8Mapping, source string, days int) {
	m.WriteCatchupWithStartToken(uri, info, ext, source, days, "utc")
}

func (m *Writer) WriteCatchupWithStartToken(uri string, info model.ChannelInfo, ext model.M3u8Mapping, source string, days int, startToken string) {
	var groups = ext.CustomGroups
	if groups == "" {
		groups = ext.AutoGroups
	}
	if days < 1 {
		days = 1
	}
	m.buf.WriteString("\n")
	m.buf.WriteString(fmt.Sprintf(`#EXTINF:-1 tvg-id="%s" tvg-name="%s" tvg-logo="%s"`, info.MixNo, info.CommName, ext.Logo))
	m.buf.WriteString(fmt.Sprintf(` group-title="%s" catchup="default" catchup-days="%d" catchup-source="%s/%s/{%s}/{duration}.ts"`, groups, days, source, info.MixNo, startToken))
	m.buf.WriteString(fmt.Sprintf(",%s\n%s", info.Name, uri))
}

func (m *Writer) Bytes() []byte {
	return m.buf.Bytes()
}

func (m *Writer) Strings() string {
	return m.buf.String()
}

func NewWriter() *Writer {
	m := Writer{}
	return &m
}
