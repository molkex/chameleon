//go:build integration

// announcements_test.go — in-app announcements (INAPP-ANNOUNCEMENTS, migration
// 024): the active-window filter the mobile client depends on + CRUD lifecycle.
// Integration-tagged (testcontainers PG).
//
//	go test -tags=integration ./internal/db/...

package db

import (
	"context"
	"testing"
	"time"
)

func TestAnnouncementsActiveWindowAndCRUD(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()

	live, err := database.CreateAnnouncement(ctx, &Announcement{Title: "live", Body: "b", Kind: "info", Active: true})
	if err != nil {
		t.Fatalf("CreateAnnouncement live: %v", err)
	}
	inactive, err := database.CreateAnnouncement(ctx, &Announcement{Title: "off", Body: "b", Kind: "promo", Active: false})
	if err != nil {
		t.Fatalf("CreateAnnouncement inactive: %v", err)
	}
	future := time.Now().Add(time.Hour)
	if _, err := database.CreateAnnouncement(ctx, &Announcement{Title: "future", Body: "b", Kind: "info", Active: true, StartsAt: &future}); err != nil {
		t.Fatalf("CreateAnnouncement future: %v", err)
	}
	past := time.Now().Add(-time.Hour)
	if _, err := database.CreateAnnouncement(ctx, &Announcement{Title: "expired", Body: "b", Kind: "info", Active: true, EndsAt: &past}); err != nil {
		t.Fatalf("CreateAnnouncement expired: %v", err)
	}

	// Only the active, in-window one is served to the client.
	active, err := database.ActiveAnnouncements(ctx)
	if err != nil {
		t.Fatalf("ActiveAnnouncements: %v", err)
	}
	if len(active) != 1 || active[0].ID != live.ID {
		t.Fatalf("ActiveAnnouncements = %d rows, want only the live one", len(active))
	}

	// Reactivating the inactive one (via update) makes it live too.
	inactive.Active = true
	if _, err := database.UpdateAnnouncement(ctx, inactive); err != nil {
		t.Fatalf("UpdateAnnouncement reactivate: %v", err)
	}
	if a, _ := database.ActiveAnnouncements(ctx); len(a) != 2 {
		t.Errorf("after reactivate: %d active, want 2", len(a))
	}

	// Admin list shows all 4 regardless of active/window.
	if all, _ := database.ListAnnouncements(ctx, 100); len(all) != 4 {
		t.Errorf("ListAnnouncements = %d, want 4", len(all))
	}

	// Delete + the not-found contracts.
	if err := database.DeleteAnnouncement(ctx, live.ID); err != nil {
		t.Fatalf("DeleteAnnouncement: %v", err)
	}
	if err := database.DeleteAnnouncement(ctx, live.ID); err != ErrNotFound {
		t.Errorf("re-delete = %v, want ErrNotFound", err)
	}
	if _, err := database.UpdateAnnouncement(ctx, &Announcement{ID: 999999, Title: "x", Body: "y", Kind: "info"}); err != ErrNotFound {
		t.Errorf("update missing = %v, want ErrNotFound", err)
	}
}

func TestAnnouncementCTAFieldsRoundTrip(t *testing.T) {
	database := startTestDB(t)
	ctx := context.Background()

	label, url := "Открыть", "https://madfrog.online/promo"
	created, err := database.CreateAnnouncement(ctx, &Announcement{
		Title: "promo", Body: "save 50%", Kind: "promo", Active: true,
		CTALabel: &label, CTAURL: &url,
	})
	if err != nil {
		t.Fatalf("CreateAnnouncement: %v", err)
	}
	if created.CTALabel == nil || *created.CTALabel != label || created.CTAURL == nil || *created.CTAURL != url {
		t.Errorf("CTA round-trip mismatch: %+v", created)
	}
}
