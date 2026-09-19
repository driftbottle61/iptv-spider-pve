package model

import "testing"

func TestChannelInfoNormalizesSportsChannelAlias(t *testing.T) {
	channel := ChannelInfo{Name: "体育频道HD"}
	channel.processData()

	if channel.CommName != "五星体育" {
		t.Fatalf("expected 五星体育, got %q", channel.CommName)
	}
	if !channel.IsHD {
		t.Fatal("expected sports channel alias to remain HD")
	}
}

func TestHiddenChannelFilteredFromOutput(t *testing.T) {
	hidden := []string{"高清导视", "高清导视HD", "高清导视频道", " 高清导视频道 "}
	for _, name := range hidden {
		if !IsHiddenChannelName(name) {
			t.Fatalf("expected %q to be hidden", name)
		}
	}
	kept := []string{"新闻综合HD", "五星体育HD", "都市频道", ""}
	for _, name := range kept {
		if IsHiddenChannelName(name) {
			t.Fatalf("expected %q to be kept", name)
		}
	}

	in := []ChannelInfo{
		{Name: "高清导视频道", CommName: "高清导视频道", MixNo: "198"},
		{Name: "新闻综合HD", CommName: "新闻综合", MixNo: "101"},
	}
	out := RemoveDuplicateChannelInfo(in)
	if len(out) != 1 {
		t.Fatalf("expected 1 channel after filtering, got %d", len(out))
	}
	if out[0].MixNo != "101" {
		t.Fatalf("expected kept channel 101, got %s", out[0].MixNo)
	}
}
