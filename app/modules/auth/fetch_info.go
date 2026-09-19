package auth

import (
	"encoding/json"
	"fmt"
	"github.com/golang-module/carbon"
	"go.uber.org/zap"
	"gorm.io/gorm/clause"
	"iptv-spider-sh/global"
	"iptv-spider-sh/model"
	"iptv-spider-sh/modules/http_client"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

var epgFallbackHosts = []string{"218.83.188.231:8084"}

var (
	channelListFetchMu sync.Mutex
	channelProgFetchMu sync.Mutex
)

func (c *Client) checkSessionState() error {
	now := carbon.Now()
	if c.AuthInfo.UpdatedAt.Unix() > now.SubHours(1).Timestamp() {
		global.LOG.Info("AuthInfo 更新时间在60分钟以内, 跳过检测")
		return nil
	}
	global.LOG.Info("Check session state")
	p := "service/auth/AuthByAjax.jsp?action=auth"
	uri := fmt.Sprintf("%s/%s", c.EPGHostUrl, p)
	resp := c.requestEPG(uri, "GET", nil)
	if resp.GetResp() == nil || resp.GetResp().StatusCode() == 0 {
		return fmt.Errorf("EPG host unavailable: %s", c.EPGHostUrl)
	}
	cont := resp.GetResp().Header().Get("Content-Type")
	if !strings.Contains(cont, "json") {
		global.LOG.Info("Session expired, reAuth")
		// 过期了, 重新认证
		err := c.StartAuth()
		return err
	}
	// 有效期内, 更新 UpdatedAt 为当前时间
	c.AuthInfo.UpdatedAt = now.ToStdTime()
	c.AuthInfo.BimAuthInfo = string(resp.GetRespBytes())
	// 保存到数据库
	global.DB.Updates(&c.AuthInfo)
	global.LOG.Info("Session OK")
	return nil
}

func (c *Client) requestEPG(uri, method string, form map[string]string) *http_client.HttpClient {
	resp := c.httpClient.Request(uri, method, form)
	if resp.GetResp() != nil && resp.GetResp().StatusCode() > 0 &&
		(strings.EqualFold(method, "GET") || strings.Contains(resp.GetResp().Header().Get("Content-Type"), "json")) {
		return resp
	}
	if resp.GetResp() != nil && resp.GetResp().StatusCode() > 0 && strings.EqualFold(method, "POST") {
		if err := c.StartAuth(); err == nil {
			return c.httpClient.Request(uriForCurrentEPG(c.EPGHostUrl, uri), method, form)
		}
	}
	if !c.tryEPGFallback() {
		return resp
	}
	u, err := url.Parse(uri)
	if err != nil {
		return resp
	}
	base, err := url.Parse(c.EPGHostUrl)
	if err != nil {
		return resp
	}
	u.Host = base.Host
	if strings.EqualFold(method, "POST") && c.StartAuth() == nil {
		return c.httpClient.Request(uriForCurrentEPG(c.EPGHostUrl, uri), method, form)
	}
	return c.httpClient.Request(u.String(), method, form)
}

func uriForCurrentEPG(base, original string) string {
	u, err := url.Parse(original)
	if err != nil {
		return original
	}
	b, err := url.Parse(base)
	if err != nil {
		return original
	}
	u.Host = b.Host
	return u.String()
}

// Try known EPG nodes before forcing a full STB re-authentication. The load
// balancer can leave a dead node in AuthInfo even while another node works.
func (c *Client) tryEPGFallback() bool {
	old := c.EPGHostUrl
	for _, host := range epgFallbackHosts {
		if strings.Contains(old, host) {
			continue
		}
		candidate := old
		if u, err := url.Parse(old); err == nil {
			u.Host = host
			candidate = u.String()
		}
		c.EPGHostUrl = candidate
		c.updateCookies()
		probe := c.httpClient.Request(candidate+"/service/auth/AuthByAjax.jsp?action=auth", "GET", nil)
		if probe.GetResp() != nil && probe.GetResp().StatusCode() > 0 &&
			strings.Contains(probe.GetResp().Header().Get("Content-Type"), "json") {
			global.LOG.Warn("切换到备用 EPG 节点", zap.String("host", host))
			return true
		}
	}
	c.EPGHostUrl = old
	return false
}

func (c *Client) FetchChannelList() {
	channelListFetchMu.Lock()
	defer channelListFetchMu.Unlock()

	err := c.checkSessionState()
	if err != nil {
		global.LOG.Error("FetchChannelList checkSessionState Err: " + err.Error())
		global.LOG.Error("跳过此次更新")
		return
	}
	global.LOG.Info("开始更新频道信息列表")
	p := "function/ajax/epg7getChannelByAjax.jsp"
	uri := fmt.Sprintf("%s/%s", c.EPGHostUrl, p)
	resp := c.requestEPG(uri, "POST", map[string]string{
		"action": "getChannelList",
		"cateID": "000406",
	})
	var respJson model.JsonResponse[model.ChannelInfo]
	err = json.Unmarshal(resp.GetRespBytes(), &respJson)
	if err != nil {
		global.LOG.Error("FetchChannelList Unmarshal Err: " + err.Error())
		return
	}
	if respJson.Data == nil || len(respJson.Data) == 0 {
		global.LOG.Error("FetchChannelList Err: No Data!")
		return
	}
	global.LOG.Info(fmt.Sprintf("FetchChannelList Data Length: %d", len(respJson.Data)))
	filtered := respJson.Data[:0]
	for _, chanInfo := range respJson.Data {
		channelName := strings.TrimSpace(strings.TrimSuffix(strings.ToUpper(chanInfo.Name), "HD"))
		if model.IsHiddenChannelName(chanInfo.Name) {
			global.LOG.Info("跳过需隐藏的频道", zap.String("ChannelName", chanInfo.Name))
			continue
		}
		if channelName == "体育频道" {
			global.LOG.Info("跳过重复体育频道，保留五星体育HD")
			continue
		}
		filtered = append(filtered, chanInfo)
	}
	respJson.Data = filtered
	for _, chanInfo := range respJson.Data {
		global.LOG.Info("FetchChannelList Data:",
			zap.Any("Channel Info", chanInfo))
	}
	/*
		TsTime        int       `gorm:"comment:TimeShiftTime 时移时间" json:"tsTime"`
		Code          string    `gorm:"uniqueIndex;comment:频道代码" json:"code"`
		AuthCode      string    `gorm:"comment:付费认证代码" json:"authCode"`
		Name          string    `gorm:"comment:频道名称" json:"name"`
		ChID          string    `gorm:"uniqueIndex;comment:频道ID" json:"ID"`
		MixNo         string    `gorm:"comment:用户频道映射" json:"mixNo"`
		MediaID       string    `gorm:"comment:未知" json:"mediaID"`
		IsTs          string    `gorm:"comment:是否支持回放" json:"isTs"`
		IsCharge      string    `gorm:"comment:是否需要付费" json:"isCharge"`
		IsHD          bool      `gorm:"default:false;comment:是否是高清频道" json:"-"`
		Is4K          bool      `gorm:"default:false;comment:是否是4K频道" json:"-"`
		IsPullEPG     bool      `gorm:"default:true;comment:是否拉取节目单" json:"-"`
		IsShow        bool      `gorm:"default:true;comment:是否展示该节目" json:"-"`
		CommName      string    `gorm:"comment:通用标题" json:"-"`
		LastFetchTime time.Time `gorm:"comment:节目单最后更新时间" json:"-"`
	*/
	// 数据入库
	mixNos := make([]string, 0, len(respJson.Data))
	for _, ci := range respJson.Data {
		mixNos = append(mixNos, ci.MixNo)
	}
	global.DB.Clauses(clause.OnConflict{
		Columns: []clause.Column{{Name: "mix_no"}},
		DoUpdates: clause.AssignmentColumns([]string{
			"code",
			"auth_code",
			"name",
			"ch_id",
			"is_charge",
			"is_hd",
			"is4_k",
			"comm_name",
		}),
	}).Create(&respJson.Data)
	// 频道重新出现在列表里时，把此前因 >48h 未更新被软删的行恢复（upsert 不会自动清 deleted_at）
	if len(mixNos) > 0 {
		global.DB.Unscoped().Model(&model.ChannelInfo{}).
			Where("mix_no IN ?", mixNos).
			Update("deleted_at", nil)
	}
	global.LOG.Info("频道信息列表更新完成")
}

func (c *Client) FetchChannelProg() {
	channelProgFetchMu.Lock()
	defer channelProgFetchMu.Unlock()

	err := c.checkSessionState()
	if err != nil {
		global.LOG.Error("FetchChannelProg checkSessionState Err: " + err.Error())
		global.LOG.Error("跳过此次更新")
		return
	}
	global.LOG.Info("开始更新节目信息列表; 如果后续没有任何输出, 可能是近期更新过")

	p := "function/ajax/epg7getChannelByAjax.jsp"
	uri := fmt.Sprintf("%s/%s", c.EPGHostUrl, p)

	var channelInfoList []model.ChannelInfo
	// 数据库取数据
	global.DB.Group("comm_name").Find(&channelInfoList)
	now := carbon.Now()
	for _, ch := range channelInfoList {
		// 4 个小时之内更新过，跳过此次更新
		lft := carbon.FromStdTime(ch.LastFetchTime)
		if lft.Gt(now.SubHours(4)) || !ch.IsPullEPG || !ch.IsShow || ch.IsHidden() {
			continue
		}
		endTime := now.AddDays(3).TimestampMilli()
		startTime := epgHistoryBoundary(time.Now(), 7)
		params := map[string]string{
			"action":    "getChannelProg",
			"code":      ch.Code,
			"channelID": ch.ChID,
			"endTime":   strconv.FormatInt(endTime, 10),
			"startTime": strconv.FormatInt(startTime, 10),
			"offset":    "0",
			"limit":     "2000",
		}
		resp := c.requestEPG(uri, "POST", params)
		var respJson model.JsonResponse[model.EPGDetails]
		err := json.Unmarshal(resp.GetRespBytes(), &respJson)
		if err != nil {
			// 单频道数据异常（会话失效返回 HTML、上游偶发坏包等）只跳过该频道，
			// 不要中断整轮，否则后续频道全部漏更（2026-09-08 08:00 cron 整轮失败即此 bug）
			global.LOG.Error("FetchChannelProg Unmarshal Err: "+err.Error(),
				zap.Any("Params", params),
				zap.Any("resp", respJson))
			time.Sleep(time.Millisecond * 500)
			continue
		}
		if respJson.Data == nil || len(respJson.Data) == 0 {
			global.LOG.Warn("FetchChannelProg Err: No Data!",
				zap.Any("Params", params),
				zap.Any("resp", respJson))
			continue
		}
		daysAgo := epgHistoryBoundary(time.Now(), 7)
		// Keep completed programmes until the catch-up window expires. Providers
		// sometimes revise historical schedules after clients have cached the EPG;
		// deleting those rows also deletes the playbill ID needed by old catch-up
		// links. Only current/future rows are replaced by the fresh schedule.
		global.DB.Unscoped().Where("comm_name = ? AND end_time > ?", ch.CommName, now.TimestampMilli()).Delete(&model.EPGDetails{})
		global.DB.Unscoped().Where("end_time < ?", daysAgo).Delete(&model.EPGDetails{})
		length := 0
		var des []model.EPGDetails
		for _, details := range respJson.Data {
			if details.StartTime < daysAgo {
				continue
			}
			details.CommName = ch.CommName
			length++
			des = append(des, details)
		}
		global.DB.Clauses(clause.OnConflict{
			Columns:   []clause.Column{{Name: "id"}},
			UpdateAll: true,
		}).Create(&des)
		global.LOG.Info("GetChannelProg: ",
			zap.Any("CommName", ch.CommName),
			zap.Any("Data Length", length))
		global.DB.Model(&model.ChannelInfo{}).
			Where("comm_name = ?", ch.CommName).
			Updates(model.ChannelInfo{LastFetchTime: time.Now()})
		time.Sleep(time.Millisecond * 500)
	}
	global.LOG.Info("更新节目信息列表完成")
}
