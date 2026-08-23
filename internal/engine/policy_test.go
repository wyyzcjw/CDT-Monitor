package engine

import (
	"testing"
	"time"
)

func TestDueWithinSupportsLateScheduler(t *testing.T) {
	location := time.FixedZone("CST", 8*3600)
	now := time.Date(2026, 7, 19, 8, 7, 0, 0, location)
	if !dueWithin(now, "08:00", 10*time.Minute) {
		t.Fatal("expected delayed scheduler to compensate")
	}
	if dueWithin(now, "07:50", 10*time.Minute) {
		t.Fatal("must not compensate outside the window")
	}
	if !dueWithin(now, "08:00:00", 10*time.Minute) {
		t.Fatal("expected HH:MM:SS clock values to parse")
	}
}

func TestParseClock(t *testing.T) {
	hour, minute, ok := parseClock("08:30")
	if !ok || hour != 8 || minute != 30 {
		t.Fatalf("08:30 => %d:%02d ok=%v", hour, minute, ok)
	}
	hour, minute, ok = parseClock("22:00:00")
	if !ok || hour != 22 || minute != 0 {
		t.Fatalf("22:00:00 => %d:%02d ok=%v", hour, minute, ok)
	}
	if _, _, ok = parseClock("25:00"); ok {
		t.Fatal("invalid clock must not parse")
	}
	hour, minute = dailyReportClock("")
	if hour != 0 || minute != 0 {
		t.Fatalf("empty clock should fall back to midnight, got %d:%02d", hour, minute)
	}
}

func TestInTimeRangeAcrossMidnight(t *testing.T) {
	if !inTimeRange("23:30", "22:00", "06:00") || !inTimeRange("05:59", "22:00", "06:00") {
		t.Fatal("cross-midnight window should include night times")
	}
	if inTimeRange("12:00", "22:00", "06:00") {
		t.Fatal("cross-midnight window must exclude midday")
	}
}

func TestUsagePercent(t *testing.T) {
	if value := usagePercent(95, 200); value != 47.5 {
		t.Fatalf("got %v", value)
	}
	if value := usagePercent(1, 0); value != 0 {
		t.Fatalf("zero quota got %v", value)
	}
}
