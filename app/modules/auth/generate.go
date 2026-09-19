package auth

import (
	"bufio"
	"encoding/xml"
	"errors"
	"fmt"
	"github.com/golang-module/carbon"
	"iptv-spider-sh/global"
	"iptv-spider-sh/model"
	"iptv-spider-sh/modules/m3u"
	"iptv-spider-sh/utils"
	"net/url"
	"os"
	"path"
	"strings"
	"time"
)

const timeFormat = carbon.ShortDateTimeLayout + " -0700"

const directReferenceM3uPath = "assets/channel-reference.m3u"

const localLogoPath = "/iptvlogos/"

// 批量预载频道与分组映射（替代逐频道 N+1 查询）
func preloadChannelMaps() (map[string]model.Channel, map[string]model.M3u8Mapping) {
	var channels []model.Channel
	global.DB.Find(&channels)
	channelByMix := make(map[string]model.Channel, len(channels))
	for _, c := range channels {
		channelByMix[c.UserChannelID] = c
	}
	var mappings []model.M3u8Mapping
	global.DB.Find(&mappings)
	mappingByComm := make(map[string]model.M3u8Mapping, len(mappings))
	for _, m := range mappings {
		mappingByComm[m.CommName] = m
	}
	return channelByMix, mappingByComm
}

func GenerateM3u8(udpxy, scheme, xteve, all string) []byte {
	m3uWriter := m3u.NewWriter()
	m3uWriter.WriteHeaderWithInfo(global.CONFIG.Epg.XmlUrl)

	// 查询数据库
	var channelInfoList []model.ChannelInfo
	global.DB.Order("mix_no asc").
		Find(&channelInfoList)
	// 去重
	newChanInfo := model.RemoveDuplicateChannelInfo(channelInfoList)
	channelByMix, mappingByComm := preloadChannelMaps()
	for _, info := range newChanInfo {
		// 不展示
		if !info.IsShow {
			continue
		}
		channel := channelByMix[info.MixNo]
		m3u8Mapping := mappingByComm[info.CommName]

		if all != "true" && (m3u8Mapping.AutoGroups == "购物" ||
			m3u8Mapping.CustomGroups == "购物") {
			continue
		}
		uri := assemblyUrl(udpxy, scheme, xteve, channel.ChannelURL)
		m3uWriter.Write(uri, info, m3u8Mapping)
	}
	return m3uWriter.Bytes()
}

func GenerateDirectCatchupM3u8(udpxy, epgURL, catchupBase string, days int) []byte {
	return generateDirectCatchupM3u8(udpxy, epgURL, catchupBase, days, "utc")
}

func GenerateDirectIPTVSharpM3u8(udpxy, epgURL, catchupBase string, days int) []byte {
	return generateDirectCatchupM3u8(udpxy, epgURL, catchupBase, days, "start")
}

func generateDirectCatchupM3u8(udpxy, epgURL, catchupBase string, days int, startToken string) []byte {
	m3uWriter := m3u.NewWriter()
	m3uWriter.WriteHeaderWithInfo(epgURL)
	referenceMappings := fetchDirectReferenceMappings()
	var channelInfoList []model.ChannelInfo
	global.DB.Order("mix_no asc").Find(&channelInfoList)
	channelByMix, mappingByComm := preloadChannelMaps()
	for _, info := range model.RemoveDuplicateChannelInfo(channelInfoList) {
		if !info.IsShow {
			continue
		}
		channel := channelByMix[info.MixNo]
		mapping := mappingByComm[info.CommName]
		if reference, ok := referenceMappings[info.MixNo]; ok {
			mapping.Logo = localLogoURL(reference.Logo)
			mapping.CustomGroups = reference.Group
		}
		if mapping.AutoGroups == "购物" || mapping.CustomGroups == "购物" {
			continue
		}
		m3uWriter.WriteCatchupWithStartToken(assemblyUrl(udpxy, "", "", channel.ChannelURL), info, mapping, catchupBase, days, startToken)
	}
	return m3uWriter.Bytes()
}

type directReferenceMapping struct {
	Logo  string
	Group string
}

// The reference list is the maintained source of channel logos and manual groups.
// Fail open so the direct list remains available if the logo host is temporarily down.
func fetchDirectReferenceMappings() map[string]directReferenceMapping {
	mappings := make(map[string]directReferenceMapping)
	file, err := os.Open(directReferenceM3uPath)
	if err != nil {
		return mappings
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "#EXTINF:") {
			continue
		}
		id := directM3uAttribute(line, "tvg-id")
		if id == "" {
			continue
		}
		mappings[id] = directReferenceMapping{
			Logo:  directM3uAttribute(line, "tvg-logo"),
			Group: directM3uAttribute(line, "group-title"),
		}
	}
	return mappings
}

func localLogoURL(value string) string {
	if value == "" {
		return ""
	}
	parsed, err := url.Parse(value)
	if err == nil && parsed.Path != "" {
		value = parsed.Path
	}
	name := path.Base(value)
	if name == "." || name == "/" || name == "" {
		return ""
	}
	return localLogoBaseURL() + url.PathEscape(name)
}

func localLogoBaseURL() string {
	if global.CONFIG != nil {
		if parsed, err := url.Parse(global.CONFIG.Epg.XmlUrl); err == nil && parsed.Scheme != "" && parsed.Host != "" {
			return parsed.Scheme + "://" + parsed.Host + localLogoPath
		}
	}
	return "http://127.0.0.1:8888" + localLogoPath
}

func directM3uAttribute(line, key string) string {
	prefix := key + `="`
	start := strings.Index(line, prefix)
	if start < 0 {
		return ""
	}
	value := line[start+len(prefix):]
	end := strings.Index(value, `"`)
	if end < 0 {
		return ""
	}
	return value[:end]
}

func GenerateTimeShiftM3u8() []byte {
	m3uWriter := m3u.NewWriter()
	m3uWriter.WriteHeaderWithInfo(global.CONFIG.Epg.XmlUrl)
	// 查询数据库
	var channelInfoList []model.ChannelInfo
	global.DB.Find(&channelInfoList)
	// 去重
	newChanInfo := model.RemoveDuplicateChannelInfo(channelInfoList)
	channelByMix, mappingByComm := preloadChannelMaps()
	for _, info := range newChanInfo {
		// 不展示
		if !info.IsShow {
			continue
		}
		channel := channelByMix[info.MixNo]
		m3u8Mapping := mappingByComm[info.CommName]

		if m3u8Mapping.AutoGroups == "购物" || m3u8Mapping.CustomGroups == "购物" {
			continue
		}
		uri := assemblyUrl("", "", "", channel.TimeShiftURL)
		m3uWriter.Write(uri, info, m3u8Mapping)
	}
	return m3uWriter.Bytes()
}

func assemblyUrl(udpxy, scheme, xteve, uri string) string {
	u, _ := url.Parse(uri)
	if xteve == "true" {
		return fmt.Sprintf("udp://@%s", u.Host)
	} else if udpxy != "" {
		return fmt.Sprintf("http://%s/udp/%s", udpxy, u.Host)
	} else if scheme != "" {
		return fmt.Sprintf("%s://%s", scheme, u.Host)
	}
	return uri
}

func GenerateXmlTv(daysAgo int) ([]byte, error) {
	if daysAgo < 1 {
		daysAgo = 1
	} else if daysAgo > 7 {
		daysAgo = 7
	}
	var now = carbon.Now()
	playableBoundary := now.SubDays(daysAgo).TimestampMilli()
	var xmlTv = model.XmlTV{
		Generator: fmt.Sprintf("%s %s", global.CONFIG.Epg.Generator, now.ToDateTimeString()),
		Source:    global.CONFIG.Epg.Source,
	}
	// 取数据
	var channelInfoList []model.ChannelInfo
	global.DB.Find(&channelInfoList)
	// 去重
	newChanInfo := model.RemoveDuplicateChannelInfo(channelInfoList)
	// 一次性批量取全部频道的节目（替代逐频道 N+1 查询），按 comm_name 分组保持原输出顺序
	boundary := epgHistoryBoundary(time.Now(), daysAgo)
	pullNames := make([]string, 0, len(newChanInfo))
	for _, info := range newChanInfo {
		if info.IsShow && info.IsPullEPG {
			pullNames = append(pullNames, info.CommName)
		}
	}
	epgByComm := make(map[string][]model.EPGDetails)
	if len(pullNames) > 0 {
		var epgAll []model.EPGDetails
		global.DB.Where("comm_name IN ?", pullNames).
			Where("start_time >= ?", boundary).
			Order("comm_name asc, start_time asc").
			Find(&epgAll)
		for _, epg := range epgAll {
			epgByComm[epg.CommName] = append(epgByComm[epg.CommName], epg)
		}
	}
	for _, info := range newChanInfo {
		// 不展示
		if !info.IsShow {
			continue
		}
		chId := info.MixNo
		xmlTv.Channel = append(xmlTv.Channel, &model.XmlTvChannel{
			ID:          chId,
			DisplayName: []model.DisplayName{{Lang: "zh", Value: info.CommName}},
		})
		if !info.IsPullEPG {
			xmlTv.Program = append(xmlTv.Program, &model.Program{
				Channel: chId,
				Title:   []*model.Title{{Lang: "zh"}},
				Desc:    []*model.Desc{{Lang: "zh"}},
			})
			continue
		}

		epgData := epgByComm[info.CommName]
		for _, epg := range epgData {
			startTime := carbon.CreateFromTimestampMilli(epg.StartTime).Layout(timeFormat)
			endTime := carbon.CreateFromTimestampMilli(epg.EndTime).Layout(timeFormat)
			xmlTv.Program = append(xmlTv.Program, &model.Program{
				Channel: chId,
				Start:   startTime,
				Stop:    endTime,
				Title:   []*model.Title{{Lang: "zh", Value: epgDisplayTitle(epg.Name, epg.StartTime, playableBoundary)}},
				Desc:    []*model.Desc{{Lang: "zh"}},
			})
		}
	}
	// 序列化
	epgBytes, err := xml.MarshalIndent(&xmlTv, "", "  ")
	if err != nil {
		global.LOG.Error("节目表单生成出错: " + err.Error())
		return nil, errors.New("节目表单生成出错")
	}
	epgBytes = append([]byte(model.PrefixHeader+"\n"), epgBytes...)
	return epgBytes, nil
}

func GenerateAndUploadM3u() {
	m3uBytes := GenerateM3u8("", "", "true", "")
	utils.UploadToOSS("/sh/tel-xteve.m3u", m3uBytes)
}

func GenerateAndUploadXmlTv() {
	xmlTvBytes, _ := GenerateXmlTv(1)
	utils.UploadToOSS("/sh/tel-epg.xml", xmlTvBytes)
}

func GenerateAndUploadXmlTvDays7() {
	xmlTvBytes, _ := GenerateXmlTv(7)
	utils.UploadToOSS("/sh/tel-epg-7.xml", xmlTvBytes)
}
