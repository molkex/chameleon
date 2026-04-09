// Package vpn provides the User API client for runtime user management
// on sing-box fork with user-api service.
//
// API contract (sing-box fork):
//   POST   /api/v1/inbounds/:tag/users       — add user    {name, uuid, flow}
//   DELETE /api/v1/inbounds/:tag/users/:name  — remove user
//   PUT    /api/v1/inbounds/:tag/users        — bulk replace {users: [...]}
//   GET    /api/v1/inbounds/:tag/users        — list users
package vpn

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

// UserAPIClient communicates with the sing-box User API service.
type UserAPIClient struct {
	baseURL    string
	secret     string
	inboundTag string
	client     *http.Client
}

// NewUserAPIClient creates a client for the sing-box User API.
func NewUserAPIClient(port int, secret, inboundTag string) *UserAPIClient {
	return &UserAPIClient{
		baseURL:    fmt.Sprintf("http://127.0.0.1:%d", port),
		secret:     secret,
		inboundTag: inboundTag,
		client: &http.Client{
			Timeout: 5 * time.Second,
		},
	}
}

// userAPIUser matches adapter.ManagedUser from the sing-box fork.
type userAPIUser struct {
	Name string `json:"name"`
	UUID string `json:"uuid,omitempty"`
	Flow string `json:"flow,omitempty"`
}

// AddUser adds a single user to the running sing-box instance via API.
func (c *UserAPIClient) AddUser(ctx context.Context, user VPNUser) error {
	body := userAPIUser{
		Name: user.Username,
		UUID: user.UUID,
		Flow: "xtls-rprx-vision",
	}

	data, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("user-api: marshal: %w", err)
	}

	url := fmt.Sprintf("%s/api/v1/inbounds/%s/users", c.baseURL, c.inboundTag)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(data))
	if err != nil {
		return fmt.Errorf("user-api: create request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	c.setAuth(req)

	resp, err := c.client.Do(req)
	if err != nil {
		return fmt.Errorf("user-api: request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusCreated {
		return nil
	}

	return c.readError(resp)
}

// RemoveUser removes a user by name from the running sing-box instance.
func (c *UserAPIClient) RemoveUser(ctx context.Context, username string) error {
	reqURL := fmt.Sprintf("%s/api/v1/inbounds/%s/users/%s", c.baseURL, c.inboundTag, url.PathEscape(username))
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, reqURL, nil)
	if err != nil {
		return fmt.Errorf("user-api: create request: %w", err)
	}
	c.setAuth(req)

	resp, err := c.client.Do(req)
	if err != nil {
		return fmt.Errorf("user-api: request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusOK {
		return nil
	}

	return c.readError(resp)
}

// ReplaceUsers bulk-replaces all users on the inbound.
func (c *UserAPIClient) ReplaceUsers(ctx context.Context, users []VPNUser) error {
	apiUsers := make([]userAPIUser, 0, len(users))
	for _, u := range users {
		apiUsers = append(apiUsers, userAPIUser{
			Name: u.Username,
			UUID: u.UUID,
			Flow: "xtls-rprx-vision",
		})
	}

	body := struct {
		Users []userAPIUser `json:"users"`
	}{Users: apiUsers}

	data, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("user-api: marshal: %w", err)
	}

	url := fmt.Sprintf("%s/api/v1/inbounds/%s/users", c.baseURL, c.inboundTag)
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, url, bytes.NewReader(data))
	if err != nil {
		return fmt.Errorf("user-api: create request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	c.setAuth(req)

	resp, err := c.client.Do(req)
	if err != nil {
		return fmt.Errorf("user-api: request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusOK {
		return nil
	}

	return c.readError(resp)
}

// Health checks if the User API is reachable.
func (c *UserAPIClient) Health(ctx context.Context) error {
	url := fmt.Sprintf("%s/api/v1/inbounds", c.baseURL)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	c.setAuth(req)

	resp, err := c.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusOK {
		return nil
	}
	return fmt.Errorf("user-api: health check returned %d", resp.StatusCode)
}

func (c *UserAPIClient) setAuth(req *http.Request) {
	if c.secret != "" {
		req.Header.Set("Authorization", "Bearer "+c.secret)
	}
}

func (c *UserAPIClient) readError(resp *http.Response) error {
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
	return fmt.Errorf("user-api: %s (status %d)", string(body), resp.StatusCode)
}
