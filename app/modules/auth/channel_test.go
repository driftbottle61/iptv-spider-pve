package auth

import "testing"

func TestGetChannelFormStringSkipsSegmentsWithoutEquals(t *testing.T) {
	// 含不带 "=" 的脏段（旧实现直接取 c[1] 越界 panic）
	in := `1000,ChannelID=12,UserChannelID=345,broken,TimeShift=1`
	ch := GetChannelFormString(in)
	if ch.ChannelID != "12" {
		t.Fatalf("ChannelID = %q, want 12", ch.ChannelID)
	}
	if ch.UserChannelID != "345" {
		t.Fatalf("UserChannelID = %q, want 345", ch.UserChannelID)
	}
	if ch.TimeShift != "1" {
		t.Fatalf("TimeShift = %q, want 1", ch.TimeShift)
	}
}

func TestGetChannelFormStringEmptySegment(t *testing.T) {
	in := `ChannelID=12,`
	if ch := GetChannelFormString(in); ch.ChannelID != "12" {
		t.Fatalf("ChannelID = %q, want 12", ch.ChannelID)
	}
}
