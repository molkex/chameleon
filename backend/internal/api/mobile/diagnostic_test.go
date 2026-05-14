package mobile

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"
	"go.uber.org/zap/zaptest/observer"
)

// newObservedHandler returns a Handler whose Logger writes into an
// in-memory observer so tests can assert on the structured log lines.
func newObservedHandler() (*Handler, *observer.ObservedLogs) {
	core, logs := observer.New(zap.InfoLevel)
	return &Handler{Logger: zap.New(core)}, logs
}

func postDiagnostic(t *testing.T, h *Handler, body string) int {
	t.Helper()
	e := echo.New()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/mobile/diagnostic", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)
	if err := h.PostDiagnostic(c); err != nil {
		t.Fatalf("PostDiagnostic returned error: %v", err)
	}
	return rec.Code
}

// TestDiagnosticRoutingEvent_LogsAsMobileDiagnostic — a routing telemetry
// event (country_dead etc.) lands on the mobile.diagnostic log key, NOT
// mobile.crash.
func TestDiagnosticRoutingEvent_LogsAsMobileDiagnostic(t *testing.T) {
	h, logs := newObservedHandler()
	code := postDiagnostic(t, h, `{"event":"country_dead","country":"🇩🇪 Германия","dead_leaves":["de-direct-de"],"network_type":"cellular","ts":"2026-05-14T12:00:00Z"}`)
	if code != http.StatusNoContent {
		t.Errorf("status = %d, want 204", code)
	}
	if got := logs.FilterMessage("mobile.diagnostic").Len(); got != 1 {
		t.Errorf("mobile.diagnostic log lines = %d, want 1", got)
	}
	if got := logs.FilterMessage("mobile.crash").Len(); got != 0 {
		t.Errorf("mobile.crash log lines = %d, want 0 — a routing event must not hit the crash key", got)
	}
}

// TestDiagnosticCrashEvent_LogsAsMobileCrash — a crash event routes to
// the mobile.crash log key with all crash fields carried through.
func TestDiagnosticCrashEvent_LogsAsMobileCrash(t *testing.T) {
	h, logs := newObservedHandler()
	body := `{
		"event":"crash",
		"crash_signal":"exc=1 code=1 sig=11",
		"crash_termination":"Namespace SIGNAL, Code 11",
		"app_build":"65",
		"os_version":"17.4.1",
		"device_type":"iPhone15,2",
		"call_stack_top":["MadFrogVPN+10240","PacketTunnel+88123"],
		"ts":"2026-05-14T12:00:00Z"
	}`
	code := postDiagnostic(t, h, body)
	if code != http.StatusNoContent {
		t.Errorf("status = %d, want 204", code)
	}

	crashLogs := logs.FilterMessage("mobile.crash")
	if crashLogs.Len() != 1 {
		t.Fatalf("mobile.crash log lines = %d, want 1", crashLogs.Len())
	}
	if logs.FilterMessage("mobile.diagnostic").Len() != 0 {
		t.Error("a crash event must not also log mobile.diagnostic")
	}

	entry := crashLogs.All()[0]
	fields := entry.ContextMap()
	if fields["crash_signal"] != "exc=1 code=1 sig=11" {
		t.Errorf("crash_signal = %v, want carried through", fields["crash_signal"])
	}
	if fields["app_build"] != "65" {
		t.Errorf("app_build = %v, want 65", fields["app_build"])
	}
	if fields["device_type"] != "iPhone15,2" {
		t.Errorf("device_type = %v, want iPhone15,2", fields["device_type"])
	}
}

// TestDiagnosticCrashEvent_HangAlsoRoutesToCrashKey — hang/cpu/disk
// events share the crash log key.
func TestDiagnosticCrashEvent_HangAlsoRoutesToCrashKey(t *testing.T) {
	for _, ev := range []string{"hang", "cpu", "disk"} {
		h, logs := newObservedHandler()
		postDiagnostic(t, h, `{"event":"`+ev+`","crash_signal":"`+ev+`-info","app_build":"65","ts":"2026-05-14T12:00:00Z"}`)
		if logs.FilterMessage("mobile.crash").Len() != 1 {
			t.Errorf("event=%q did not route to mobile.crash", ev)
		}
	}
}

// TestDiagnosticCrashFields_AreCapped — defence-in-depth: an oversized
// crash payload is truncated, not logged verbatim.
func TestDiagnosticCrashFields_AreCapped(t *testing.T) {
	h, logs := newObservedHandler()
	bigSignal := strings.Repeat("A", 500)            // cap 64
	bigTermination := strings.Repeat("B", 1000)      // cap 256
	manyFrames := make([]string, 40)                 // cap 16
	for i := range manyFrames {
		manyFrames[i] = `"` + strings.Repeat("F", 300) + `"` // each cap 128
	}
	body := `{"event":"crash","crash_signal":"` + bigSignal + `","crash_termination":"` + bigTermination + `","call_stack_top":[` + strings.Join(manyFrames, ",") + `],"ts":"2026-05-14T12:00:00Z"}`
	postDiagnostic(t, h, body)

	entry := logs.FilterMessage("mobile.crash").All()[0]
	f := entry.ContextMap()
	if s, _ := f["crash_signal"].(string); len(s) > 64 {
		t.Errorf("crash_signal len = %d, want <= 64", len(s))
	}
	if s, _ := f["crash_termination"].(string); len(s) > 256 {
		t.Errorf("crash_termination len = %d, want <= 256", len(s))
	}
	if frames, _ := f["call_stack_top"].([]string); len(frames) > 16 {
		t.Errorf("call_stack_top len = %d, want <= 16", len(frames))
	} else {
		for _, fr := range frames {
			if len(fr) > 128 {
				t.Errorf("call_stack_top frame len = %d, want <= 128", len(fr))
			}
		}
	}
}

// TestDiagnosticMalformedBody_StillReturns204 — a body that doesn't even
// parse is accepted silently (no 400 storm masquerading as an outage).
func TestDiagnosticMalformedBody_StillReturns204(t *testing.T) {
	h, _ := newObservedHandler()
	code := postDiagnostic(t, h, `{not json`)
	if code != http.StatusNoContent {
		t.Errorf("status = %d, want 204 for malformed body", code)
	}
}
