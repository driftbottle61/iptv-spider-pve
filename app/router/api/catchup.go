package api

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/kataras/iris/v12"
	"iptv-spider-sh/global"
	"iptv-spider-sh/model"
	"iptv-spider-sh/modules/auth"
)

const (
	catchupMaxDays        = 7
	catchupMaxDuration    = 8 * time.Hour
	catchupMinTail        = 12 * time.Second
	catchupSegmentRetries = 3
	catchupRetryDelay     = 250 * time.Millisecond
	catchupUserAgent      = "IPTVSpiderCatchup/1.0"
)

var tvgIDPattern = regexp.MustCompile(`tvg-id="([^"]+)"`)
var tvgNamePattern = regexp.MustCompile(`tvg-name="([^"]+)"`)
var tvgLogoPattern = regexp.MustCompile(`tvg-logo="[^"]*"`)
var groupTitlePattern = regexp.MustCompile(`group-title="[^"]*"`)

type referenceMapping struct {
	logo  string
	group string
}

func loadReferenceMappings() map[string]referenceMapping {
	mappings := make(map[string]referenceMapping)
	data, err := os.ReadFile("assets/channel-reference.m3u")
	if err != nil {
		return mappings
	}
	for _, line := range strings.Split(strings.ReplaceAll(string(data), "\r\n", "\n"), "\n") {
		if !strings.HasPrefix(line, "#EXTINF:") {
			continue
		}
		id := tvgIDPattern.FindStringSubmatch(line)
		logo := tvgLogoPattern.FindStringSubmatch(line)
		group := groupTitlePattern.FindStringSubmatch(line)
		comma := strings.LastIndex(line, ",")
		name := ""
		if comma >= 0 {
			name = normalizeChannelName(line[comma+1:])
		}
		if len(id) == 2 && len(logo) == 1 && len(group) == 1 {
			logoValue := strings.TrimSuffix(strings.TrimPrefix(logo[0], `tvg-logo="`), `"`)
			if parsed, err := url.Parse(logoValue); err == nil && parsed.Path != "" {
				logoValue = parsed.Path
			}
			if slash := strings.LastIndex(logoValue, "/"); slash >= 0 {
				logoValue = logoValue[slash+1:]
			}
			groupValue := strings.TrimSuffix(strings.TrimPrefix(group[0], `group-title="`), `"`)
			mapping := referenceMapping{
				logo:  logoValue,
				group: groupValue,
			}
			mappings["id:"+id[1]] = mapping
			if name != "" {
				mappings["name:"+name] = mapping
			}
		}
	}
	return mappings
}

func applyReferenceMapping(line string, mappings map[string]referenceMapping, logoBase string) string {
	id := tvgIDPattern.FindStringSubmatch(line)
	if len(id) != 2 {
		return line
	}
	mapping, ok := mappings["id:"+id[1]]
	if !ok {
		if name := tvgNamePattern.FindStringSubmatch(line); len(name) == 2 {
			mapping, ok = mappings["name:"+normalizeChannelName(name[1])]
		}
	}
	if !ok {
		if comma := strings.LastIndex(line, ","); comma >= 0 {
			mapping, ok = mappings["name:"+normalizeChannelName(line[comma+1:])]
		}
	}
	if !ok {
		return line
	}
	logoURL := ""
	if mapping.logo != "" {
		logoURL = logoBase + url.PathEscape(mapping.logo)
	}
	if tvgLogoPattern.MatchString(line) {
		line = tvgLogoPattern.ReplaceAllString(line, `tvg-logo="`+logoURL+`"`)
	} else if logoURL != "" {
		// #EXTINF 行缺 tvg-logo 时在频道名逗号前插入属性（旧实现 Replace 相同串=no-op）
		if comma := strings.LastIndex(line, ","); comma >= 0 {
			line = line[:comma] + ` tvg-logo="` + logoURL + `"` + line[comma:]
		}
	}
	if groupTitlePattern.MatchString(line) {
		line = groupTitlePattern.ReplaceAllString(line, `group-title="`+mapping.group+`"`)
	}
	return line
}

func logoBaseURL(ctx iris.Context) string {
	scheme := ctx.GetHeader("X-Forwarded-Proto")
	if scheme == "" {
		scheme = "http"
	}
	host := ctx.GetHeader("X-Forwarded-Host")
	if host == "" {
		host = ctx.Request().Host
	}
	if host == "" || strings.HasPrefix(host, "127.0.0.1") || host == "::1" || strings.HasPrefix(host, "[::1]") {
		if parsed, err := url.Parse(global.CONFIG.Epg.XmlUrl); err == nil && parsed.Scheme != "" && parsed.Host != "" {
			return parsed.Scheme + "://" + parsed.Host + "/iptvlogos/"
		}
		host = "127.0.0.1:8888"
	}
	return scheme + "://" + host + "/iptvlogos/"
}

type tvodPlaySource struct {
	playlistURL string
	cookie      *http.Cookie
	referer     string
}

// Keep redirects visible: the provider uses a 302 to signal an expired IPTV
// session, and following it would turn this POST into an unrelated GET.
func iptvHTTPClient(timeout time.Duration, checkRedirect func(*http.Request, []*http.Request) error) *http.Client {
	dialer := &net.Dialer{Timeout: 8 * time.Second}
	if ip := currentIPTVSourceIP(); ip != nil {
		dialer.LocalAddr = &net.TCPAddr{IP: ip}
	}
	return &http.Client{
		Timeout: timeout,
		Transport: &http.Transport{
			DialContext:           dialer.DialContext,
			ResponseHeaderTimeout: 8 * time.Second,
		},
		CheckRedirect: checkRedirect,
	}
}

func currentIPTVSourceIP() net.IP {
	interfaceName := os.Getenv("IPTV_INTERFACE")
	if interfaceName == "" {
		interfaceName = "eth1"
	}
	if networkInterface, err := net.InterfaceByName(interfaceName); err == nil {
		if addresses, err := networkInterface.Addrs(); err == nil {
			for _, address := range addresses {
				var ip net.IP
				switch value := address.(type) {
				case *net.IPNet:
					ip = value.IP
				case *net.IPAddr:
					ip = value.IP
				}
				if ip != nil && ip.To4() != nil && !ip.IsLoopback() {
					return ip.To4()
				}
			}
		}
	}
	if global.CONFIG != nil {
		if ip := net.ParseIP(global.CONFIG.Stb.IP); ip != nil {
			return ip.To4()
		}
	}
	return nil
}

var tvodHTTPClient = iptvHTTPClient(15*time.Second, func(_ *http.Request, _ []*http.Request) error {
	return http.ErrUseLastResponse
})

var tvodAuthMu sync.Mutex

type tvodError struct {
	status int
	msg    string
}

func (e *tvodError) Error() string { return e.msg }

type hlsRelayError struct {
	status int
	err    error
}

func (e *hlsRelayError) Error() string { return e.err.Error() }
func (e *hlsRelayError) Unwrap() error { return e.err }

func GenerateCatchupM3u(ctx iris.Context) {
	generateCatchupM3uWithDefaults(ctx, configuredCatchupSource(), configuredCatchupDays())
}

func generateCatchupM3uWithDefaults(ctx iris.Context, defaultSource string, defaultDays int) {
	playlist, err := loadSourcePlaylist(ctx, defaultSource)
	if err != nil {
		stopRequest(ctx, iris.StatusBadGateway, err)
		return
	}

	var channelInfos []model.ChannelInfo
	if err := global.DB.Find(&channelInfos).Error; err != nil {
		stopRequest(ctx, iris.StatusInternalServerError, err)
		return
	}
	var channels []model.Channel
	if err := global.DB.Find(&channels).Error; err != nil {
		stopRequest(ctx, iris.StatusInternalServerError, err)
		return
	}
	channelByMix := make(map[string]model.Channel, len(channels))
	for _, channel := range channels {
		if channel.TimeShift == "1" && channel.TimeShiftURL != "" {
			channelByMix[channel.UserChannelID] = channel
		}
	}
	enabled := make(map[string]bool)
	channelsByName := make(map[string]string)
	for _, info := range model.RemoveDuplicateChannelInfo(channelInfos) {
		if !info.IsShow {
			continue
		}
		if _, ok := channelByMix[info.MixNo]; !ok {
			continue
		}
		enabled[info.MixNo] = true
		channelsByName[normalizeChannelName(info.Name)] = info.MixNo
		channelsByName[normalizeChannelName(info.CommName)] = info.MixNo
	}

	days := defaultDays
	if value, err := strconv.Atoi(ctx.URLParamDefault("days", strconv.Itoa(defaultDays))); err == nil && value >= 1 && value <= catchupMaxDays {
		days = value
	}
	scheme := ctx.GetHeader("X-Forwarded-Proto")
	if scheme == "" {
		scheme = "http"
	}
	host := ctx.GetHeader("X-Forwarded-Host")
	if host == "" {
		host = ctx.Request().Host
	}
	if host == "" || strings.HasPrefix(host, "127.0.0.1:") || host == "127.0.0.1" || strings.HasPrefix(host, "[::1]:") || host == "::1" {
		host = "192.168.100.90:8888"
	}
	baseURL := fmt.Sprintf("%s://%s/api/catchup/stream", scheme, host)
	result := injectCatchupAttributes(string(playlist), enabled, channelsByName, baseURL, logoBaseURL(ctx), days)

	ctx.Header("Content-Disposition", "attachment; filename=iptv-catchup.m3u")
	ctx.ContentType("audio/x-mpegurl")
	_, _ = ctx.WriteString(result)
}

func loadSourcePlaylist(ctx iris.Context, defaultSource string) ([]byte, error) {
	source := strings.TrimSpace(ctx.URLParam("source"))
	if source == "" {
		source = defaultSource
	}
	if source == "" {
		return auth.GenerateM3u8("", "", "true", ""), nil
	}
	parsed, err := url.Parse(source)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		return nil, errors.New("source must be an HTTP or HTTPS URL")
	}
	request, err := http.NewRequestWithContext(ctx.Request().Context(), http.MethodGet, source, nil)
	if err != nil {
		return nil, err
	}
	client := &http.Client{Timeout: 20 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		return nil, fmt.Errorf("load source playlist: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("source playlist returned %s", response.Status)
	}
	return io.ReadAll(io.LimitReader(response.Body, 16<<20))
}

func injectCatchupAttributes(playlist string, enabled map[string]bool, channelsByName map[string]string, baseURL, logoBase string, days int) string {
	lines := strings.Split(strings.ReplaceAll(playlist, "\r\n", "\n"), "\n")
	referenceMappings := loadReferenceMappings()
	for index, line := range lines {
		if !strings.HasPrefix(line, "#EXTINF:") {
			continue
		}
		line = applyReferenceMapping(line, referenceMappings, logoBase)
		if strings.Contains(line, "catchup=") {
			lines[index] = line
			continue
		}
		channelID := ""
		if match := tvgIDPattern.FindStringSubmatch(line); len(match) == 2 && enabled[match[1]] {
			channelID = match[1]
		}
		if channelID == "" {
			if match := tvgNamePattern.FindStringSubmatch(line); len(match) == 2 {
				channelID = channelsByName[normalizeChannelName(match[1])]
			}
		}
		if channelID == "" {
			comma := strings.LastIndex(line, ",")
			if comma >= 0 {
				channelID = channelsByName[normalizeChannelName(line[comma+1:])]
			}
		}
		if channelID == "" {
			continue
		}
		comma := strings.LastIndex(line, ",")
		if comma < 0 {
			continue
		}
		streamURL := fmt.Sprintf("%s/%s/{utc}/{duration}.ts", baseURL, url.PathEscape(channelID))
		attributes := fmt.Sprintf(` catchup="default" catchup-days="%d" catchup-source="%s"`, days, streamURL)
		lines[index] = line[:comma] + attributes + line[comma:]
	}
	return strings.Join(lines, "\n")
}

func normalizeChannelName(name string) string {
	name = strings.ToUpper(strings.TrimSpace(name))
	name = strings.ReplaceAll(name, "(高清)", "")
	name = strings.ReplaceAll(name, "（高清）", "")
	name = strings.TrimSpace(name)
	if strings.HasSuffix(name, "HD") {
		name = strings.TrimSpace(strings.TrimSuffix(name, "HD"))
	}
	if strings.HasSuffix(name, "4K") {
		name = strings.TrimSpace(strings.TrimSuffix(name, "4K"))
	}
	return strings.ReplaceAll(name, " ", "")
}

func streamCatchup(ctx iris.Context) {
	channelID := ctx.Params().Get("channel")
	start, duration, err := parseCatchupRange(ctx)
	if err != nil {
		stopRequest(ctx, iris.StatusBadRequest, err)
		return
	}
	global.LOG.Info(fmt.Sprintf("catchup request channel=%s start=%s duration=%s remote=%s", channelID, start.Format(time.RFC3339), duration, ctx.RemoteAddr()))

	playSource, err := getTvodPlayURL(ctx.Request().Context(), channelID, start, duration)
	if err != nil {
		global.LOG.Warn(fmt.Sprintf("catchup upstream failed channel=%s error=%s", channelID, err.Error()))
		status := iris.StatusBadGateway
		message := "upstream TVOD service unavailable"
		var te *tvodError
		if errors.As(err, &te) {
			status = te.status
			message = te.msg
		}
		stopRequest(ctx, status, errors.New(message))
		return
	}
	// All private/LAN clients use the .90 server as the catch-up relay. This keeps
	// IPTV-network CDN access on the server side and avoids relying on each TV or
	// set-top-box client to route the provider's public CDN correctly. Public
	// clients retain the redirect path unless CATCHUP_MODE=relay is set.
	remoteHost := ctx.RemoteAddr()
	if host, _, err := net.SplitHostPort(remoteHost); err == nil {
		remoteHost = host
	}
	clientIP := net.ParseIP(strings.Trim(remoteHost, "[]"))
	useRelay := strings.EqualFold(os.Getenv("CATCHUP_MODE"), "relay") || isPrivateClient(clientIP)
	if useRelay {
		ctx.ContentType("video/mp2t")
		ctx.Header("Cache-Control", "no-store")
		ctx.Header("X-Accel-Buffering", "no")
		// 总时长兜底：回看窗口最长 8h，加 30 分钟余量后强制结束，防上游不返回 ENDLIST 时无限中继
		relayCtx, relayCancel := context.WithTimeout(ctx.Request().Context(), catchupMaxDuration+30*time.Minute)
		defer relayCancel()
		for attempt := 0; attempt < 3; attempt++ {
			written, relayErr := relayHLSWithSource(relayCtx, playSource, ctx.ResponseWriter())
			if relayErr == nil || ctx.Request().Context().Err() != nil {
				return
			}
			if written > 0 || !retryableRelayError(relayErr) || attempt == 2 {
				global.LOG.Warn(fmt.Sprintf("catchup relay stopped channel=%s remote=%s bytes=%d error=%s", channelID, ctx.RemoteAddr(), written, relayErr.Error()))
				return
			}
			global.LOG.Warn(fmt.Sprintf("catchup relay retry channel=%s attempt=%d error=%s", channelID, attempt+1, relayErr.Error()))
			playSource, err = getTvodPlayURL(ctx.Request().Context(), channelID, start, duration)
			if err != nil {
				global.LOG.Warn(fmt.Sprintf("catchup relay refresh failed channel=%s error=%s", channelID, err.Error()))
				return
			}
		}
		return
	}
	ctx.Header("Cache-Control", "no-store")
	ctx.Redirect(playSource.playlistURL, iris.StatusFound)
}

func isPrivateClient(ip net.IP) bool {
	if ip == nil {
		return false
	}
	if ip.IsPrivate() || ip.IsLoopback() {
		return true
	}
	// relay_clients 白名单：可配置为 IP 或 CIDR，命中即按内网客户端走服务端中继
	if global.CONFIG != nil {
		for _, entry := range global.CONFIG.Catchup.RelayClients {
			entry = strings.TrimSpace(entry)
			if entry == "" {
				continue
			}
			if parsed := net.ParseIP(entry); parsed != nil && parsed.Equal(ip) {
				return true
			}
			if _, network, err := net.ParseCIDR(entry); err == nil && network.Contains(ip) {
				return true
			}
		}
	}
	return false
}

// 回看/直连列表默认参数：优先取 config.yaml 的 catchup 段，缺省沿用原有硬编码
func configuredCatchupSource() string {
	if global.CONFIG != nil && strings.TrimSpace(global.CONFIG.Catchup.SourceM3u) != "" {
		return strings.TrimSpace(global.CONFIG.Catchup.SourceM3u)
	}
	return ""
}

func configuredUdpxy() string {
	if global.CONFIG != nil && strings.TrimSpace(global.CONFIG.Catchup.Udpxy) != "" {
		return strings.TrimSpace(global.CONFIG.Catchup.Udpxy)
	}
	return "192.168.100.51:4022"
}

func configuredCatchupDays() int {
	if global.CONFIG != nil && global.CONFIG.Catchup.Days > 0 && global.CONFIG.Catchup.Days <= catchupMaxDays {
		return global.CONFIG.Catchup.Days
	}
	return catchupMaxDays
}

func retryableRelayError(err error) bool {
	if errors.Is(err, context.Canceled) {
		return false
	}
	var relayErr *hlsRelayError
	if errors.As(err, &relayErr) {
		return relayErr.status == http.StatusUnauthorized || relayErr.status == http.StatusForbidden ||
			relayErr.status == http.StatusNotFound || relayErr.status == http.StatusTooManyRequests || relayErr.status >= 500
	}
	var netErr net.Error
	return errors.As(err, &netErr) && netErr.Timeout()
}

func relayHLS(ctx context.Context, playlistURL string, writer io.Writer) (int64, error) {
	return relayHLSWithSource(ctx, tvodPlaySource{playlistURL: playlistURL}, writer)
}

func relayHLSWithSource(ctx context.Context, source tvodPlaySource, writer io.Writer) (int64, error) {
	client := iptvHTTPClient(0, nil)
	current := source.playlistURL
	seen := make(map[string]bool)
	var written int64
	for {
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, current, nil)
		if err != nil {
			return written, err
		}
		setHLSHeaders(request, source)
		var response *http.Response
		for retry := 0; ; retry++ {
			response, err = client.Do(request)
			if err == nil || retry >= catchupSegmentRetries {
				break
			}
			if waitErr := waitCatchupRetry(ctx, retry); waitErr != nil {
				return written, waitErr
			}
		}
		if err != nil {
			return written, err
		}
		if response.StatusCode != http.StatusOK {
			response.Body.Close()
			if response.StatusCode == http.StatusRequestedRangeNotSatisfiable && written > 0 {
				return written, nil
			}
			return written, &hlsRelayError{status: response.StatusCode, err: fmt.Errorf("HLS request returned %s", response.Status)}
		}
		reader := bufio.NewReader(response.Body)
		probe, _ := reader.Peek(16)
		trimmedProbe := bytes.TrimLeft(probe, " \t\r\n")
		if len(trimmedProbe) == 0 || !bytes.HasPrefix(trimmedProbe, []byte("#EXT")) {
			// 上游直接回媒体流（如整段 .ts）而非 HLS 播放列表：原样透传
			n, copyErr := io.Copy(writer, reader)
			written += n
			if flusher, ok := writer.(interface{ Flush() }); ok {
				flusher.Flush()
			}
			if copyErr != nil {
				return written, copyErr
			}
			if n == 0 {
				return written, errors.New("upstream returned empty response")
			}
			return written, nil
		}
		body, readErr := io.ReadAll(io.LimitReader(reader, 32<<20))
		response.Body.Close()
		if readErr != nil {
			return written, readErr
		}
		lines := strings.Split(strings.ReplaceAll(string(body), "\r\n", "\n"), "\n")
		base, _ := url.Parse(current)
		segments := make([]string, 0, 16)
		isMaster := false
		for _, line := range lines {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "#EXT-X-STREAM-INF") {
				isMaster = true
				continue
			}
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			u, err := base.Parse(line)
			if err != nil {
				continue
			}
			if isMaster {
				current = u.String()
				break
			}
			segments = append(segments, u.String())
		}
		if isMaster {
			continue
		}
		if len(segments) == 0 {
			return written, errors.New("HLS playlist has no media segments")
		}
		for _, segment := range segments {
			// 长时间中继时 seen 无界增长会吃内存：到上限就整表重置（最多重发最近一屏段）
			if len(seen) >= 4096 {
				seen = make(map[string]bool)
			}
			if seen[segment] {
				continue
			}
			seen[segment] = true
			req, err := http.NewRequestWithContext(ctx, http.MethodGet, segment, nil)
			if err != nil {
				return written, err
			}
			setHLSHeaders(req, source)
			var resp *http.Response
			for retry := 0; ; retry++ {
				resp, err = client.Do(req)
				if err == nil || retry >= catchupSegmentRetries {
					break
				}
				if waitErr := waitCatchupRetry(ctx, retry); waitErr != nil {
					return written, waitErr
				}
			}
			if err != nil {
				return written, err
			}
			if resp.StatusCode != http.StatusOK {
				resp.Body.Close()
				if resp.StatusCode == http.StatusRequestedRangeNotSatisfiable && written > 0 {
					return written, nil
				}
				return written, &hlsRelayError{status: resp.StatusCode, err: fmt.Errorf("HLS segment returned %s", resp.Status)}
			}
			n, copyErr := io.Copy(writer, resp.Body)
			written += n
			resp.Body.Close()
			if copyErr != nil {
				return written, copyErr
			}
			if flusher, ok := writer.(interface{ Flush() }); ok {
				flusher.Flush()
			}
		}
		if strings.Contains(string(body), "#EXT-X-ENDLIST") {
			return written, nil
		}
		select {
		case <-ctx.Done():
			return written, ctx.Err()
		case <-time.After(1 * time.Second):
		}
		// Live-style playlists may advance; re-fetch the same signed URL.
	}
}

func waitCatchupRetry(ctx context.Context, retry int) error {
	delay := catchupRetryDelay * time.Duration(retry+1)
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func setHLSHeaders(request *http.Request, source tvodPlaySource) {
	request.Header.Set("User-Agent", catchupUserAgent)
	if source.referer != "" {
		request.Header.Set("Referer", source.referer)
		if parsed, err := url.Parse(source.referer); err == nil {
			request.Header.Set("Origin", parsed.Scheme+"://"+parsed.Host)
		}
	}
	if source.cookie != nil {
		request.AddCookie(source.cookie)
	}
}

func getTvodPlayURL(ctx context.Context, mixNo string, start time.Time, duration time.Duration) (tvodPlaySource, error) {
	var info model.ChannelInfo
	if err := global.DB.Where("mix_no = ?", mixNo).First(&info).Error; err != nil {
		return tvodPlaySource{}, err
	}
	var program model.EPGDetails
	ms := start.UnixMilli()
	exactProgram := true
	if err := global.DB.Where("comm_name = ? AND start_time <= ? AND end_time > ?", info.CommName, ms, ms).Order("start_time DESC").First(&program).Error; err != nil {
		exactProgram = false
		if previousErr := global.DB.Where("comm_name = ? AND end_time <= ?", info.CommName, ms).Order("end_time DESC").First(&program).Error; previousErr != nil || ms-program.EndTime > int64(6*time.Hour/time.Millisecond) {
			if nextErr := global.DB.Where("comm_name = ? AND start_time > ?", info.CommName, ms).Order("start_time ASC").First(&program).Error; nextErr != nil || program.StartTime-ms > int64(6*time.Hour/time.Millisecond) {
				return tvodPlaySource{}, &tvodError{status: http.StatusNotFound, msg: "catchup program not found"}
			}
		}
		global.LOG.Warn(fmt.Sprintf("catchup EPG gap fallback channel=%s requested=%s anchor=%s", mixNo, start.Format(time.RFC3339), program.ID))
	}
	programStart := program.StartTime / 1000
	programEnd := program.EndTime / 1000
	requestedStart := start.Unix()
	requestedEnd := start.Add(duration).Unix()
	if requestedEnd > time.Now().Unix() {
		requestedEnd = time.Now().Unix()
	}
	if exactProgram {
		requestedStart, requestedEnd = normalizeCatchupWindow(programStart, programEnd, requestedStart, requestedEnd)
	}
	if requestedEnd <= requestedStart {
		return tvodPlaySource{}, &tvodError{status: http.StatusRequestedRangeNotSatisfiable, msg: "TVOD request range is empty"}
	}
	// Historical TVOD URLs are signed by the provider. Do not reuse them:
	// a cached URL can return 401 while a freshly issued URL is valid.
	// Request only the range selected by TiviMate, clipped to the EPG item
	// and to the part that has already aired.
	form := url.Values{"action": {"getTvodPlayUrl"}, "channelID": {info.ChID}, "playbillID": {program.ID}, "startTime": {strconv.FormatInt(requestedStart, 10)}, "endTime": {strconv.FormatInt(requestedEnd, 10)}}
	anchorIDs := []string{program.ID}
	var previousPrograms []model.EPGDetails
	global.DB.Where("comm_name = ? AND end_time <= ?", info.CommName, program.StartTime).
		Order("end_time DESC").Limit(4).Find(&previousPrograms)
	for _, previous := range previousPrograms {
		if program.StartTime-previous.EndTime > int64(6*time.Hour/time.Millisecond) {
			break
		}
		if previous.ID != "" && previous.ID != program.ID {
			anchorIDs = append(anchorIDs, previous.ID)
		}
	}
	anchorIndex := 0
	authRefreshUsed := false
	for attempt := 0; attempt < len(anchorIDs)+2; attempt++ {
		form.Set("playbillID", anchorIDs[anchorIndex])
		var authInfo model.AuthInfo
		if err := global.DB.Order("updated_at DESC").First(&authInfo).Error; err != nil {
			return tvodPlaySource{}, err
		}
		endpoint := strings.TrimRight(authInfo.EPGHostUrl, "/") + "/function/ajax/epg7getChannelByAjax.jsp"
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
		if err != nil {
			return tvodPlaySource{}, err
		}
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.Header.Set("User-Agent", catchupUserAgent)
		req.AddCookie(&http.Cookie{Name: "JSESSIONID", Value: authInfo.JSESSIONID})
		resp, err := tvodHTTPClient.Do(req)
		if err != nil {
			return tvodPlaySource{}, err
		}
		body, readErr := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		resp.Body.Close()
		if readErr != nil {
			return tvodPlaySource{}, readErr
		}

		if resp.StatusCode == http.StatusMovedPermanently || resp.StatusCode == http.StatusFound ||
			resp.StatusCode == http.StatusTemporaryRedirect || resp.StatusCode == http.StatusPermanentRedirect ||
			resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
			if !authRefreshUsed {
				authRefreshUsed = true
				if err := refreshTvodAuth(); err != nil {
					return tvodPlaySource{}, fmt.Errorf("refresh TVOD session: %w", err)
				}
				continue
			}
			return tvodPlaySource{}, &tvodError{status: http.StatusUnauthorized, msg: "TVOD authentication rejected"}
		}

		var out struct {
			Status string `json:"status"`
			Data   struct {
				PlayURL string `json:"playURL"`
			} `json:"data"`
		}
		if err := json.Unmarshal(body, &out); err != nil {
			return tvodPlaySource{}, err
		}
		if out.Status != "1" || out.Data.PlayURL == "" {
			if anchorIndex+1 < len(anchorIDs) {
				anchorIndex++
				global.LOG.Warn(fmt.Sprintf("catchup unavailable playbill fallback channel=%s requested=%s anchor=%s candidate=%d/%d", mixNo, start.Format(time.RFC3339), anchorIDs[anchorIndex], anchorIndex+1, len(anchorIDs)))
				continue
			}
			global.LOG.Warn(fmt.Sprintf("TVOD URL unavailable channel=%s playbill=%s provider_status=%s", info.ChID, anchorIDs[anchorIndex], out.Status))
			return tvodPlaySource{}, &tvodError{status: http.StatusNotFound, msg: "TVOD program unavailable"}
		}
		return tvodPlaySource{playlistURL: out.Data.PlayURL, cookie: &http.Cookie{Name: "JSESSIONID", Value: authInfo.JSESSIONID}, referer: endpoint}, nil
	}
	return tvodPlaySource{}, errors.New("TVOD URL not issued")
}

func normalizeCatchupWindow(programStart, programEnd, requestedStart, requestedEnd int64) (int64, int64) {
	if requestedStart < programStart {
		requestedStart = programStart
	}
	if requestedEnd > programEnd {
		requestedEnd = programEnd
	}
	minimum := int64(catchupMinTail / time.Second)
	if requestedEnd > requestedStart && requestedEnd-requestedStart < minimum {
		requestedStart = requestedEnd - minimum
		if requestedStart < programStart {
			requestedStart = programStart
		}
	}
	return requestedStart, requestedEnd
}

func refreshTvodAuth() error {
	tvodAuthMu.Lock()
	defer tvodAuthMu.Unlock()
	client := auth.GetGlobalClient()
	if client == nil {
		return errors.New("IPTV auth client is not initialized")
	}
	if time.Since(client.AuthInfo.UpdatedAt) < 2*time.Minute {
		return nil
	}
	global.LOG.Warn("TVOD session expired; starting IPTV re-authentication")
	return client.StartAuth()
}

func stopRequest(ctx iris.Context, status int, err error) {
	ctx.StatusCode(status)
	if err != nil {
		if global.LOG != nil {
			global.LOG.Warn(fmt.Sprintf("catchup request rejected status=%d path=%s error=%s", status, ctx.Path(), err.Error()))
		}
		_, _ = ctx.WriteString(err.Error())
	}
	ctx.StopExecution()
}

func parseCatchupRange(ctx iris.Context) (time.Time, time.Duration, error) {
	rawStart := ctx.URLParam("start")
	if rawStart == "" {
		rawStart = ctx.Params().Get("start")
	}
	if rawStart == "" {
		rawStart = ctx.URLParam("utc")
	}
	if rawStart == "" {
		rawStart = ctx.URLParam("lutc")
	}
	seconds, err := strconv.ParseInt(rawStart, 10, 64)
	if err != nil {
		return time.Time{}, 0, errors.New("start must be a Unix timestamp")
	}
	if seconds > 1_000_000_000_000 {
		seconds /= 1000
	}
	start := time.Unix(seconds, 0).UTC()

	rawDuration := ctx.URLParam("duration")
	if rawDuration == "" {
		rawDuration = ctx.Params().Get("duration")
	}
	if rawDuration == "" {
		rawDuration = "3600"
	}
	rawDuration = strings.TrimSuffix(rawDuration, ".ts")
	durationSeconds, err := strconv.ParseInt(rawDuration, 10, 64)
	var duration time.Duration
	if err == nil {
		// IPTV# sends programme duration in milliseconds.
		if durationSeconds > int64(catchupMaxDuration/time.Second) && durationSeconds%1000 == 0 {
			durationSeconds /= 1000
		}
		duration = time.Duration(durationSeconds) * time.Second
	} else if parsed, parseErr := time.ParseDuration(rawDuration); parseErr == nil {
		duration = parsed
	} else {
		return time.Time{}, 0, errors.New("duration must be seconds or a Go duration")
	}
	if duration <= 0 {
		return time.Time{}, 0, errors.New("duration must be positive")
	}
	if duration > catchupMaxDuration {
		return time.Time{}, 0, errors.New("duration exceeds eight hours")
	}
	if err := validateCatchupStart(start, time.Now().UTC()); err != nil {
		return time.Time{}, 0, err
	}
	return start, duration, nil
}

func validateCatchupStart(start time.Time, now time.Time) error {
	if start.After(now.Add(5 * time.Minute)) {
		return errors.New("start is in the future")
	}
	return nil
}
