// ascinit is an App Store Connect bootstrapping utility for Chameleon/MadFrog.
//
// It talks to the App Store Connect API to audit and configure developer
// portal state (App IDs, capabilities, App Groups) and later App Store Connect
// IAP products. Credentials come from environment variables so the private key
// never lands in the repo or a config file:
//
//	ASC_KEY_ID      — key id (e.g. 6HX3DA4P2Y)
//	ASC_ISSUER_ID   — issuer id (UUID)
//	ASC_KEY_PATH    — path to AuthKey_<KEY_ID>.p8
//
// Subcommands:
//
//	audit-portal   — read-only dump of bundle ids, their capabilities, and app groups
//	sync-portal    — create missing bundle ids/app groups and enable required capabilities
package main

import (
	"bytes"
	"crypto/md5"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"image"
	"image/png"
	"io"
	"net/http"
	"os"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	ascBaseURL = "https://api.appstoreconnect.apple.com"
	ascAud     = "appstoreconnect-v1"
)

// Target bundle identifiers and the App Group we want to exist.
const (
	appBundleID    = "com.madfrog.vpn"
	tunnelBundleID = "com.madfrog.vpn.tunnel"
	appGroupID     = "group.com.madfrog.vpn"
)

// ascAppIDEnv holds the App Store Connect internal app id (e.g. 6761008632).
// Used for IAP operations that scope by /v1/apps/{id}/...
const ascAppIDEnv = "ASC_APP_ID"

// iapProduct describes one non-renewing subscription tier we want in ASC.
type iapProduct struct {
	ProductID   string // Apple product id
	Name        string // internal reference name
	Days        int    // duration — used in localizations
	PriceUSD    string // base USD price for the schedule (not yet wired)
	Description map[string]string
	DisplayName map[string]string
}

var iapCatalog = []iapProduct{
	{
		ProductID: "com.madfrog.vpn.sub.30days",
		Name:      "MadFrog VPN 30 days",
		Days:      30,
		PriceUSD:  "1.99",
		DisplayName: map[string]string{
			"en-US": "30 days",
			"ru":    "30 дней",
		},
		Description: map[string]string{
			"en-US": "Unlimited VPN access for 30 days",
			"ru":    "Безлимитный VPN на 30 дней",
		},
	},
	{
		ProductID: "com.madfrog.vpn.sub.90days",
		Name:      "MadFrog VPN 90 days",
		Days:      90,
		PriceUSD:  "4.99",
		DisplayName: map[string]string{
			"en-US": "90 days",
			"ru":    "90 дней",
		},
		Description: map[string]string{
			"en-US": "Unlimited VPN access for 90 days",
			"ru":    "Безлимитный VPN на 90 дней",
		},
	},
	{
		ProductID: "com.madfrog.vpn.sub.180days",
		Name:      "MadFrog VPN 180 days",
		Days:      180,
		PriceUSD:  "8.99",
		DisplayName: map[string]string{
			"en-US": "180 days",
			"ru":    "180 дней",
		},
		Description: map[string]string{
			"en-US": "Unlimited VPN access for 180 days",
			"ru":    "Безлимитный VPN на 180 дней",
		},
	},
	{
		ProductID: "com.madfrog.vpn.sub.365days",
		Name:      "MadFrog VPN 365 days",
		Days:      365,
		PriceUSD:  "15.99",
		DisplayName: map[string]string{
			"en-US": "365 days",
			"ru":    "365 дней",
		},
		Description: map[string]string{
			"en-US": "Unlimited VPN access for 365 days",
			"ru":    "Безлимитный VPN на 365 дней",
		},
	},
}

// Capability types used in ASC API (see CapabilityType enum).
const (
	capAppGroups        = "APP_GROUPS"
	capNetworkExtension = "NETWORK_EXTENSIONS"
	capSignInWithApple  = "APPLE_ID_AUTH"
)

// desired maps bundleId → capability types that must be enabled.
var desired = map[string][]string{
	appBundleID:    {capAppGroups, capNetworkExtension, capSignInWithApple},
	tunnelBundleID: {capAppGroups, capNetworkExtension},
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	cmd := os.Args[1]

	client, err := newClient()
	if err != nil {
		die("init: %v", err)
	}

	switch cmd {
	case "audit-portal":
		if err := auditPortal(client); err != nil {
			die("audit-portal: %v", err)
		}
	case "sync-portal":
		if err := syncPortal(client); err != nil {
			die("sync-portal: %v", err)
		}
	case "audit-iap":
		if err := auditIAP(client); err != nil {
			die("audit-iap: %v", err)
		}
	case "sync-iap":
		if err := syncIAP(client); err != nil {
			die("sync-iap: %v", err)
		}
	case "sync-iap-prices":
		if err := syncIAPPrices(client); err != nil {
			die("sync-iap-prices: %v", err)
		}
	case "sync-iap-availability":
		if err := syncIAPAvailability(client); err != nil {
			die("sync-iap-availability: %v", err)
		}
	case "sync-iap-screenshots":
		if err := syncIAPScreenshots(client); err != nil {
			die("sync-iap-screenshots: %v", err)
		}
	case "raw":
		if len(os.Args) < 3 {
			die("usage: raw <path>")
		}
		var out map[string]any
		if err := client.do("GET", os.Args[2], nil, &out); err != nil {
			die("raw: %v", err)
		}
		b, _ := json.MarshalIndent(out, "", "  ")
		fmt.Println(string(b))
	case "device-add":
		if len(os.Args) < 4 {
			die("usage: device-add <name> <udid>")
		}
		if err := addDevice(client, os.Args[2], os.Args[3]); err != nil {
			die("device-add: %v", err)
		}
	case "beta-add":
		if len(os.Args) < 4 {
			die("usage: beta-add <betaGroupID> <buildID>")
		}
		groupID := os.Args[2]
		buildID := os.Args[3]
		body := map[string]any{
			"data": []map[string]any{
				{"type": "builds", "id": buildID},
			},
		}
		if err := client.do("POST", "/v1/betaGroups/"+groupID+"/relationships/builds", body, nil); err != nil {
			die("beta-add: %v", err)
		}
		fmt.Println("added build", buildID, "to group", groupID)
	default:
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintf(os.Stderr, `ascinit — Chameleon/MadFrog App Store Connect bootstrap

Env:
  ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH

Commands:
  audit-portal   Read bundle ids, capabilities, and app groups (no changes)
  sync-portal    Create missing bundle ids/app groups and enable capabilities
  audit-iap      Read existing in-app purchase products (no changes)
  sync-iap       Create missing non-renewing subscription products + localizations
  sync-iap-prices  Attach USD price schedules (base territory USA) to all IAPs
`)
}

func die(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "ascinit: "+format+"\n", args...)
	os.Exit(1)
}

// ----------------------------------------------------------------------------
// ASC API client
// ----------------------------------------------------------------------------

type client struct {
	http     *http.Client
	keyID    string
	issuerID string
	keyPEM   []byte
}

func newClient() (*client, error) {
	keyID := os.Getenv("ASC_KEY_ID")
	issuerID := os.Getenv("ASC_ISSUER_ID")
	keyPath := os.Getenv("ASC_KEY_PATH")
	if keyID == "" || issuerID == "" || keyPath == "" {
		return nil, errors.New("ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH must be set")
	}
	keyPEM, err := os.ReadFile(keyPath)
	if err != nil {
		return nil, fmt.Errorf("read key: %w", err)
	}
	return &client{
		http:     &http.Client{Timeout: 30 * time.Second},
		keyID:    keyID,
		issuerID: issuerID,
		keyPEM:   keyPEM,
	}, nil
}

func (c *client) token() (string, error) {
	block, _ := pem.Decode(c.keyPEM)
	if block == nil {
		return "", errors.New("invalid PEM in ASC key")
	}
	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return "", fmt.Errorf("parse pkcs8: %w", err)
	}
	claims := jwt.MapClaims{
		"iss": c.issuerID,
		"iat": time.Now().Unix(),
		"exp": time.Now().Add(19 * time.Minute).Unix(),
		"aud": ascAud,
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodES256, claims)
	tok.Header["kid"] = c.keyID
	return tok.SignedString(key)
}

func (c *client) do(method, path string, body any, out any) error {
	tok, err := c.token()
	if err != nil {
		return err
	}
	var reqBody io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reqBody = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, ascBaseURL+path, reqBody)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 300 {
		return fmt.Errorf("%s %s: HTTP %d: %s", method, path, resp.StatusCode, string(raw))
	}
	if out != nil && len(raw) > 0 {
		if err := json.Unmarshal(raw, out); err != nil {
			return fmt.Errorf("decode %s: %w", path, err)
		}
	}
	return nil
}

// ----------------------------------------------------------------------------
// Types — only the fields we care about
// ----------------------------------------------------------------------------

type bundleIDResource struct {
	ID         string `json:"id"`
	Attributes struct {
		Identifier string `json:"identifier"`
		Name       string `json:"name"`
		Platform   string `json:"platform"`
	} `json:"attributes"`
}

type bundleIDListResp struct {
	Data []bundleIDResource `json:"data"`
}

type capabilityResource struct {
	ID         string `json:"id"`
	Attributes struct {
		CapabilityType string `json:"capabilityType"`
	} `json:"attributes"`
}

type capabilityListResp struct {
	Data []capabilityResource `json:"data"`
}

// ----------------------------------------------------------------------------
// audit-portal
// ----------------------------------------------------------------------------

func auditPortal(c *client) error {
	fmt.Println("=== Bundle IDs ===")
	for _, id := range []string{appBundleID, tunnelBundleID} {
		b, err := c.findBundleID(id)
		if err != nil {
			return err
		}
		if b == nil {
			fmt.Printf("  %-30s  MISSING\n", id)
			continue
		}
		caps, err := c.listCapabilities(b.ID)
		if err != nil {
			return fmt.Errorf("list capabilities for %s: %w", id, err)
		}
		names := make([]string, 0, len(caps))
		for _, cap := range caps {
			names = append(names, cap.Attributes.CapabilityType)
		}
		fmt.Printf("  %-30s  ok  platform=%s  caps=%v\n", id, b.Attributes.Platform, names)

		missing := missingCaps(desired[id], names)
		if len(missing) > 0 {
			fmt.Printf("      → MISSING CAPS: %v\n", missing)
		}
	}

	fmt.Println()
	fmt.Println("=== App Groups ===")
	fmt.Printf("  %s  — not queryable via public ASC API\n", appGroupID)
	fmt.Println("  (Xcode automatic signing will create it on first build if missing)")
	return nil
}

// ----------------------------------------------------------------------------
// sync-portal (stub — will be filled once audit shows current state)
// ----------------------------------------------------------------------------

func syncPortal(c *client) error {
	return errors.New("sync-portal not yet implemented — run audit-portal first and share output")
}

// ----------------------------------------------------------------------------
// helpers
// ----------------------------------------------------------------------------

func (c *client) findBundleID(identifier string) (*bundleIDResource, error) {
	var resp bundleIDListResp
	path := fmt.Sprintf("/v1/bundleIds?filter[identifier]=%s&limit=200", identifier)
	if err := c.do("GET", path, nil, &resp); err != nil {
		return nil, err
	}
	for i := range resp.Data {
		if resp.Data[i].Attributes.Identifier == identifier {
			return &resp.Data[i], nil
		}
	}
	return nil, nil
}

func (c *client) listCapabilities(bundleIDResourceID string) ([]capabilityResource, error) {
	var resp capabilityListResp
	path := fmt.Sprintf("/v1/bundleIds/%s/bundleIdCapabilities", bundleIDResourceID)
	if err := c.do("GET", path, nil, &resp); err != nil {
		return nil, err
	}
	return resp.Data, nil
}

// ----------------------------------------------------------------------------
// audit-iap / sync-iap
// ----------------------------------------------------------------------------

type iapResource struct {
	ID         string `json:"id"`
	Attributes struct {
		Name               string `json:"name"`
		ProductID          string `json:"productId"`
		InAppPurchaseType  string `json:"inAppPurchaseType"`
		State              string `json:"state"`
		ReviewNote         string `json:"reviewNote"`
		FamilySharable     bool   `json:"familySharable"`
		ContentHosting     bool   `json:"contentHosting"`
	} `json:"attributes"`
}

type iapListResp struct {
	Data []iapResource `json:"data"`
	Links struct {
		Next string `json:"next"`
	} `json:"links"`
}

type iapCreateReq struct {
	Data struct {
		Type       string `json:"type"`
		Attributes struct {
			Name              string `json:"name"`
			ProductID         string `json:"productId"`
			InAppPurchaseType string `json:"inAppPurchaseType"`
		} `json:"attributes"`
		Relationships struct {
			App struct {
				Data struct {
					Type string `json:"type"`
					ID   string `json:"id"`
				} `json:"data"`
			} `json:"app"`
		} `json:"relationships"`
	} `json:"data"`
}

type iapCreateResp struct {
	Data iapResource `json:"data"`
}

type iapLocalizationCreateReq struct {
	Data struct {
		Type       string `json:"type"`
		Attributes struct {
			Locale      string `json:"locale"`
			Name        string `json:"name"`
			Description string `json:"description"`
		} `json:"attributes"`
		Relationships struct {
			InAppPurchaseV2 struct {
				Data struct {
					Type string `json:"type"`
					ID   string `json:"id"`
				} `json:"data"`
			} `json:"inAppPurchaseV2"`
		} `json:"relationships"`
	} `json:"data"`
}

func ascAppID() (string, error) {
	id := os.Getenv(ascAppIDEnv)
	if id == "" {
		return "", fmt.Errorf("%s must be set (ASC app internal id, e.g. 6761008632)", ascAppIDEnv)
	}
	return id, nil
}

func (c *client) listIAPs(appID string) ([]iapResource, error) {
	var out []iapResource
	path := fmt.Sprintf("/v1/apps/%s/inAppPurchasesV2?limit=200", appID)
	for path != "" {
		var resp iapListResp
		if err := c.do("GET", path, nil, &resp); err != nil {
			return nil, err
		}
		out = append(out, resp.Data...)
		if resp.Links.Next == "" {
			break
		}
		// Next is a full URL; trim base.
		if len(resp.Links.Next) > len(ascBaseURL) && resp.Links.Next[:len(ascBaseURL)] == ascBaseURL {
			path = resp.Links.Next[len(ascBaseURL):]
		} else {
			break
		}
	}
	return out, nil
}

func (c *client) createIAP(appID string, p iapProduct) (*iapResource, error) {
	var req iapCreateReq
	req.Data.Type = "inAppPurchases"
	req.Data.Attributes.Name = p.Name
	req.Data.Attributes.ProductID = p.ProductID
	req.Data.Attributes.InAppPurchaseType = "NON_RENEWING_SUBSCRIPTION"
	req.Data.Relationships.App.Data.Type = "apps"
	req.Data.Relationships.App.Data.ID = appID

	var resp iapCreateResp
	if err := c.do("POST", "/v2/inAppPurchases", req, &resp); err != nil {
		return nil, err
	}
	return &resp.Data, nil
}

func (c *client) addIAPLocalization(iapID, locale, name, description string) error {
	var req iapLocalizationCreateReq
	req.Data.Type = "inAppPurchaseLocalizations"
	req.Data.Attributes.Locale = locale
	req.Data.Attributes.Name = name
	req.Data.Attributes.Description = description
	req.Data.Relationships.InAppPurchaseV2.Data.Type = "inAppPurchases"
	req.Data.Relationships.InAppPurchaseV2.Data.ID = iapID
	return c.do("POST", "/v1/inAppPurchaseLocalizations", req, nil)
}

func auditIAP(c *client) error {
	appID, err := ascAppID()
	if err != nil {
		return err
	}
	existing, err := c.listIAPs(appID)
	if err != nil {
		return err
	}
	byProductID := make(map[string]iapResource, len(existing))
	for _, r := range existing {
		byProductID[r.Attributes.ProductID] = r
	}
	fmt.Printf("=== In-App Purchases (app %s) ===\n", appID)
	fmt.Printf("  total existing: %d\n\n", len(existing))
	for _, want := range iapCatalog {
		if r, ok := byProductID[want.ProductID]; ok {
			fmt.Printf("  %-30s  ok  type=%s  state=%s  name=%q\n",
				want.ProductID, r.Attributes.InAppPurchaseType, r.Attributes.State, r.Attributes.Name)
		} else {
			fmt.Printf("  %-30s  MISSING\n", want.ProductID)
		}
	}
	return nil
}

func syncIAP(c *client) error {
	appID, err := ascAppID()
	if err != nil {
		return err
	}
	existing, err := c.listIAPs(appID)
	if err != nil {
		return err
	}
	byProductID := make(map[string]iapResource, len(existing))
	for _, r := range existing {
		byProductID[r.Attributes.ProductID] = r
	}
	for _, want := range iapCatalog {
		if r, ok := byProductID[want.ProductID]; ok {
			fmt.Printf("  %-30s  exists (id=%s, state=%s) — skipping create\n",
				want.ProductID, r.ID, r.Attributes.State)
			continue
		}
		fmt.Printf("  %-30s  creating...\n", want.ProductID)
		created, err := c.createIAP(appID, want)
		if err != nil {
			return fmt.Errorf("create %s: %w", want.ProductID, err)
		}
		fmt.Printf("      → created id=%s\n", created.ID)

		for locale, name := range want.DisplayName {
			desc := want.Description[locale]
			if err := c.addIAPLocalization(created.ID, locale, name, desc); err != nil {
				return fmt.Errorf("localize %s (%s): %w", want.ProductID, locale, err)
			}
			fmt.Printf("      → localization %s ok\n", locale)
		}
	}
	fmt.Println()
	fmt.Println("NOTE: products created without prices — run `sync-iap-prices` next.")
	return nil
}

// ---- Price scheduling --------------------------------------------------------

type pricePointResource struct {
	ID         string `json:"id"`
	Attributes struct {
		CustomerPrice string `json:"customerPrice"`
		Proceeds      string `json:"proceeds"`
	} `json:"attributes"`
}

type pricePointListResp struct {
	Data []pricePointResource `json:"data"`
	Links struct {
		Next string `json:"next"`
	} `json:"links"`
}

// findUSAPricePoint walks paginated /v2/inAppPurchases/{id}/pricePoints?filter[territory]=USA
// and returns the id of the point whose customerPrice matches targetUSD (e.g. "1.99").
func (c *client) findUSAPricePoint(iapID, targetUSD string) (string, error) {
	path := fmt.Sprintf("/v2/inAppPurchases/%s/pricePoints?filter[territory]=USA&limit=200", iapID)
	for path != "" {
		var resp pricePointListResp
		if err := c.do("GET", path, nil, &resp); err != nil {
			return "", err
		}
		for _, p := range resp.Data {
			if p.Attributes.CustomerPrice == targetUSD {
				return p.ID, nil
			}
		}
		if resp.Links.Next == "" {
			break
		}
		if len(resp.Links.Next) > len(ascBaseURL) && resp.Links.Next[:len(ascBaseURL)] == ascBaseURL {
			path = resp.Links.Next[len(ascBaseURL):]
		} else {
			break
		}
	}
	return "", fmt.Errorf("no USA price point found for $%s on iap %s", targetUSD, iapID)
}

// createPriceSchedule attaches a single-manual-price schedule (effective immediately)
// to iapID using the given USA price point. Uses the JSON:API "included" convention
// with a placeholder id so Apple resolves the manualPrice before storing it.
func (c *client) createPriceSchedule(iapID, pricePointID string) error {
	// iapPriceSchedule is a 1:1 child of an in-app purchase and uses the IAP id
	// as its own id. Resource type in the JSON:API wire format is
	// "inAppPurchasePriceSchedules" (plural) — the relationship just aliases it.
	body := map[string]any{
		"data": map[string]any{
			"type": "inAppPurchasePriceSchedules",
			"relationships": map[string]any{
				"inAppPurchase": map[string]any{
					"data": map[string]any{"type": "inAppPurchases", "id": iapID},
				},
				"baseTerritory": map[string]any{
					"data": map[string]any{"type": "territories", "id": "USA"},
				},
				"manualPrices": map[string]any{
					"data": []any{
						map[string]any{"type": "inAppPurchasePrices", "id": "${price1}"},
					},
				},
			},
		},
		"included": []any{
			map[string]any{
				"type": "inAppPurchasePrices",
				"id":   "${price1}",
				"attributes": map[string]any{
					"startDate": nil,
				},
				"relationships": map[string]any{
					"inAppPurchasePricePoint": map[string]any{
						"data": map[string]any{"type": "inAppPurchasePricePoints", "id": pricePointID},
					},
				},
			},
		},
	}
	return c.do("POST", "/v1/inAppPurchasePriceSchedules", body, nil)
}

// createAvailability marks an IAP as available in all territories fetched from
// /v1/territories + auto-enrolled in future territories. This is a 1:1 child
// resource; POST replaces the existing availability.
func (c *client) createAvailability(iapID string) error {
	var terrResp struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if err := c.do("GET", "/v1/territories?limit=200", nil, &terrResp); err != nil {
		return fmt.Errorf("list territories: %w", err)
	}
	territories := make([]any, 0, len(terrResp.Data))
	for _, t := range terrResp.Data {
		territories = append(territories, map[string]any{"type": "territories", "id": t.ID})
	}
	body := map[string]any{
		"data": map[string]any{
			"type": "inAppPurchaseAvailabilities",
			"attributes": map[string]any{
				"availableInNewTerritories": true,
			},
			"relationships": map[string]any{
				"inAppPurchase": map[string]any{
					"data": map[string]any{"type": "inAppPurchases", "id": iapID},
				},
				"availableTerritories": map[string]any{
					"data": territories,
				},
			},
		},
	}
	return c.do("POST", "/v1/inAppPurchaseAvailabilities", body, nil)
}

func syncIAPAvailability(c *client) error {
	appID, err := ascAppID()
	if err != nil {
		return err
	}
	existing, err := c.listIAPs(appID)
	if err != nil {
		return err
	}
	byProductID := make(map[string]iapResource, len(existing))
	for _, r := range existing {
		byProductID[r.Attributes.ProductID] = r
	}
	for _, want := range iapCatalog {
		r, ok := byProductID[want.ProductID]
		if !ok {
			fmt.Printf("  %-30s  skipped (not yet created)\n", want.ProductID)
			continue
		}
		fmt.Printf("  %-30s  setting availability (USA + future territories)...\n", want.ProductID)
		if err := c.createAvailability(r.ID); err != nil {
			return fmt.Errorf("availability for %s: %w", want.ProductID, err)
		}
		fmt.Printf("      → ok\n")
	}
	return nil
}

func syncIAPPrices(c *client) error {
	appID, err := ascAppID()
	if err != nil {
		return err
	}
	existing, err := c.listIAPs(appID)
	if err != nil {
		return err
	}
	byProductID := make(map[string]iapResource, len(existing))
	for _, r := range existing {
		byProductID[r.Attributes.ProductID] = r
	}
	for _, want := range iapCatalog {
		r, ok := byProductID[want.ProductID]
		if !ok {
			fmt.Printf("  %-30s  skipped (not yet created)\n", want.ProductID)
			continue
		}
		fmt.Printf("  %-30s  looking up USA pricePoint for $%s...\n", want.ProductID, want.PriceUSD)
		pp, err := c.findUSAPricePoint(r.ID, want.PriceUSD)
		if err != nil {
			return err
		}
		fmt.Printf("      → pricePoint id=%s\n", pp)
		if err := c.createPriceSchedule(r.ID, pp); err != nil {
			return fmt.Errorf("create schedule for %s: %w", want.ProductID, err)
		}
		fmt.Printf("      → price schedule attached\n")
	}
	return nil
}

// ----------------------------------------------------------------------------
// Review screenshot upload (multi-step flow)
// ----------------------------------------------------------------------------

// generateBlackPNG returns an opaque black PNG of the given dimensions — used
// as a placeholder review screenshot to satisfy Apple's metadata requirements.
// 1242x2688 matches iPhone 11 Pro Max (6.5").
func generateBlackPNG(w, h int) []byte {
	img := image.NewNRGBA(image.Rect(0, 0, w, h))
	for i := 3; i < len(img.Pix); i += 4 {
		img.Pix[i] = 255 // alpha = opaque; R/G/B stay 0 → black
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		panic(err) // only fails on io.Writer errors; bytes.Buffer never errors
	}
	return buf.Bytes()
}

type uploadOperation struct {
	Method         string `json:"method"`
	URL            string `json:"url"`
	Length         int    `json:"length"`
	Offset         int    `json:"offset"`
	RequestHeaders []struct {
		Name  string `json:"name"`
		Value string `json:"value"`
	} `json:"requestHeaders"`
}

type screenshotCreateResp struct {
	Data struct {
		ID         string `json:"id"`
		Attributes struct {
			UploadOperations []uploadOperation `json:"uploadOperations"`
		} `json:"attributes"`
	} `json:"data"`
}

// reserveScreenshot creates the screenshot resource with file metadata and
// returns the resource id + the list of upload operations Apple wants us to PUT.
func (c *client) reserveScreenshot(iapID string, fileName string, fileSize int) (*screenshotCreateResp, error) {
	body := map[string]any{
		"data": map[string]any{
			"type": "inAppPurchaseAppStoreReviewScreenshots",
			"attributes": map[string]any{
				"fileName": fileName,
				"fileSize": fileSize,
			},
			"relationships": map[string]any{
				"inAppPurchaseV2": map[string]any{
					"data": map[string]any{"type": "inAppPurchases", "id": iapID},
				},
			},
		},
	}
	var resp screenshotCreateResp
	if err := c.do("POST", "/v1/inAppPurchaseAppStoreReviewScreenshots", body, &resp); err != nil {
		return nil, err
	}
	return &resp, nil
}

// uploadChunks performs the raw PUTs described by Apple's uploadOperations.
// Each operation carries its own URL + headers; we don't use the JWT here.
func (c *client) uploadChunks(data []byte, ops []uploadOperation) error {
	for _, op := range ops {
		chunk := data[op.Offset : op.Offset+op.Length]
		req, err := http.NewRequest(op.Method, op.URL, bytes.NewReader(chunk))
		if err != nil {
			return err
		}
		for _, h := range op.RequestHeaders {
			req.Header.Set(h.Name, h.Value)
		}
		req.ContentLength = int64(len(chunk))
		resp, err := c.http.Do(req)
		if err != nil {
			return err
		}
		raw, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode >= 300 {
			return fmt.Errorf("upload chunk: HTTP %d: %s", resp.StatusCode, string(raw))
		}
	}
	return nil
}

// commitScreenshot tells Apple the upload is finished and hands over the md5
// of the full file so Apple can verify integrity.
func (c *client) commitScreenshot(screenshotID string, md5hex string) error {
	body := map[string]any{
		"data": map[string]any{
			"type": "inAppPurchaseAppStoreReviewScreenshots",
			"id":   screenshotID,
			"attributes": map[string]any{
				"uploaded":           true,
				"sourceFileChecksum": md5hex,
			},
		},
	}
	return c.do("PATCH", "/v1/inAppPurchaseAppStoreReviewScreenshots/"+screenshotID, body, nil)
}

func syncIAPScreenshots(c *client) error {
	appID, err := ascAppID()
	if err != nil {
		return err
	}
	existing, err := c.listIAPs(appID)
	if err != nil {
		return err
	}
	byProductID := make(map[string]iapResource, len(existing))
	for _, r := range existing {
		byProductID[r.Attributes.ProductID] = r
	}

	img := generateBlackPNG(1242, 2688)
	sum := md5.Sum(img)
	md5hex := hex.EncodeToString(sum[:])
	fmt.Printf("  generated placeholder screenshot: 1242x2688 PNG, %d bytes, md5=%s\n\n",
		len(img), md5hex)

	for _, want := range iapCatalog {
		r, ok := byProductID[want.ProductID]
		if !ok {
			fmt.Printf("  %-30s  skipped (not yet created)\n", want.ProductID)
			continue
		}
		fmt.Printf("  %-30s  reserving screenshot...\n", want.ProductID)
		res, err := c.reserveScreenshot(r.ID, "review.png", len(img))
		if err != nil {
			return fmt.Errorf("reserve %s: %w", want.ProductID, err)
		}
		fmt.Printf("      → id=%s  ops=%d\n", res.Data.ID, len(res.Data.Attributes.UploadOperations))
		if err := c.uploadChunks(img, res.Data.Attributes.UploadOperations); err != nil {
			return fmt.Errorf("upload %s: %w", want.ProductID, err)
		}
		fmt.Printf("      → bytes uploaded\n")
		if err := c.commitScreenshot(res.Data.ID, md5hex); err != nil {
			return fmt.Errorf("commit %s: %w", want.ProductID, err)
		}
		fmt.Printf("      → committed\n")
	}
	return nil
}

func addDevice(c *client, name, udid string) error {
	body := map[string]any{
		"data": map[string]any{
			"type": "devices",
			"attributes": map[string]any{
				"name":     name,
				"udid":     udid,
				"platform": "IOS",
			},
		},
	}
	var resp map[string]any
	if err := c.do("POST", "/v1/devices", body, &resp); err != nil {
		return err
	}
	b, _ := json.MarshalIndent(resp, "", "  ")
	fmt.Println(string(b))
	return nil
}

func missingCaps(want, have []string) []string {
	set := make(map[string]bool, len(have))
	for _, h := range have {
		set[h] = true
	}
	var out []string
	for _, w := range want {
		if !set[w] {
			out = append(out, w)
		}
	}
	return out
}
