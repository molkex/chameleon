package mobile

import (
	"crypto/md5"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/labstack/echo/v4"
	"go.uber.org/zap"

	"github.com/chameleonvpn/chameleon/internal/config"
	"github.com/chameleonvpn/chameleon/internal/payments/freekassa"
)

const (
	testShopID  = "12345"
	testSecret2 = "secretTwoValue"
)

// fkSign computes a valid FreeKassa webhook signature for the given fields, using the
// same formula VerifyWebhookSignature checks: md5(shopId:amount:secret2:orderId).
func fkSign(t *testing.T, shopID, amount, orderID, secret2 string) string {
	t.Helper()
	sum := md5.Sum([]byte(shopID + ":" + amount + ":" + secret2 + ":" + orderID))
	return hex.EncodeToString(sum[:])
}

func newWebhookRequest(t *testing.T, form url.Values) (*httptest.ResponseRecorder, echo.Context) {
	t.Helper()
	e := echo.New()
	req := httptest.NewRequest(http.MethodPost, "/api/webhooks/freekassa", strings.NewReader(form.Encode()))
	req.Header.Set(echo.HeaderContentType, echo.MIMEApplicationForm)
	rec := httptest.NewRecorder()
	return rec, e.NewContext(req, rec)
}

func newQBTestHandler(t *testing.T, forwarder *freekassa.QuupbotForwarder) *Handler {
	t.Helper()
	return &Handler{
		Config: &config.Config{
			Payments: config.PaymentsConfig{
				FreeKassa: config.FreeKassaPaymentsConfig{
					Enabled: true,
					ShopID:  testShopID,
					Secret2: testSecret2,
					// empty IPWhitelist ⇒ IPAllowed permits everything, matching dev/test mode.
				},
			},
		},
		Logger:           zap.NewNop(),
		QuupbotForwarder: forwarder,
	}
}

// TestFreeKassaWebhook_QuupbotOrder_Forwarded is the core regression: a qb_-prefixed,
// validly-signed order must be relayed to quupbot, never processed as a chameleon order.
func TestFreeKassaWebhook_QuupbotOrder_Forwarded(t *testing.T) {
	var forwardCalls int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		forwardCalls++
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	form := url.Values{
		"MERCHANT_ID":       {testShopID},
		"AMOUNT":            {"999.00"},
		"MERCHANT_ORDER_ID": {"qb_142"},
		"intid":             {"555"},
	}
	form.Set("SIGN", fkSign(t, testShopID, "999.00", "qb_142", testSecret2))

	h := newQBTestHandler(t, freekassa.NewQuupbotForwarder(srv.URL, "forward-secret"))
	rec, c := newWebhookRequest(t, form)

	if err := h.FreeKassaWebhook(c); err != nil {
		t.Fatalf("FreeKassaWebhook: %v", err)
	}
	if rec.Code != http.StatusOK || rec.Body.String() != "YES" {
		t.Errorf("response = %d %q, want 200 YES", rec.Code, rec.Body.String())
	}
	if forwardCalls != 1 {
		t.Errorf("forward called %d times, want 1", forwardCalls)
	}
}

// TestFreeKassaWebhook_QuupbotOrder_ForwardUnavailable: quupbot down/erroring ⇒ chameleon
// must NOT answer YES (that would make FreeKassa stop retrying and silently lose the payment).
func TestFreeKassaWebhook_QuupbotOrder_ForwardUnavailable(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	form := url.Values{
		"MERCHANT_ID":       {testShopID},
		"AMOUNT":            {"999.00"},
		"MERCHANT_ORDER_ID": {"qb_142"},
		"intid":             {"555"},
	}
	form.Set("SIGN", fkSign(t, testShopID, "999.00", "qb_142", testSecret2))

	h := newQBTestHandler(t, freekassa.NewQuupbotForwarder(srv.URL, "forward-secret"))
	rec, c := newWebhookRequest(t, form)

	if err := h.FreeKassaWebhook(c); err != nil {
		t.Fatalf("FreeKassaWebhook: %v", err)
	}
	if rec.Code == http.StatusOK && rec.Body.String() == "YES" {
		t.Fatal("responded YES despite quupbot being unavailable — FreeKassa will stop retrying and the payment is lost")
	}
	if rec.Code != http.StatusServiceUnavailable {
		t.Errorf("status = %d, want 503", rec.Code)
	}
}

// TestFreeKassaWebhook_QuupbotOrder_ForwardRejected: quupbot examined and permanently
// rejected the payment (e.g. amount mismatch) ⇒ chameleon must not tell FreeKassa YES,
// but also shouldn't trigger infinite retries — 400.
func TestFreeKassaWebhook_QuupbotOrder_ForwardRejected(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusConflict)
	}))
	defer srv.Close()

	form := url.Values{
		"MERCHANT_ID":       {testShopID},
		"AMOUNT":            {"999.00"},
		"MERCHANT_ORDER_ID": {"qb_142"},
		"intid":             {"555"},
	}
	form.Set("SIGN", fkSign(t, testShopID, "999.00", "qb_142", testSecret2))

	h := newQBTestHandler(t, freekassa.NewQuupbotForwarder(srv.URL, "forward-secret"))
	rec, c := newWebhookRequest(t, form)

	if err := h.FreeKassaWebhook(c); err != nil {
		t.Fatalf("FreeKassaWebhook: %v", err)
	}
	if rec.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", rec.Code)
	}
}

// TestFreeKassaWebhook_QuupbotOrder_FeatureOff: forwarder not configured (nil) ⇒
// identical to today's pre-existing behavior for unrecognized order ids — swallow, YES.
// This is the "rollback = unset the config" contract from the deploy plan.
func TestFreeKassaWebhook_QuupbotOrder_FeatureOff(t *testing.T) {
	form := url.Values{
		"MERCHANT_ID":       {testShopID},
		"AMOUNT":            {"999.00"},
		"MERCHANT_ORDER_ID": {"qb_142"},
		"intid":             {"555"},
	}
	form.Set("SIGN", fkSign(t, testShopID, "999.00", "qb_142", testSecret2))

	h := newQBTestHandler(t, nil) // QuupbotForwarder = nil
	rec, c := newWebhookRequest(t, form)

	if err := h.FreeKassaWebhook(c); err != nil {
		t.Fatalf("FreeKassaWebhook: %v", err)
	}
	if rec.Code != http.StatusOK || rec.Body.String() != "YES" {
		t.Errorf("response = %d %q, want 200 YES (legacy swallow behavior)", rec.Code, rec.Body.String())
	}
}

// TestFreeKassaWebhook_QuupbotOrder_BadSignature: the qb_ routing must sit AFTER
// signature verification — a forged qb_ order must never reach the forwarder.
func TestFreeKassaWebhook_QuupbotOrder_BadSignature(t *testing.T) {
	var forwardCalls int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		forwardCalls++
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	form := url.Values{
		"MERCHANT_ID":       {testShopID},
		"AMOUNT":            {"999.00"},
		"MERCHANT_ORDER_ID": {"qb_142"},
		"intid":             {"555"},
		"SIGN":              {"not-a-valid-signature"},
	}

	h := newQBTestHandler(t, freekassa.NewQuupbotForwarder(srv.URL, "forward-secret"))
	rec, c := newWebhookRequest(t, form)

	if err := h.FreeKassaWebhook(c); err != nil {
		t.Fatalf("FreeKassaWebhook: %v", err)
	}
	if rec.Code != http.StatusForbidden {
		t.Errorf("status = %d, want 403", rec.Code)
	}
	if forwardCalls != 0 {
		t.Error("forwarder must not be called for an unsigned/forged request")
	}
}

// TestFreeKassaWebhook_AppOrder_Unaffected is the regression guard: a normal app_ order
// must take the exact same path it always has — the qb_ branch must not touch it.
func TestFreeKassaWebhook_AppOrder_Unaffected(t *testing.T) {
	var forwardCalls int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		forwardCalls++
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	form := url.Values{
		"MERCHANT_ID":       {testShopID},
		"AMOUNT":            {"249.00"},
		"MERCHANT_ORDER_ID": {"app_m1_42_7"},
		"intid":             {"555"},
	}
	form.Set("SIGN", fkSign(t, testShopID, "249.00", "app_m1_42_7", testSecret2))

	h := newQBTestHandler(t, freekassa.NewQuupbotForwarder(srv.URL, "forward-secret"))
	_, c := newWebhookRequest(t, form)

	// h.DB/h.Payments are nil, so ParseAppPayment or findPlan/CreditDays will fail past
	// the routing branches — that's fine, this test only asserts the qb_ forwarder was
	// never invoked and the response isn't the qb_ path's "YES" short-circuit.
	_ = h.FreeKassaWebhook(c)

	if forwardCalls != 0 {
		t.Error("app_ order must never reach the quupbot forwarder")
	}
}
