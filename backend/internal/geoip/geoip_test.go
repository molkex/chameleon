package geoip

import (
	"context"
	"errors"
	"io"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// roundTripperFunc lets a test stand in for the network: every request
// the Resolver makes is answered by this func instead of ip-api.com.
type roundTripperFunc func(*http.Request) (*http.Response, error)

func (f roundTripperFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// newStubResolver returns a Resolver whose HTTP client is backed by rt,
// plus a pointer to a call counter so tests can assert cache behaviour.
func newStubResolver(rt roundTripperFunc) (*Resolver, *int32) {
	var calls int32
	counting := roundTripperFunc(func(req *http.Request) (*http.Response, error) {
		atomic.AddInt32(&calls, 1)
		return rt(req)
	})
	r := New()
	r.client = &http.Client{Transport: counting}
	return r, &calls
}

func jsonResponse(status int, body string) (*http.Response, error) {
	return &http.Response{
		StatusCode: status,
		Body:       io.NopCloser(strings.NewReader(body)),
		Header:     make(http.Header),
	}, nil
}

const okBody = `{"status":"success","countryCode":"RU","country":"Russia","city":"Saint Petersburg"}`

// ─── isPublicIP ────────────────────────────────────────────────────────────

func TestIsPublicIP(t *testing.T) {
	cases := []struct {
		ip   string
		want bool
	}{
		{"8.8.8.8", true},
		{"1.1.1.1", true},
		{"2001:4860:4860::8888", true}, // public IPv6
		{"127.0.0.1", false},           // loopback
		{"::1", false},                 // loopback v6
		{"10.0.0.1", false},            // private
		{"192.168.1.1", false},         // private
		{"172.16.0.1", false},          // private
		{"0.0.0.0", false},             // unspecified
		{"::", false},                  // unspecified v6
		{"169.254.1.1", false},         // link-local
		{"fe80::1", false},             // link-local v6
		{"", false},                    // not an IP
		{"not-an-ip", false},
		{"999.999.999.999", false},
	}
	for _, c := range cases {
		if got := isPublicIP(c.ip); got != c.want {
			t.Errorf("isPublicIP(%q) = %v, want %v", c.ip, got, c.want)
		}
	}
}

// ─── Lookup: non-public input never hits the network ───────────────────────

func TestLookup_NonPublicIP_NoFetch(t *testing.T) {
	r, calls := newStubResolver(func(*http.Request) (*http.Response, error) {
		t.Error("fetch must not be called for a non-public IP")
		return jsonResponse(http.StatusOK, okBody)
	})
	for _, ip := range []string{"127.0.0.1", "10.1.2.3", "", "garbage"} {
		if got := r.Lookup(context.Background(), ip); got != (Result{}) {
			t.Errorf("Lookup(%q) = %+v, want zero Result", ip, got)
		}
	}
	if *calls != 0 {
		t.Errorf("network called %d times for non-public IPs, want 0", *calls)
	}
}

// ─── Lookup: success path ──────────────────────────────────────────────────

func TestLookup_Success(t *testing.T) {
	r, _ := newStubResolver(func(*http.Request) (*http.Response, error) {
		return jsonResponse(http.StatusOK, okBody)
	})
	got := r.Lookup(context.Background(), "8.8.8.8")
	want := Result{Country: "RU", CountryName: "Russia", City: "Saint Petersburg"}
	if got != want {
		t.Errorf("Lookup = %+v, want %+v", got, want)
	}
}

func TestLookup_RequestTargetsIPAPI(t *testing.T) {
	var seenURL string
	r, _ := newStubResolver(func(req *http.Request) (*http.Response, error) {
		seenURL = req.URL.String()
		return jsonResponse(http.StatusOK, okBody)
	})
	r.Lookup(context.Background(), "8.8.8.8")
	if !strings.Contains(seenURL, "ip-api.com/json/8.8.8.8") {
		t.Errorf("request URL = %q, want it to target ip-api.com/json/8.8.8.8", seenURL)
	}
}

// ─── Lookup: cache hit / miss / expiry ─────────────────────────────────────

func TestLookup_CacheHit(t *testing.T) {
	r, calls := newStubResolver(func(*http.Request) (*http.Response, error) {
		return jsonResponse(http.StatusOK, okBody)
	})
	first := r.Lookup(context.Background(), "8.8.8.8")
	second := r.Lookup(context.Background(), "8.8.8.8")
	if first != second {
		t.Errorf("cached Lookup differs: %+v vs %+v", first, second)
	}
	if *calls != 1 {
		t.Errorf("network called %d times, want 1 (second Lookup must hit cache)", *calls)
	}
}

func TestLookup_CacheExpiry_Refetches(t *testing.T) {
	r, calls := newStubResolver(func(*http.Request) (*http.Response, error) {
		return jsonResponse(http.StatusOK, okBody)
	})
	r.Lookup(context.Background(), "8.8.8.8")
	// Force the cached entry past its TTL.
	r.mu.Lock()
	e := r.cache["8.8.8.8"]
	e.expiry = time.Now().Add(-time.Minute)
	r.cache["8.8.8.8"] = e
	r.mu.Unlock()

	r.Lookup(context.Background(), "8.8.8.8")
	if *calls != 2 {
		t.Errorf("network called %d times, want 2 (expired entry must re-fetch)", *calls)
	}
}

func TestLookup_CacheTTLIs24h(t *testing.T) {
	r, _ := newStubResolver(func(*http.Request) (*http.Response, error) {
		return jsonResponse(http.StatusOK, okBody)
	})
	before := time.Now()
	r.Lookup(context.Background(), "8.8.8.8")
	r.mu.RLock()
	exp := r.cache["8.8.8.8"].expiry
	r.mu.RUnlock()
	d := exp.Sub(before)
	if d < 23*time.Hour || d > 25*time.Hour {
		t.Errorf("cache TTL ~= %v, want ~24h", d)
	}
}

// ─── Lookup: failure paths all return a zero Result ────────────────────────

func TestLookup_FailurePaths_ReturnZero(t *testing.T) {
	cases := []struct {
		name string
		rt   roundTripperFunc
	}{
		{"transport error", func(*http.Request) (*http.Response, error) {
			return nil, errors.New("dial tcp: connection refused")
		}},
		{"non-200", func(*http.Request) (*http.Response, error) {
			return jsonResponse(http.StatusInternalServerError, "")
		}},
		{"api status fail", func(*http.Request) (*http.Response, error) {
			return jsonResponse(http.StatusOK, `{"status":"fail","message":"private range"}`)
		}},
		{"malformed json", func(*http.Request) (*http.Response, error) {
			return jsonResponse(http.StatusOK, `{not json`)
		}},
		{"empty body", func(*http.Request) (*http.Response, error) {
			return jsonResponse(http.StatusOK, ``)
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r, _ := newStubResolver(c.rt)
			if got := r.Lookup(context.Background(), "8.8.8.8"); got != (Result{}) {
				t.Errorf("%s: Lookup = %+v, want zero Result", c.name, got)
			}
		})
	}
}

func TestLookup_ContextCanceled_ReturnsZero(t *testing.T) {
	r, _ := newStubResolver(func(req *http.Request) (*http.Response, error) {
		// Honour cancellation the way a real transport does.
		return nil, req.Context().Err()
	})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if got := r.Lookup(ctx, "8.8.8.8"); got != (Result{}) {
		t.Errorf("Lookup with canceled ctx = %+v, want zero Result", got)
	}
}

// TestLookup_FailureIsCached pins current behaviour: a failed fetch is
// cached for the full TTL like a success. Consequence — a transient
// ip-api outage yields country="" for that IP for 24h. Per ADR-004 an
// empty country is the safe fallback ("ship full config"), so this
// degrades gracefully rather than mis-filtering; the test exists so a
// future change to cache-failures-shorter is a deliberate, visible edit.
func TestLookup_FailureIsCached(t *testing.T) {
	r, calls := newStubResolver(func(*http.Request) (*http.Response, error) {
		return nil, errors.New("network down")
	})
	r.Lookup(context.Background(), "8.8.8.8")
	r.Lookup(context.Background(), "8.8.8.8")
	if *calls != 1 {
		t.Errorf("network called %d times, want 1 (a failed lookup is cached)", *calls)
	}
}

// ─── concurrency (run with -race) ──────────────────────────────────────────

func TestLookup_ConcurrentIsSafe(t *testing.T) {
	r, _ := newStubResolver(func(*http.Request) (*http.Response, error) {
		return jsonResponse(http.StatusOK, okBody)
	})
	ips := []string{"8.8.8.8", "1.1.1.1", "9.9.9.9", "208.67.222.222"}
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			r.Lookup(context.Background(), ips[i%len(ips)])
		}(i)
	}
	wg.Wait()
}
