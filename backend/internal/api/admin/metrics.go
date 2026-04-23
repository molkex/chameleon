package admin

import (
	"bufio"
	"os/exec"
	"os"
	"runtime"
	"strconv"
	"strings"
	"syscall"
)

// systemMetrics holds host system resource usage.
type systemMetrics struct {
	CPUPercent *float64 // CPU load percentage (1-min load avg / cores * 100)
	RAMUsedMB  *float64 // RAM used in MB
	RAMTotalMB *float64 // RAM total in MB
	DiskPercent *float64 // Disk usage percentage
}

// collectSystemMetrics gathers CPU, RAM and disk usage from the host.
// Works inside Docker containers on Linux (reads /proc and uses statfs).
// Returns partial results on error — never fails completely.
func collectSystemMetrics() systemMetrics {
	var m systemMetrics

	// CPU: 1-minute load average / number of cores * 100
	if data, err := os.ReadFile("/proc/loadavg"); err == nil {
		fields := strings.Fields(string(data))
		if len(fields) >= 1 {
			if load1, err := strconv.ParseFloat(fields[0], 64); err == nil {
				cores := float64(runtime.NumCPU())
				if cores < 1 {
					cores = 1
				}
				pct := (load1 / cores) * 100
				if pct > 100 {
					pct = 100
				}
				m.CPUPercent = &pct
			}
		}
	}

	// RAM: parse /proc/meminfo
	if f, err := os.Open("/proc/meminfo"); err == nil {
		defer f.Close()
		var totalKB, availKB int64
		scanner := bufio.NewScanner(f)
		for scanner.Scan() {
			line := scanner.Text()
			if strings.HasPrefix(line, "MemTotal:") {
				totalKB = parseMemInfoValue(line)
			} else if strings.HasPrefix(line, "MemAvailable:") {
				availKB = parseMemInfoValue(line)
			}
		}
		if totalKB > 0 {
			totalMB := float64(totalKB) / 1024
			usedMB := float64(totalKB-availKB) / 1024
			m.RAMTotalMB = &totalMB
			m.RAMUsedMB = &usedMB
		}
	}

	// Disk: statfs on root filesystem
	var stat syscall.Statfs_t
	if err := syscall.Statfs("/", &stat); err == nil {
		total := stat.Blocks * uint64(stat.Bsize)
		free := stat.Bfree * uint64(stat.Bsize)
		if total > 0 {
			pct := float64(total-free) / float64(total) * 100
			m.DiskPercent = &pct
		}
	}

	return m
}

// parseMemInfoValue extracts the numeric kB value from a /proc/meminfo line.
// Example: "MemTotal:       16384000 kB" → 16384000
func parseMemInfoValue(line string) int64 {
	parts := strings.Fields(line)
	if len(parts) >= 2 {
		val, _ := strconv.ParseInt(parts[1], 10, 64)
		return val
	}
	return 0
}

// collectContainerStatus runs "docker ps" and parses the output into container info.
// Returns nil if docker is not available or the command fails.
func collectContainerStatus() []containerInfo {
	out, err := exec.Command("docker", "ps", "--format", "{{.Names}}\t{{.Status}}").Output()
	if err != nil {
		return nil
	}
	raw := strings.TrimSpace(string(out))
	if raw == "" {
		return nil
	}
	var containers []containerInfo
	for _, line := range strings.Split(raw, "\n") {
		parts := strings.SplitN(line, "\t", 2)
		if len(parts) != 2 {
			continue
		}
		containers = append(containers, containerInfo{
			Name:   strings.TrimSpace(parts[0]),
			Status: strings.TrimSpace(parts[1]),
		})
	}
	return containers
}
