package model

import (
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"sort"
	"strconv"
	"strings"
	"time"
)

type ChannelInfo struct {
	CreatedAt     time.Time
	UpdatedAt     time.Time
	DeletedAt     gorm.DeletedAt `gorm:"index"`
	TsTime        int            `gorm:"comment:TimeShiftTime 时移时间" json:"tsTime"`
	Code          string         `gorm:"comment:频道代码" json:"code"`
	AuthCode      string         `gorm:"comment:付费认证代码" json:"authCode"`
	Name          string         `gorm:"comment:频道名称" json:"name"`
	ChID          string         `gorm:"comment:频道ID" json:"ID"`
	MixNo         string         `gorm:"primarykey;comment:用户频道映射" json:"mixNo"`
	MediaID       string         `gorm:"comment:未知" json:"mediaID"`
	IsTs          string         `gorm:"comment:是否支持回放" json:"isTs"`
	IsCharge      string         `gorm:"comment:是否需要付费" json:"isCharge"`
	IsHD          bool           `gorm:"default:false;comment:是否是高清频道" json:"-"`
	Is4K          bool           `gorm:"default:false;comment:是否是4K频道" json:"-"`
	IsPullEPG     bool           `gorm:"default:true;comment:是否拉取节目单" json:"-"`
	IsShow        bool           `gorm:"default:true;comment:是否展示该节目" json:"-"`
	CommName      string         `gorm:"comment:通用标题" json:"-"`
	LastFetchTime time.Time      `gorm:"comment:节目单最后更新时间" json:"-"`
}

func (h *ChannelInfo) processData() {
	name := strings.ToUpper(h.Name)
	h.CommName = name
	if strings.HasSuffix(name, "HD") {
		h.IsHD = true
		c := strings.ReplaceAll(name, "HD", "")
		h.CommName = strings.TrimSpace(c)
	} else if strings.HasSuffix(name, "4K") {
		h.IsHD = true
		h.Is4K = true
		if !strings.HasSuffix(name, "-4K") {
			c := strings.ReplaceAll(name, "4K", "")
			h.CommName = strings.TrimSpace(c)
		}
	} else if strings.Contains(name, "高清") {
		h.IsHD = true
		h.CommName = strings.ReplaceAll(name, "(高清)", "")
	}
	if h.CommName == "体育频道" {
		h.CommName = "五星体育"
	}
}

func (h *ChannelInfo) updateMapping(tx *gorm.DB) {
	if h.CommName == "" {
		return
	}
	var groups []string
	if strings.Contains(h.CommName, "CCTV") {
		groups = append(groups, "央视")
	} else if strings.Contains(h.Name, "卫视") {
		groups = append(groups, "卫视")
	} else if strings.Contains(h.Name, "购物") {
		groups = append(groups, "购物")
	} else if strings.Contains(h.Name, "年级") {
		groups = append(groups, "空中课堂")
	} else if strings.Contains(h.Name, "百事通") {
		groups = append(groups, "百事通")
	}
	tx.Clauses(clause.OnConflict{
		Columns:   []clause.Column{{Name: "comm_name"}},
		DoUpdates: clause.AssignmentColumns([]string{"auto_groups"}),
	}).Create(&M3u8Mapping{
		CommName:   h.CommName,
		AutoGroups: strings.Join(groups, ","),
	})
}
func (h *ChannelInfo) BeforeCreate(tx *gorm.DB) (err error) {
	h.processData()
	h.updateMapping(tx)
	return
}

func (h *ChannelInfo) BeforeUpdate(tx *gorm.DB) (err error) {
	h.processData()
	h.updateMapping(tx)
	return
}

// hiddenChannelKeywords 需要在所有输出（m3u / EPG）里隐藏的频道关键字。
// 导视类频道上游实际下发名是「高清导视频道」（不是「高清导视」），且会反复下发，
// 因此在统一收口处按关键字判断，避免依赖上游名称的精确写法。
var hiddenChannelKeywords = []string{"高清导视"}

// IsHiddenChannelName 频道名是否属于需要在输出中隐藏的频道。
func IsHiddenChannelName(name string) bool {
	n := strings.ToUpper(strings.TrimSpace(name))
	if n == "" {
		return false
	}
	for _, kw := range hiddenChannelKeywords {
		if strings.Contains(n, kw) {
			return true
		}
	}
	return false
}

// IsHidden 频道（名称或通用名）是否需要在输出中隐藏。
func (h *ChannelInfo) IsHidden() bool {
	return IsHiddenChannelName(h.Name) || IsHiddenChannelName(h.CommName)
}

// RemoveDuplicateChannelInfo  ChannelInfo 数组去重（同时剔除需隐藏的频道）
func RemoveDuplicateChannelInfo(in []ChannelInfo) []ChannelInfo {
	newMap := make(map[string]ChannelInfo, len(in))
	for _, child := range in {
		if child.IsHidden() {
			continue
		}
		if ch, ok := newMap[child.CommName]; ok {
			// 判断能否替换
			newMap[child.CommName] = check(ch, child)
			continue
		}
		newMap[child.CommName] = child
	}
	var newArr []ChannelInfo
	for _, v := range newMap {
		newArr = append(newArr, v)
	}
	// Keep the provider's numeric order as the tie-breaker, but make the
	// generated "all channels" list follow the user's category order.
	sort.SliceStable(newArr, func(i, j int) bool {
		ri, rj := channelSortRank(newArr[i]), channelSortRank(newArr[j])
		if ri != rj {
			return ri < rj
		}
		numi, err := strconv.Atoi(newArr[i].MixNo)
		if err != nil {
			return false
		}
		numj, err := strconv.Atoi(newArr[j].MixNo)
		if err != nil {
			return true
		}
		return numi < numj
	})
	return newArr
}

var preferredLocalOrder = map[string]int{
	"新闻综合": 0, "五星体育": 1, "第一财经": 2, "上海教育": 3,
	"都市频道": 4, "东方影视": 5, "东方财经": 6, "金鹰纪实": 7,
}

var localChannelNames = map[string]bool{
	"快乐垂钓": true, "游戏风云": true, "生活时尚": true, "动漫秀场": true,
	"乐游": true, "都市剧场": true, "法治天地": true, "多彩文体": true,
	"哈哈炫动": true, "金色学堂": true, "财富天下": true, "家庭理财": true,
}

var preferredCCTVByMixNo = map[string]int{
	"102": 0, "125": 1, "126": 2, "127": 3, "128": 4, "129": 5,
	"130": 6, "131": 7, "132": 8, "133": 9, "134": 10, "135": 11,
	"136": 12, "137": 13, "138": 14, "139": 15, "140": 16,
}

var preferredCCTVByName = map[string]int{
	"CCTV-1": 0, "CCTV-2": 1, "CCTV-3": 2, "CCTV-4": 3, "CCTV-5": 4,
	"CCTV-6": 5, "CCTV-7": 6, "CCTV-8": 7, "CCTV-9": 8, "CCTV-10": 9,
	"CCTV-11": 10, "CCTV-12": 11, "CCTV-13": 12, "CCTV-14": 13,
	"CCTV-15": 14, "CCTV-16": 15, "CCTV-17": 16,
}

var cctvSupplementNames = map[string]bool{
	"CGTN": true, "风云足球": true, "央视台球": true, "兵器科技": true,
	"世界地理": true, "女性时尚": true, "高尔夫网球": true, "怀旧剧场": true,
	"风云剧场": true, "第一剧场": true, "风云音乐": true, "央视文化精品": true,
	"早期教育": true, "中国教育-1": true, "中国教育-2": true, "中国教育-4": true,
	"CCTV-5+": true, "CCTV-4K": true,
}

func channelSortRank(ch ChannelInfo) int {
	name := strings.TrimSpace(ch.CommName)
	if rank, ok := preferredLocalOrder[name]; ok {
		return rank
	}
	if rank, ok := preferredCCTVByMixNo[ch.MixNo]; ok {
		return 100 + rank
	}
	if rank, ok := preferredCCTVByName[name]; ok {
		return 100 + rank
	}
	if cctvSupplementNames[name] {
		return 200
	}
	if localChannelNames[name] {
		return 50
	}
	if strings.Contains(name, "CCTV") {
		return 100 + cctvOrder(name)
	}
	if strings.Contains(name, "卫视") {
		return 300
	}
	if strings.HasPrefix(name, "CHC") {
		return 400
	}
	if strings.Contains(name, "卡通") || strings.Contains(name, "动漫") || strings.Contains(name, "炫动") || name == "卡酷少儿" {
		return 500
	}
	// Other local channels follow the requested local front section.
	if name != "" {
		return 50
	}
	return 600
}

func cctvOrder(name string) int {
	for i := 1; i <= 17; i++ {
		if name == "CCTV-"+strconv.Itoa(i) {
			return i - 1
		}
	}
	return 99
}

func check(c1, c2 ChannelInfo) ChannelInfo {
	if c1.Is4K {
		return c1
	} else if c2.Is4K {
		return c2
	} else if c1.IsHD {
		return c1
	}
	return c2
}
