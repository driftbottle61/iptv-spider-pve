// stb-probe captures a short IPTV authentication trace from RouterOS and
// extracts values needed by iptv-spider before the target host joins IPTV VLANs.
package main

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/google/gopacket"
	"github.com/google/gopacket/layers"
	"github.com/google/gopacket/pcapgo"
)

type capture struct {
	router, user, key, password, iface, mac, ip, file string
	port, vlan, seconds                               int
	keep                                              bool
}

const spiderAuthHost = "222.68.208.73:7001"

func main() {
	c := capture{}
	flag.StringVar(&c.router, "router", "192.168.100.1", "RouterOS address")
	flag.IntVar(&c.port, "router-port", 1314, "RouterOS SSH port")
	flag.StringVar(&c.user, "router-user", "david_ni", "RouterOS SSH user")
	flag.StringVar(&c.key, "router-key", "~/.ssh/id_ed25519_sbx_github", "SSH private key")
	passwordEnv := flag.String("router-password-env", "", "environment variable containing the RouterOS SSH password")
	flag.StringVar(&c.iface, "interface", "ether3_lan", "RouterOS physical IPTV port")
	flag.IntVar(&c.vlan, "vlan", 0, "optional 802.1Q VLAN filter; use 85 only on a physical trunk")
	flag.StringVar(&c.mac, "mac", "", "optional STB MAC filter")
	flag.StringVar(&c.ip, "ip", "", "optional STB IPv4 filter")
	flag.IntVar(&c.seconds, "duration", 90, "capture duration in seconds")
	flag.StringVar(&c.file, "output", "", "local pcap path (temporary by default)")
	flag.BoolVar(&c.keep, "keep-pcap", false, "do not delete the downloaded pcap")
	flag.Parse()
	if *passwordEnv != "" {
		c.password = os.Getenv(*passwordEnv)
		if c.password == "" {
			fatal("RouterOS 密码环境变量 %s 为空", *passwordEnv)
		}
	}
	if c.file != "" {
		values, err := parsePCAP(c.file)
		if err != nil {
			fatal("无法解析抓包文件：%v", err)
		}
		printYAML(values)
		return
	}

	if c.seconds < 10 || c.seconds > 600 {
		fatal("抓包时长必须在 10 到 600 秒之间")
	}
	if c.vlan < 0 || c.vlan > 4094 || (c.mac != "" && !validMAC(c.mac)) || (c.ip != "" && net.ParseIP(c.ip) == nil) {
		fatal("VLAN、MAC 或 IP 参数无效")
	}
	if c.password == "" {
		c.key = expandHome(c.key)
		if _, err := os.Stat(c.key); err != nil {
			fatal("SSH 私钥不可用：%v", err)
		}
	} else if _, err := exec.LookPath("sshpass"); err != nil {
		fatal("密码登录需要安装 sshpass")
	}

	name := fmt.Sprintf("stb-probe-%d.pcap", time.Now().UnixNano())
	local := c.file
	if local == "" {
		local = filepath.Join(os.TempDir(), name)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(c.seconds+45)*time.Second)
	defer cancel()

	fmt.Printf("正在抓取 RouterOS %s 的 %s 接口，持续 %d 秒。请现在重启或重新连接机顶盒。\n", c.router, c.iface, c.seconds)
	if err := remoteCapture(ctx, c, name); err != nil {
		fatal("RouterOS 抓包失败：%v", err)
	}
	defer remoteDelete(context.Background(), c, name)
	if err := download(ctx, c, name, local); err != nil {
		fatal("无法下载 RouterOS 抓包文件：%v", err)
	}
	if !c.keep {
		defer os.Remove(local)
	}

	values, err := parsePCAP(local)
	if err != nil {
		fatal("无法解析抓包文件：%v", err)
	}
	printYAML(values)
	if c.keep {
		fmt.Printf("# 已保留抓包文件：%s\n", local)
	}
}

func remoteCapture(ctx context.Context, c capture, name string) error {
	// RouterOS has one global sniffer configuration. Save each changed setting and
	// restore it in the same SSH session once the bounded capture has stopped.
	vlan := `""`
	if c.vlan != 0 {
		vlan = fmt.Sprint(c.vlan)
	}
	set := fmt.Sprintf("file-name=%s file-limit=51200 filter-interface=%s filter-direction=rx filter-ip-protocol=\"\" filter-port=\"\" filter-vlan=%s filter-mac-address=%s filter-ip-address=%s", rosQuote(name), rosQuote(c.iface), vlan, rosQuote(c.mac), rosQuote(ipCIDR(c.ip)))
	fields := []string{"file-name", "file-limit", "filter-interface", "filter-direction", "filter-ip-protocol", "filter-port", "filter-vlan", "filter-mac-address", "filter-ip-address"}
	vars := make([]string, 0, len(fields))
	for i, f := range fields {
		vars = append(vars, fmt.Sprintf(":local p%d [/tool/sniffer get %s]", i, f))
	}
	restore := make([]string, 0, len(fields))
	for i, f := range fields {
		restore = append(restore, fmt.Sprintf("%s=$p%d", f, i))
	}
	script := fmt.Sprintf(":if ([/tool/sniffer get running]) do={:error \"sniffer is already running\"}; :local bp [/interface/bridge/port find where interface=%s]; :local hw \"\"; :if ([:len $bp] > 0) do={:set hw [/interface/bridge/port get $bp hw]; /interface/bridge/port set $bp hw=no}; %s; :do {/tool/sniffer set %s; /tool/sniffer start; :delay %ds} on-error={}; /tool/sniffer stop; :delay 2s; /tool/sniffer set %s; :if ([:len $bp] > 0) do={/interface/bridge/port set $bp hw=$hw}; :put \"stb-probe capture completed\"", rosQuote(c.iface), strings.Join(vars, "; "), set, c.seconds, strings.Join(restore, " "))
	cmd := sshExec(ctx, c, false, script)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func download(ctx context.Context, c capture, remote, local string) error {
	cmd := sshExec(ctx, c, true, fmt.Sprintf("%s@%s:%s", c.user, c.router, remote), local)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func remoteDelete(ctx context.Context, c capture, name string) {
	sshExec(ctx, c, false, fmt.Sprintf("/file/remove [find name=%s]", rosQuote(name))).Run()
}

func sshExec(ctx context.Context, c capture, scp bool, trailing ...string) *exec.Cmd {
	program := "ssh"
	portFlag := "-p"
	args := []string{}
	if scp {
		program = "scp"
		portFlag = "-P"
	}
	if c.password != "" {
		args = append(args, "-e", program, portFlag, fmt.Sprint(c.port), "-o", "BatchMode=no", "-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no", "-o", "KbdInteractiveAuthentication=yes")
		program = "sshpass"
	} else {
		args = append(args, "-i", c.key, portFlag, fmt.Sprint(c.port), "-o", "BatchMode=yes")
	}
	args = append(args, "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=10")
	if !scp {
		args = append(args, fmt.Sprintf("%s@%s", c.user, c.router))
	}
	args = append(args, trailing...)
	cmd := exec.CommandContext(ctx, program, args...)
	if c.password != "" {
		cmd.Env = append(os.Environ(), "SSHPASS="+c.password)
	}
	return cmd
}

func parsePCAP(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	magic := make([]byte, 4)
	if _, err := io.ReadFull(f, magic); err != nil {
		return nil, err
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	var r gopacket.PacketDataSource
	if bytes.Equal(magic, []byte{0x0a, 0x0d, 0x0d, 0x0a}) {
		r, err = pcapgo.NewNgReader(f, pcapgo.DefaultNgReaderOptions)
	} else {
		r, err = pcapgo.NewReader(f)
	}
	if err != nil {
		return nil, err
	}
	v := map[string]string{"auth_host": spiderAuthHost}
	privateByMAC := map[string]string{}
	var payloads bytes.Buffer
	for {
		data, _, err := r.ReadPacketData()
		if err != nil {
			break
		}
		p := gopacket.NewPacket(data, layers.LayerTypeEthernet, gopacket.Default)
		if vlan := p.Layer(layers.LayerTypeDot1Q); vlan != nil {
			v["vlan"] = strconv.Itoa(int(vlan.(*layers.Dot1Q).VLANIdentifier))
		}
		if dhcp := p.Layer(layers.LayerTypeDHCPv4); dhcp != nil {
			for _, option := range dhcp.(*layers.DHCPv4).Options {
				if byte(option.Type) == 125 {
					v["option125"] = hex.EncodeToString(option.Data)
				}
			}
		}
		if ip := p.Layer(layers.LayerTypeIPv4); ip != nil {
			i := ip.(*layers.IPv4)
			if eth := p.Layer(layers.LayerTypeEthernet); eth != nil && i.SrcIP.IsPrivate() {
				privateByMAC[strings.ToLower(eth.(*layers.Ethernet).SrcMAC.String())] = i.SrcIP.String()
			}
			if tcp := p.Layer(layers.LayerTypeTCP); tcp != nil {
				t := tcp.(*layers.TCP)
				dst := uint16(t.DstPort)
				// Telecom IPTV leases often use 30.x addresses, which are not RFC1918
				// private addresses. The outbound authentication flow is authoritative.
				if len(t.Payload) > 0 {
					payloads.Write(t.Payload)
					payloads.WriteByte('\n')
				}
				if dst == 80 || dst == 7001 || bytes.HasPrefix(t.Payload, []byte("GET ")) || bytes.HasPrefix(t.Payload, []byte("POST ")) {
					if eth := p.Layer(layers.LayerTypeEthernet); eth != nil && v["mac"] == "" {
						v["mac"] = eth.(*layers.Ethernet).SrcMAC.String()
					}
					if v["plane_b_ip"] == "" && strings.HasPrefix(i.SrcIP.String(), "30.") {
						v["plane_b_ip"] = i.SrcIP.String()
					}
				}
			}
		}
		if app := p.ApplicationLayer(); app != nil {
			extract(v, string(app.Payload()))
		}
	}
	extract(v, payloads.String())
	for _, body := range findGzipStreams(payloads.Bytes()) {
		extract(v, string(body))
	}
	if v["mac"] != "" {
		v["plane_a_ip"] = privateByMAC[strings.ToLower(v["mac"])]
	}
	return v, nil
}

func extract(v map[string]string, text string) {
	// Prefer protocol-specific identifiers. A physical port capture can include
	// unrelated LAN broadcasts and UPnP traffic, so generic uid/model fields are
	// not authoritative enough for provisioning.
	if m := regexp.MustCompile(`(?i)([A-Za-z0-9._-]+%40etv[0-9]+|[A-Za-z0-9._-]+@etv[0-9]+)`).FindStringSubmatch(text); len(m) == 2 {
		v["uid"], _ = url.QueryUnescape(m[1])
	}
	if m := regexp.MustCompile(`(?i)"MAC"[[:space:]]*:[[:space:]]*"([0-9A-F]{2}(?::[0-9A-F]{2}){5})"`).FindStringSubmatch(text); len(m) == 2 {
		v["mac"] = strings.ToLower(m[1])
	}
	if m := regexp.MustCompile(`(?i)(?:stbtype=|stbType[=:\\"]+)([A-Za-z0-9._-]+)`).FindStringSubmatch(text); len(m) == 2 {
		v["type"] = m[1]
	} else if m := regexp.MustCompile(`(?i)Android[^;]*;[[:space:]]*([A-Za-z0-9._-]+)[[:space:]]+Build/`).FindStringSubmatch(text); len(m) == 2 {
		v["type"] = m[1]
	}
	for _, item := range []struct{ key, name string }{
		{"plane_b_ip", "PlaneBIP"},
		{"plane_b_gateway", "SRIP"},
	} {
		expr := `(?i)"KeyName"[[:space:]]*:[[:space:]]*"` + item.name + `"[[:space:]]*,[[:space:]]*"KeyValue"[[:space:]]*:[[:space:]]*"([0-9.]+)"`
		if m := regexp.MustCompile(expr).FindStringSubmatch(text); len(m) == 2 {
			v[item.key] = m[1]
		}
	}
	for _, item := range []struct{ key, expr string }{
		{"sn", `(?i)(?:SN|serial(?:Number)?)[=:\\"]+([A-Za-z0-9_-]{8,})`},
		{"mac", `(?i)(?:MAC|MacAddr|macAddress)[=:\\"]+([0-9A-F]{2}(?::|-)[0-9A-F]{2}(?::|-)[0-9A-F]{2}(?::|-)[0-9A-F]{2}(?::|-)[0-9A-F]{2}(?::|-)[0-9A-F]{2})`},
	} {
		if v[item.key] == "" {
			if m := regexp.MustCompile(item.expr).FindStringSubmatch(text); len(m) == 2 {
				value, _ := url.QueryUnescape(m[1])
				if item.key == "mac" {
					value = strings.ReplaceAll(value, "-", ":")
				}
				if item.key == "plane_b_ip" || item.key == "plane_b_gateway" {
					value = strings.ReplaceAll(value, ",", ".")
				}
				v[item.key] = value
			}
		}
	}
}

func findGzipStreams(data []byte) [][]byte {
	var out [][]byte
	for pos := 0; ; {
		i := bytes.Index(data[pos:], []byte{0x1f, 0x8b, 0x08})
		if i < 0 {
			break
		}
		pos += i
		zr, err := gzip.NewReader(bytes.NewReader(data[pos:]))
		if err == nil {
			if body, readErr := io.ReadAll(zr); readErr == nil {
				out = append(out, body)
			}
			zr.Close()
		}
		pos += 3
	}
	return out
}

func printYAML(v map[string]string) {
	fmt.Println("stb:")
	for _, key := range []string{"uid", "mac", "sn", "type", "auth_host", "plane_a_ip", "plane_b_ip", "plane_b_gateway", "vlan", "option125"} {
		fmt.Printf("  %s: %q\n", key, v[key])
	}
	var missing []string
	for _, key := range []string{"uid", "mac", "sn", "type", "auth_host", "plane_a_ip", "plane_b_ip", "plane_b_gateway"} {
		if v[key] == "" {
			missing = append(missing, key)
		}
	}
	if len(missing) > 0 {
		fmt.Printf("# 缺少字段：%s。请在实体机顶盒启动或重新连接时抓包。\n", strings.Join(missing, ", "))
	}
}

func ipCIDR(ip string) string {
	if ip == "" {
		return ""
	}
	return ip + "/32"
}
func validMAC(s string) bool { _, err := net.ParseMAC(s); return err == nil }
func expandHome(s string) string {
	if s == "~" {
		h, _ := os.UserHomeDir()
		return h
	}
	if strings.HasPrefix(s, "~/") {
		h, _ := os.UserHomeDir()
		return filepath.Join(h, s[2:])
	}
	return s
}
func rosQuote(s string) string         { return "\"" + strings.ReplaceAll(s, "\"", "\\\"") + "\"" }
func fatal(format string, args ...any) { fmt.Fprintf(os.Stderr, format+"\n", args...); os.Exit(1) }
