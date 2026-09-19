package model

import "gorm.io/gorm"

type EPGDetails struct {
	// 外层 string ID 有意遮蔽 gorm.Model.ID：节目单主键是平台下发的 string playbillID。
	// gorm.Model 仅用于 CreatedAt/UpdatedAt/DeletedAt（勿改为内嵌无 ID 结构，会触发建表/迁移变化）
	gorm.Model        `json:"-"`
	CommName          string `gorm:"index;comment:节目通用名称" json:"-"`
	InterRecordStatus string `gorm:"comment:未知" json:"interRecordStatus"`
	Name              string `gorm:"comment:节目名称" json:"name"`
	ChannelName       string `gorm:"-" json:"channelName"`
	StartTime         int64  `gorm:"comment:开始时间" json:"startTime"`
	ID                string `gorm:"comment:ID" json:"ID"`
	EndTime           int64  `gorm:"index;comment:结束时间" json:"endTime"`
	MixNo             string `gorm:"-" json:"mixNo"`
	ChannelID         string `gorm:"-" json:"channelID"`
	Status            string `gorm:"comment:状态" json:"status"`
}
