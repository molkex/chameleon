package cluster

import (
	"context"
	"fmt"
	"net/http"
	"time"
)

// PeerHealth checks if a peer node is reachable by calling its /health endpoint.
// Returns nil if the peer responds with HTTP 200, or an error describing the failure.
// The check has a 5-second timeout regardless of the parent context.
func PeerHealth(ctx context.Context, peerURL string) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	url := peerURL + "/health"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return fmt.Errorf("create request: %w", err)
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("peer %s unreachable: %w", peerURL, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("peer %s returned status %d", peerURL, resp.StatusCode)
	}

	return nil
}
