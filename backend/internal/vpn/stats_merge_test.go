package vpn

import (
	"sort"
	"testing"
)

// sortTraffic gives a deterministic order for comparison.
func sortTraffic(ts []UserTraffic) {
	sort.Slice(ts, func(i, j int) bool { return ts[i].Username < ts[j].Username })
}

func TestMergeUserTraffic(t *testing.T) {
	t.Run("single source returns as-is (NL-only hot path)", func(t *testing.T) {
		nl := []UserTraffic{{Username: "alice", Upload: 10, Download: 20}}
		got := MergeUserTraffic(nl)
		// Same backing slice — no allocation on the common path.
		if len(got) != 1 || got[0] != nl[0] {
			t.Fatalf("single-source passthrough broken: %+v", got)
		}
	})

	t.Run("sums overlapping usernames across exits", func(t *testing.T) {
		nl := []UserTraffic{
			{Username: "alice", Upload: 10, Download: 20},
			{Username: "bob", Upload: 5, Download: 0},
		}
		gra := []UserTraffic{
			{Username: "alice", Upload: 100, Download: 200}, // alice also used France
			{Username: "carol", Upload: 7, Download: 8},      // carol only on France
		}
		got := MergeUserTraffic(nl, gra)
		sortTraffic(got)
		want := []UserTraffic{
			{Username: "alice", Upload: 110, Download: 220},
			{Username: "bob", Upload: 5, Download: 0},
			{Username: "carol", Upload: 7, Download: 8},
		}
		if len(got) != len(want) {
			t.Fatalf("len = %d, want %d (%+v)", len(got), len(want), got)
		}
		for i := range want {
			if got[i] != want[i] {
				t.Errorf("merged[%d] = %+v, want %+v", i, got[i], want[i])
			}
		}
	})

	t.Run("handles nil and empty sources", func(t *testing.T) {
		got := MergeUserTraffic(nil, []UserTraffic{}, []UserTraffic{{Username: "x", Upload: 1, Download: 2}})
		if len(got) != 1 || got[0] != (UserTraffic{Username: "x", Upload: 1, Download: 2}) {
			t.Fatalf("nil/empty handling broken: %+v", got)
		}
	})

	t.Run("no sources yields empty, not nil-deref", func(t *testing.T) {
		if got := MergeUserTraffic(); len(got) != 0 {
			t.Fatalf("expected empty, got %+v", got)
		}
	})

	t.Run("three exits sum for the same user", func(t *testing.T) {
		a := []UserTraffic{{Username: "u", Upload: 1, Download: 1}}
		b := []UserTraffic{{Username: "u", Upload: 2, Download: 3}}
		c := []UserTraffic{{Username: "u", Upload: 4, Download: 5}}
		got := MergeUserTraffic(a, b, c)
		if len(got) != 1 || got[0] != (UserTraffic{Username: "u", Upload: 7, Download: 9}) {
			t.Fatalf("three-way sum broken: %+v", got)
		}
	})
}
