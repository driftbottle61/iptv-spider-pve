package api

import (
	"crypto/subtle"
	"errors"
	"fmt"
	"github.com/kataras/iris/v12"
	"iptv-spider-sh/global"
	"iptv-spider-sh/modules/auth"
	"iptv-spider-sh/utils"
	"net"
	"strings"
	"time"
)

func InitApiRouters(rg iris.Party) {
	rg.Get("/schedule", schedule)

	rg.Get("/run", func(ctx iris.Context) {
		if !apiControlAllowed(ctx) {
			return
		}
		taskName := ctx.FormValue("task")

		go func() {
			global.ConcurrencyControl.Do("", func() (interface{}, error) {
				switch taskName {
				case "clean-ch":
					auth.CleanChannelData()
				case "clean-chi":
					auth.CleanChannelInfoData()
				case "clean-epg":
					auth.CleanEPGDetailsData()
				case "clean":
					auth.CleanChannelData()
					auth.CleanChannelInfoData()
					auth.CleanEPGDetailsData()
				case "update-chi":
					auth.GetGlobalClient().FetchChannelList()
				case "update-epg":
					auth.GetGlobalClient().FetchChannelProg()
				case "upload-m3u":
					auth.GenerateAndUploadM3u()
				case "upload-xmltv":
					auth.GenerateAndUploadXmlTv()
				case "upload-xmltv7":
					auth.GenerateAndUploadXmlTvDays7()
				}
				return nil, nil
			})
		}()
		ctx.WriteString("OK")
	})

	rg.Get("/m3u8", generateM3u8)

	rg.Get("/tsM3u8", generateTsM3u8)

	rg.Get("/epg", generateXmlTv)

	rg.Get("/catchup/m3u", GenerateCatchupM3u)

	rg.Get("/catchup/stream/{channel:string}", streamCatchup)

	rg.Get("/catchup/stream/{channel:string}/{start:string}/{duration:string}", streamCatchup)
	rg.Get("/catchup/stream/{channel:string}/{start:string}/{duration:string}.ts", streamCatchup)

}

func GenerateDirectTiviMateM3u(ctx iris.Context) {
	generateDirectClientM3u(ctx, false)
}

func GenerateDirectIPTVSharpM3u(ctx iris.Context) {
	generateDirectClientM3u(ctx, true)
}

func generateDirectClientM3u(ctx iris.Context, iptvSharp bool) {
	udpxy := ctx.URLParamDefault("udpxy", configuredUdpxy())
	days := configuredCatchupDays()
	scheme := ctx.GetHeader("X-Forwarded-Proto")
	if scheme == "" {
		scheme = "http"
	}
	base := fmt.Sprintf("%s://%s/api/catchup/stream", scheme, ctx.Request().Host)
	data := auth.GenerateDirectCatchupM3u8(udpxy, global.CONFIG.Epg.XmlUrl, base, days)
	filename := "iptv-direct-catchup.m3u"
	if iptvSharp {
		data = auth.GenerateDirectIPTVSharpM3u8(udpxy, global.CONFIG.Epg.XmlUrl, base, days)
		filename = "iptvsharp.m3u"
	}
	ctx.ContentType("audio/x-mpegurl")
	ctx.Header("Content-Disposition", "attachment; filename="+filename)
	_, _ = ctx.Write(data)
}

func schedule(ctx iris.Context) {
	type s struct {
		ID       int
		PreTime  time.Time
		NextTime time.Time
	}
	var schedule []s
	for _, entry := range global.CRON.Entries() {
		schedule = append(schedule, s{
			ID:       int(entry.ID),
			PreTime:  entry.Prev,
			NextTime: entry.Next,
		})
	}
	ctx.JSON(schedule)
}

// 生成m3u8文件 节目去重
func generateM3u8(ctx iris.Context) {
	// 获取query参数
	udpxy := ctx.FormValue("udpxy")
	scheme := ctx.FormValue("scheme")
	xteve := ctx.FormValue("xteve")
	all := ctx.FormValue("all")
	ref := ctx.FormValue("ref")

	var bufStr string
	if xteve == "true" {
		bufStr = "xteve"
	} else if udpxy != "" {
		bufStr = udpxy
	} else if scheme != "" {
		bufStr = scheme
	}
	if all == "true" {
		bufStr += all
	}
	reqMD5Key := utils.CalcMD5KeyForRequest("generateM3u8", bufStr)
	// 缓存机制
	if ref != "true" && global.CACHE.IsExist(reqMD5Key) {
		ctx.Header("Content-Disposition", "attachment; filename=iptv.m3u")
		ctx.Binary(global.CACHE.Get(reqMD5Key).([]byte))
		return
	}
	// 并发时合并请求
	resp, _, _ := global.ConcurrencyControl.Do(reqMD5Key, func() (interface{}, error) {
		respBytes := auth.GenerateM3u8(udpxy, scheme, xteve, all)
		timeOut := time.Duration(global.CONFIG.Cache.DefTimeOut)
		global.CACHE.Put(reqMD5Key, respBytes, time.Minute*timeOut)
		return respBytes, nil
	})
	ctx.Header("Content-Disposition", "attachment; filename=iptv.m3u")
	ctx.Binary(resp.([]byte))
}

func generateTsM3u8(ctx iris.Context) {
	ref := ctx.FormValue("ref")
	reqMD5Key := utils.CalcMD5KeyForRequest("generateTsM3u8")
	// 缓存机制
	if ref != "true" && global.CACHE.IsExist(reqMD5Key) {
		ctx.Header("Content-Disposition", "attachment; filename=iptv-ts.m3u")
		ctx.Binary(global.CACHE.Get(reqMD5Key).([]byte))
		return
	}
	// 并发时合并请求
	resp, _, _ := global.ConcurrencyControl.Do(reqMD5Key, func() (interface{}, error) {
		respBytes := auth.GenerateTimeShiftM3u8()
		timeOut := time.Duration(global.CONFIG.Cache.DefTimeOut)
		global.CACHE.Put(reqMD5Key, respBytes, time.Minute*timeOut)
		return respBytes, nil
	})
	ctx.Header("Content-Disposition", "attachment; filename=iptv-ts.m3u")
	ctx.Binary(resp.([]byte))
}

// apiControlAllowed 管理接口访问控制：配置了 system.api-token 后 /api/run 一律要求
// 携带匹配的 ?token=；未配置时仅放行内网/回环客户端（管理接口不应暴露公网）。
func apiControlAllowed(ctx iris.Context) bool {
	token := ""
	if global.CONFIG != nil {
		token = global.CONFIG.System.ApiToken
	}
	if token != "" {
		if subtle.ConstantTimeCompare([]byte(ctx.FormValue("token")), []byte(token)) == 1 {
			return true
		}
		stopRequest(ctx, iris.StatusUnauthorized, errors.New("invalid or missing API token"))
		return false
	}
	remote := ctx.RemoteAddr()
	if host, _, err := net.SplitHostPort(remote); err == nil {
		remote = host
	}
	if ip := net.ParseIP(strings.Trim(remote, "[]")); ip != nil && (ip.IsPrivate() || ip.IsLoopback()) {
		return true
	}
	stopRequest(ctx, iris.StatusForbidden, errors.New("management API only available on private network"))
	return false
}
