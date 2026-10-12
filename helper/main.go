// Command wiz talks to a WiZ bulb over its local UDP API and prints one
// JSON object on stdout. The bar widget runs it once per action or refresh,
// so nothing stays resident between clicks.
//
//	wiz get <mac>          print the bulb state
//	wiz set <mac> <json>   apply setPilot params, then print the new state
//	wiz discover           list every bulb on the local networks
//
// An empty mac selects the single bulb that accepts unsigned local control
// (WiZ app: Settings > Security > Local communication > All controls).
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const wizPort = 38899

// State is what the widget renders. Temp is 0 while the bulb shows a colour.
type State struct {
	IP      string `json:"ip"`
	Mac     string `json:"mac"`
	On      bool   `json:"on"`
	Dimming int    `json:"dimming"`
	Temp    int    `json:"temp"`
	Color   bool   `json:"color"`
	R       int    `json:"r"`
	G       int    `json:"g"`
	B       int    `json:"b"`
	Scene   int    `json:"scene"`
	RSSI    int    `json:"rssi"`
}

type pilot struct {
	Mac     string `json:"mac"`
	RSSI    int    `json:"rssi"`
	State   bool   `json:"state"`
	SceneID int    `json:"sceneId"`
	Dimming int    `json:"dimming"`
	Temp    int    `json:"temp"`
	R       *int   `json:"r"`
	G       *int   `json:"g"`
	B       *int   `json:"b"`
}

type reply struct {
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
	// Present when the bulb runs in "Only verified controls" mode, which
	// rejects every unsigned write.
	HMAC string `json:"hmac"`
}

type bulb struct {
	IP     string `json:"ip"`
	Mac    string `json:"mac"`
	Signed bool   `json:"signed"`
}

func main() {
	out, err := run(os.Args[1:])
	if err != nil {
		out = map[string]string{"error": err.Error()}
	}
	json.NewEncoder(os.Stdout).Encode(out)
	if err != nil {
		os.Exit(1)
	}
}

func run(args []string) (any, error) {
	if len(args) == 0 {
		return nil, errors.New("usage: wiz get <mac> | set <mac> <json> | discover")
	}
	conn, err := net.ListenUDP("udp4", nil)
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	switch {
	case args[0] == "discover":
		return discover(), nil
	case args[0] == "get" && len(args) == 2:
		ip, p, err := locate(conn, normalizeMac(args[1]))
		if err != nil {
			return nil, err
		}
		return toState(ip, p), nil
	case args[0] == "set" && len(args) == 3:
		var params map[string]any
		if err := json.Unmarshal([]byte(args[2]), &params); err != nil {
			return nil, fmt.Errorf("params must be a JSON object: %w", err)
		}
		ip, _, err := locate(conn, normalizeMac(args[1]))
		if err != nil {
			return nil, err
		}
		r, err := call(conn, ip, "setPilot", params)
		if err != nil {
			return nil, err
		}
		if r.Error != nil {
			if r.HMAC != "" {
				return nil, errors.New("bulb only accepts verified controls; set Local communication to All controls in the WiZ app")
			}
			return nil, fmt.Errorf("bulb rejected %s: %s", args[2], r.Error.Message)
		}
		p, err := getPilot(conn, ip)
		if err != nil {
			return nil, err
		}
		return toState(ip, p), nil
	}
	return nil, fmt.Errorf("unknown command: %s", strings.Join(args, " "))
}

// locate finds the bulb's current IP, trying the cached address before
// sweeping the local networks, since DHCP can move the bulb.
func locate(conn *net.UDPConn, mac string) (string, pilot, error) {
	cached := readCache()
	if cached.IP != "" && (mac == "" || mac == cached.Mac) {
		if p, err := getPilot(conn, cached.IP); err == nil && p.Mac == cached.Mac {
			return cached.IP, p, nil
		}
	}

	var match []bulb
	for _, b := range discover() {
		if (mac != "" && b.Mac == mac) || (mac == "" && !b.Signed) {
			match = append(match, b)
		}
	}
	switch {
	case len(match) == 0 && mac != "":
		return "", pilot{}, fmt.Errorf("no bulb with MAC %s on this network", mac)
	case len(match) == 0:
		return "", pilot{}, errors.New("no bulb accepts local control; set Local communication to All controls in the WiZ app")
	case len(match) > 1:
		return "", pilot{}, errors.New("several bulbs accept local control; set the bulb MAC in the widget settings")
	}

	ip := match[0].IP
	p, err := getPilot(conn, ip)
	if err != nil {
		return "", pilot{}, err
	}
	writeCache(bulb{IP: ip, Mac: p.Mac})
	return ip, p, nil
}

// discover asks every address on the local IPv4 networks for its state.
// Routers often drop broadcasts, so each host is asked directly. Packets to
// hosts that ARP has not resolved yet count against the socket send buffer,
// so the sweep is spread over small per-socket batches; one socket for a
// whole /24 blocks for seconds.
func discover() []bulb {
	const batch = 32
	msg, _ := json.Marshal(map[string]any{"method": "getPilot", "params": map[string]any{}})
	hosts := localHosts()
	deadline := time.Now().Add(1200 * time.Millisecond)

	var mu sync.Mutex
	var wg sync.WaitGroup
	found := map[string]bulb{}
	for start := 0; start < len(hosts); start += batch {
		conn, err := net.ListenUDP("udp4", nil)
		if err != nil {
			continue
		}
		wg.Add(1)
		go func(conn *net.UDPConn, hosts []net.IP) {
			defer wg.Done()
			defer conn.Close()
			for _, ip := range hosts {
				conn.WriteToUDP(msg, &net.UDPAddr{IP: ip, Port: wizPort})
			}
			buf := make([]byte, 2048)
			conn.SetReadDeadline(deadline)
			for {
				n, addr, err := conn.ReadFromUDP(buf)
				if err != nil {
					return
				}
				var r reply
				var p pilot
				if json.Unmarshal(buf[:n], &r) != nil || json.Unmarshal(r.Result, &p) != nil || p.Mac == "" {
					continue
				}
				mu.Lock()
				found[addr.IP.String()] = bulb{IP: addr.IP.String(), Mac: p.Mac, Signed: r.HMAC != ""}
				mu.Unlock()
			}
		}(conn, hosts[start:min(start+batch, len(hosts))])
	}
	wg.Wait()

	bulbs := make([]bulb, 0, len(found))
	for _, b := range found {
		bulbs = append(bulbs, b)
	}
	return bulbs
}

// localHosts lists host and broadcast addresses for every up, non-loopback
// IPv4 network no larger than a /22.
func localHosts() []net.IP {
	ifaces, _ := net.Interfaces()
	var hosts []net.IP
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, _ := iface.Addrs()
		for _, a := range addrs {
			n, ok := a.(*net.IPNet)
			if !ok || n.IP.To4() == nil {
				continue
			}
			ones, bits := n.Mask.Size()
			if ones < 22 || ones > 30 {
				continue
			}
			base := ipToInt(n.IP.Mask(n.Mask))
			for i := uint32(1); i < 1<<(bits-ones); i++ {
				hosts = append(hosts, intToIP(base+i))
			}
		}
	}
	return hosts
}

func getPilot(conn *net.UDPConn, ip string) (pilot, error) {
	r, err := call(conn, ip, "getPilot", map[string]any{})
	if err != nil {
		return pilot{}, err
	}
	if r.Error != nil {
		return pilot{}, fmt.Errorf("getPilot: %s", r.Error.Message)
	}
	var p pilot
	if err := json.Unmarshal(r.Result, &p); err != nil {
		return pilot{}, err
	}
	return p, nil
}

// call sends one request and waits for the matching reply, retrying because
// UDP on Wi-Fi drops packets.
func call(conn *net.UDPConn, ip, method string, params map[string]any) (reply, error) {
	msg, _ := json.Marshal(map[string]any{"method": method, "params": params})
	addr := &net.UDPAddr{IP: net.ParseIP(ip), Port: wizPort}
	buf := make([]byte, 2048)
	for attempt := 0; attempt < 3; attempt++ {
		if _, err := conn.WriteToUDP(msg, addr); err != nil {
			return reply{}, err
		}
		conn.SetReadDeadline(time.Now().Add(400 * time.Millisecond))
		for {
			n, from, err := conn.ReadFromUDP(buf)
			if err != nil {
				break
			}
			if !from.IP.Equal(addr.IP) {
				continue
			}
			var r reply
			if err := json.Unmarshal(buf[:n], &r); err != nil {
				return reply{}, err
			}
			return r, nil
		}
	}
	return reply{}, fmt.Errorf("bulb at %s did not answer", ip)
}

func toState(ip string, p pilot) State {
	s := State{IP: ip, Mac: p.Mac, On: p.State, Dimming: p.Dimming, Temp: p.Temp, Scene: p.SceneID, RSSI: p.RSSI}
	if p.R != nil && p.G != nil && p.B != nil {
		s.Color, s.R, s.G, s.B = true, *p.R, *p.G, *p.B
	}
	return s
}

func cachePath() string {
	dir, err := os.UserCacheDir()
	if err != nil {
		return ""
	}
	return filepath.Join(dir, "omarchy-wiz", "bulb.json")
}

func readCache() bulb {
	var b bulb
	if data, err := os.ReadFile(cachePath()); err == nil {
		json.Unmarshal(data, &b)
	}
	return b
}

func writeCache(b bulb) {
	path := cachePath()
	if path == "" {
		return
	}
	os.MkdirAll(filepath.Dir(path), 0o755)
	data, _ := json.Marshal(b)
	os.WriteFile(path, data, 0o644)
}

// normalizeMac accepts aa:bb:cc:dd:ee:ff or aabbccddeeff, the form bulbs report.
func normalizeMac(mac string) string {
	return strings.ToLower(strings.NewReplacer(":", "", "-", "").Replace(strings.TrimSpace(mac)))
}

func ipToInt(ip net.IP) uint32 {
	v := ip.To4()
	return uint32(v[0])<<24 | uint32(v[1])<<16 | uint32(v[2])<<8 | uint32(v[3])
}

func intToIP(v uint32) net.IP {
	return net.IPv4(byte(v>>24), byte(v>>16), byte(v>>8), byte(v))
}
