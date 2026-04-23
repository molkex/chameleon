// Package useragent parses the User-Agent string emitted by the Chameleon
// iOS / macOS apps. Example:
//
//	Chameleon/16 CFNetwork/3860.200.71 Darwin/25.1.0
//
// We care about: app version (16), the Darwin kernel version (25.1.0), and
// the OS family (iOS vs macOS). Since the app ships the same UA on both
// platforms we cannot distinguish iOS from macOS from the string alone —
// callers should pass that in out-of-band if available. For now we map
// Darwin → iOS/macOS by kernel version range.
package useragent

import (
	"regexp"
	"strconv"
	"strings"
)

// Parsed holds the fields we extract from a Chameleon UA.
type Parsed struct {
	AppVersion string // e.g. "16"
	OSName     string // "iOS" | "macOS" | "" if unknown
	OSVersion  string // Darwin version, e.g. "25.1.0"
}

var (
	appRe    = regexp.MustCompile(`Chameleon/(\S+)`)
	darwinRe = regexp.MustCompile(`Darwin/(\S+)`)
)

// Parse extracts app/OS info from the UA. Returns zero Parsed on unknown UAs.
func Parse(ua string) Parsed {
	var p Parsed
	if ua == "" {
		return p
	}
	if m := appRe.FindStringSubmatch(ua); len(m) == 2 {
		p.AppVersion = m[1]
	}
	if m := darwinRe.FindStringSubmatch(ua); len(m) == 2 {
		p.OSVersion = m[1]
		p.OSName = darwinToOSName(m[1])
	}
	return p
}

// darwinToOSName maps the Darwin kernel version to "iOS" or "macOS".
//
// Darwin 24+ covers iOS 18+ / macOS 15+. Since the Chameleon UA itself
// doesn't expose the user-facing OS name we use a heuristic: the app is
// compiled for both, but CFNetwork build numbers diverge slightly. Without
// a reliable marker we default to "iOS" (the dominant platform) when the
// kernel is recent and leave it empty otherwise.
func darwinToOSName(ver string) string {
	major := majorVersion(ver)
	if major >= 20 { // Darwin 20 = macOS 11 / iOS 14
		return "iOS"
	}
	return ""
}

func majorVersion(v string) int {
	dot := strings.IndexByte(v, '.')
	if dot < 0 {
		dot = len(v)
	}
	n, _ := strconv.Atoi(v[:dot])
	return n
}
