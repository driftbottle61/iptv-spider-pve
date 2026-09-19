package auth

import "time"

var shanghaiTime = time.FixedZone("Asia/Shanghai", 8*60*60)

func epgHistoryBoundary(now time.Time, daysAgo int) int64 {
	local := now.In(shanghaiTime)
	today := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, shanghaiTime)
	return today.AddDate(0, 0, -daysAgo).UnixMilli()
}

func epgDisplayTitle(name string, startTime, playableBoundary int64) string {
	if startTime < playableBoundary {
		return name + "【已过期】"
	}
	return name
}
