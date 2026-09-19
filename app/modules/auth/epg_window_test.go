package auth

import "testing"

func TestEPGDisplayTitleMarksExpiredProgramme(t *testing.T) {
	boundary := int64(1000)
	if got := epgDisplayTitle("节目", 999, boundary); got != "节目【已过期】" {
		t.Fatalf("expired title = %q", got)
	}
	if got := epgDisplayTitle("节目", 1000, boundary); got != "节目" {
		t.Fatalf("playable title = %q", got)
	}
}
