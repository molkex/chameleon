// metrics-agent is a lightweight HTTP server that exposes system metrics
// in the same JSON format as the full chameleon /api/cluster/node-status endpoint.
//
// Designed for relay/lightweight nodes that can't run the full stack (Docker, PostgreSQL, Redis).
// Uses ~5 MB RAM and reads metrics from /proc and statfs.
//
// Usage:
//
//	./metrics-agent -port 8000 -node-id relay-spb -name "SPB Relay" -flag "🇷🇺" -ip 185.218.0.43
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"math"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
)

var startedAt = time.Now()

type nodeResponse struct {
	Key         string           `json:"key"`
	Name        string           `json:"name"`
	Flag        string           `json:"flag"`
	IP          string           `json:"ip"`
	IsActive    bool             `json:"is_active"`
	LatencyMS   *int             `json:"latency_ms"`
	UserCount   int              `json:"user_count"`
	OnlineUsers int              `json:"online_users"`
	TrafficUp   int64            `json:"traffic_up"`
	TrafficDown int64            `json:"traffic_down"`
	UptimeHours *float64         `json:"uptime_hours"`
	Version     *string          `json:"xray_version"`
	Protocols   []protocolStatus `json:"protocols"`
	CPU         *float64         `json:"cpu"`
	RAMUsed     *float64         `json:"ram_used"`
	RAMTotal    *float64         `json:"ram_total"`
	Disk        *float64         `json:"disk"`
	Containers  []containerInfo  `json:"containers,omitempty"`
}

type protocolStatus struct {
	Name    string `json:"name"`
	Enabled bool   `json:"enabled"`
	Port    int    `json:"port"`
}

type containerInfo struct {
	Name   string `json:"name"`
	Status string `json:"status"`
}

func main() {
	port := flag.Int("port", 8000, "HTTP listen port")
	nodeID := flag.String("node-id", "relay-spb", "Node ID")
	name := flag.String("name", "SPB Relay", "Node display name")
	flagEmoji := flag.String("flag", "🇷🇺", "Flag emoji")
	ip := flag.String("ip", "", "Node public IP")
	version := flag.String("version", "nginx relay", "Software version string")
	flag.Parse()

	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
	})

	http.HandleFunc("/api/cluster/node-status", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")

		latency := 0
		uptime := time.Since(startedAt).Hours()
		ver := *version

		resp := nodeResponse{
			Key:       *nodeID,
			Name:      *name,
			Flag:      *flagEmoji,
			IP:        *ip,
			IsActive:  true,
			LatencyMS: &latency,
			UptimeHours: &uptime,
			Version:   &ver,
			Protocols: detectProtocols(),
		}

		// System metrics.
		if cpu := cpuPercent(); cpu >= 0 {
			v := roundTo(cpu, 1)
			resp.CPU = &v
		}
		if used, total := ramMB(); total > 0 {
			u := roundTo(used, 0)
			t := roundTo(total, 0)
			resp.RAMUsed = &u
			resp.RAMTotal = &t
		}
		if pct := diskPercent(); pct >= 0 {
			v := roundTo(pct, 1)
			resp.Disk = &v
		}

		// Detect running services.
		resp.Containers = detectServices()

		json.NewEncoder(w).Encode(resp)
	})

	addr := fmt.Sprintf(":%d", *port)
	log.Printf("metrics-agent starting on %s (node=%s)", addr, *nodeID)
	log.Fatal(http.ListenAndServe(addr, nil))
}

func roundTo(v float64, decimals int) float64 {
	shift := math.Pow(10, float64(decimals))
	return math.Round(v*shift) / shift
}

func cpuPercent() float64 {
	data, err := os.ReadFile("/proc/loadavg")
	if err != nil {
		return -1
	}
	fields := strings.Fields(string(data))
	if len(fields) < 1 {
		return -1
	}
	load1, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return -1
	}
	cores := float64(runtime.NumCPU())
	if cores < 1 {
		cores = 1
	}
	pct := (load1 / cores) * 100
	if pct > 100 {
		pct = 100
	}
	return pct
}

func ramMB() (used, total float64) {
	f, err := os.Open("/proc/meminfo")
	if err != nil {
		return 0, 0
	}
	defer f.Close()

	var totalKB, availKB int64
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "MemTotal:") {
			totalKB = parseMemValue(line)
		} else if strings.HasPrefix(line, "MemAvailable:") {
			availKB = parseMemValue(line)
		}
	}
	if totalKB == 0 {
		return 0, 0
	}
	return float64(totalKB-availKB) / 1024, float64(totalKB) / 1024
}

func parseMemValue(line string) int64 {
	parts := strings.Fields(line)
	if len(parts) >= 2 {
		v, _ := strconv.ParseInt(parts[1], 10, 64)
		return v
	}
	return 0
}

func diskPercent() float64 {
	var stat syscall.Statfs_t
	if err := syscall.Statfs("/", &stat); err != nil {
		return -1
	}
	total := stat.Blocks * uint64(stat.Bsize)
	free := stat.Bfree * uint64(stat.Bsize)
	if total == 0 {
		return -1
	}
	return float64(total-free) / float64(total) * 100
}

func detectProtocols() []protocolStatus {
	// Check which ports nginx is listening on.
	var protocols []protocolStatus
	ports := map[int]string{
		443:  "TCP Relay (443)",
		2096: "TCP Relay (2096→DE)",
		2098: "TCP Relay (2098→NL)",
	}
	for port, name := range ports {
		conn, err := fmt.Sprintf(":%d", port), error(nil)
		// Quick check: try to read /proc/net/tcp or use ss
		out, err := exec.Command("ss", "-tlnH", fmt.Sprintf("sport = %d", port)).Output()
		if err == nil && len(strings.TrimSpace(string(out))) > 0 {
			protocols = append(protocols, protocolStatus{Name: name, Enabled: true, Port: port})
		}
		_ = conn
	}
	if len(protocols) == 0 {
		protocols = append(protocols, protocolStatus{Name: "TCP Relay", Enabled: true, Port: 443})
	}
	return protocols
}

func detectServices() []containerInfo {
	var services []containerInfo

	// Check nginx.
	if out, err := exec.Command("pgrep", "-c", "nginx").Output(); err == nil {
		count := strings.TrimSpace(string(out))
		services = append(services, containerInfo{Name: "nginx", Status: fmt.Sprintf("running (%s procs)", count)})
	}

	// Check if any other notable services are running.
	for _, svc := range []string{"sshd", "fail2ban"} {
		if err := exec.Command("pgrep", "-x", svc).Run(); err == nil {
			services = append(services, containerInfo{Name: svc, Status: "running"})
		}
	}

	return services
}
