package api

import (
	"net"
	"strings"
	"testing"

	"iptv-spider-sh/config"
	"iptv-spider-sh/global"
)

func TestIsPrivateClientHonorsRelayClients(t *testing.T) {
	previous := global.CONFIG
	global.CONFIG = &config.Server{
		Catchup: config.Catchup{RelayClients: []string{"198.51.100.7", "203.0.113.0/24"}},
	}
	defer func() { global.CONFIG = previous }()

	for _, ip := range []string{"198.51.100.7", "203.0.113.99"} {
		if !isPrivateClient(net.ParseIP(ip)) {
			t.Fatalf("isPrivateClient(%s) = false, want true via relay_clients", ip)
		}
	}
	if isPrivateClient(net.ParseIP("198.51.100.8")) {
		t.Fatal("isPrivateClient(198.51.100.8) = true, want false")
	}
	// 私网判定不受影响
	if !isPrivateClient(net.ParseIP("192.168.100.50")) {
		t.Fatal("isPrivateClient(192.168.100.50) = false, want true")
	}
}

func TestApplyReferenceMappingInsertsLogoWhenMissing(t *testing.T) {
	line := `#EXTINF:-1 tvg-id="9" group-title="卫视",东方卫视`
	mappings := map[string]referenceMapping{
		"id:9": {logo: "dongfang.png", group: "卫视"},
	}
	out := applyReferenceMapping(line, mappings, "http://127.0.0.1:8888/iptvlogos/")
	if !strings.Contains(out, `tvg-logo="http://127.0.0.1:8888/iptvlogos/dongfang.png"`) {
		t.Fatalf("missing inserted logo: %q", out)
	}
	if !strings.Contains(out, `group-title="卫视"`) {
		t.Fatalf("group attribute lost: %q", out)
	}
	if !strings.HasPrefix(out, "#EXTINF:-1") {
		t.Fatalf("EXTINF prefix broken: %q", out)
	}
}
