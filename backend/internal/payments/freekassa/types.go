package freekassa

// PaymentMethod is the numeric id FreeKassa uses to route a payment to a
// specific rail. Only the three we actively support are exported.
type PaymentMethod int

const (
	MethodSBP     PaymentMethod = 44 // QR код (СБП)
	MethodCard    PaymentMethod = 36 // банковские карты РФ
	MethodSberPay PaymentMethod = 43 // SberPay
)

// IsSupported returns true if the method is one of the three we accept.
func (m PaymentMethod) IsSupported() bool {
	switch m {
	case MethodSBP, MethodCard, MethodSberPay:
		return true
	default:
		return false
	}
}

// ParseMethod converts a string like "sbp" / "card" / "sberpay" into the
// numeric FreeKassa method id. Returns ok=false for anything else.
func ParseMethod(s string) (PaymentMethod, bool) {
	switch s {
	case "sbp":
		return MethodSBP, true
	case "card":
		return MethodCard, true
	case "sberpay":
		return MethodSberPay, true
	}
	return 0, false
}

// CreateOrderRequest is the body POSTed to /v1/orders/create. Signature is
// computed from all other fields via APISignature.
type CreateOrderRequest struct {
	ShopID    string        `json:"shopId"`
	Nonce     int64         `json:"nonce"`     // milliseconds, monotonically increasing
	PaymentID string        `json:"paymentId"` // our order id, echoed back in the webhook
	I         PaymentMethod `json:"i"`
	Email     string        `json:"email"`
	IP        string        `json:"ip"`
	Amount    int           `json:"amount"`
	Currency  string        `json:"currency"`
	Signature string        `json:"signature"`
}

// CreateOrderResponse is the relevant subset of the FreeKassa response.
// A successful call returns type="success" and Location holds the redirect URL.
// On error Message describes the problem.
type CreateOrderResponse struct {
	Type     string `json:"type"`
	OrderID  int64  `json:"orderId"`
	Location string `json:"location"`
	Message  string `json:"message,omitempty"`
}

// WebhookPayload mirrors the form fields FreeKassa POSTs to our notification
// URL. Amount is kept as a string because FreeKassa computes the signature
// against the exact value they sent (e.g. "249.00") and any reformatting on
// our side would diverge.
type WebhookPayload struct {
	MerchantID      string `form:"MERCHANT_ID"`
	Amount          string `form:"AMOUNT"`
	MerchantOrderID string `form:"MERCHANT_ORDER_ID"`
	IntID           string `form:"intid"` // FreeKassa internal transaction id
	Sign            string `form:"SIGN"`
	Currency        string `form:"us_currency,omitempty"`
	Email           string `form:"P_EMAIL,omitempty"`
}
