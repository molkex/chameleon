package admin

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"
)

// promMock spins up a fake Prometheus /api/v1/query endpoint. mode controls
// the response shape so we can exercise the happy path, the no-data path,
// and the unreachable/error path without a real Prometheus.
func promMock(t *testing.T, mode string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch mode {
		case "error":
			w.WriteHeader(http.StatusInternalServerError)
			return
		case "empty":
			_, _ = w.Write([]byte(`{"status":"success","data":{"resultType":"vector","result":[]}}`))
			return
		case "nan":
			_, _ = w.Write([]byte(`{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1700000000,"NaN"]}]}}`))
			return
		default: // "ok" — every query resolves to 42.5
			_, _ = w.Write([]byte(`{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1700000000,"42.5"]}]}}`))
		}
	}))
}

func callGetInfra(t *testing.T, promURL string) (int, infraResponse) {
	t.Helper()
	h := &Handler{Logger: zap.NewNop(), PrometheusURL: promURL}
	e := echo.New()
	req := httptest.NewRequest(http.MethodGet, "/stats/infra", nil)
	rec := httptest.NewRecorder()
	c := e.NewContext(req, rec)
	if err := h.GetInfra(c); err != nil {
		t.Fatalf("GetInfra returned error: %v", err)
	}
	var resp infraResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	return rec.Code, resp
}

// TestGetInfraHappyPath — every query resolves; all fields populated and
// Prometheus reported healthy.
func TestGetInfraHappyPath(t *testing.T) {
	srv := promMock(t, "ok")
	defer srv.Close()

	code, resp := callGetInfra(t, srv.URL)
	if code != http.StatusOK {
		t.Fatalf("status = %d, want 200", code)
	}
	if !resp.PrometheusOK {
		t.Errorf("PrometheusOK = false, want true")
	}
	// Spot-check a few representative fields across each category.
	for name, got := range map[string]*float64{
		"cpu_pct":       resp.CPUPct,
		"ram_pct":       resp.RAMPct,
		"disk_pct":      resp.DiskPct,
		"latency_p95":   resp.LatencyP95MS,
		"req_per_sec":   resp.ReqPerSec,
		"err_5xx_pct":   resp.Err5xxPct,
		"vpn_online":    resp.VPNOnline,
		"targets_up":    resp.TargetsUp,
		"targets_total": resp.TargetsTotal,
	} {
		if got == nil {
			t.Errorf("%s is nil, want 42.5", name)
			continue
		}
		if *got != 42.5 {
			t.Errorf("%s = %v, want 42.5", name, *got)
		}
	}
}

// TestGetInfraNoData — a query that returns an empty vector yields a nil
// field (rendered "—" by the UI), not a zero and not an error.
func TestGetInfraNoData(t *testing.T) {
	srv := promMock(t, "empty")
	defer srv.Close()

	code, resp := callGetInfra(t, srv.URL)
	if code != http.StatusOK {
		t.Fatalf("status = %d, want 200", code)
	}
	if resp.CPUPct != nil || resp.VPNOnline != nil {
		t.Errorf("expected nil fields on empty result, got cpu=%v vpn=%v", resp.CPUPct, resp.VPNOnline)
	}
	// Empty (not error) responses still mean Prometheus is reachable.
	if !resp.PrometheusOK {
		t.Errorf("PrometheusOK = false on empty data, want true")
	}
}

// TestGetInfraNaN — PromQL NaN (e.g. histogram_quantile over an empty range)
// must be treated as no-data, never marshalled (JSON can't encode NaN).
func TestGetInfraNaN(t *testing.T) {
	srv := promMock(t, "nan")
	defer srv.Close()

	code, resp := callGetInfra(t, srv.URL)
	if code != http.StatusOK {
		t.Fatalf("status = %d, want 200", code)
	}
	if resp.LatencyP95MS != nil {
		t.Errorf("LatencyP95MS = %v on NaN, want nil", *resp.LatencyP95MS)
	}
}

// TestGetInfraPrometheusDown — when Prometheus is unreachable the handler
// must still return 200 with PrometheusOK=false and all fields nil, so the
// dashboard never breaks just because monitoring is down.
func TestGetInfraPrometheusDown(t *testing.T) {
	srv := promMock(t, "error")
	defer srv.Close()

	code, resp := callGetInfra(t, srv.URL)
	if code != http.StatusOK {
		t.Fatalf("status = %d, want 200", code)
	}
	if resp.PrometheusOK {
		t.Errorf("PrometheusOK = true, want false when every query errors")
	}
	if resp.CPUPct != nil || resp.LatencyP95MS != nil {
		t.Errorf("expected all-nil fields when Prometheus down")
	}
}
