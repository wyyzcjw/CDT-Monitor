package engine

import (
	"context"
	"errors"
	"log/slog"
	"testing"
	"time"

	"github.com/wang4386/CDT-Monitor/internal/domain"
	"github.com/wang4386/CDT-Monitor/internal/notify"
	"github.com/wang4386/CDT-Monitor/internal/store"
)

func setupDailyReportEngine(t *testing.T, timezone, reportTime string) (*Engine, *store.Store) {
	t.Helper()
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	config := domain.Config{
		AdminPassword:    "Strong-Password-42!",
		TrafficThreshold: 95,
		ShutdownMode:     "KeepCharging",
		ThresholdAction:  "stop_and_notify",
		APIInterval:      600,
		Timezone:         timezone,
		Notifications: domain.NotificationConfig{
			Telegram: domain.TelegramConfig{
				Enabled:         true,
				Token:           "test-token",
				ChatID:          "12345",
				DailyReport:     true,
				DailyReportTime: reportTime,
			},
		},
	}
	if err = st.Setup(context.Background(), config); err != nil {
		t.Fatal(err)
	}
	return New(st, nil, notify.New(), slog.Default(), 1), st
}

func countRows(t *testing.T, st *store.Store, query string, args ...any) int {
	t.Helper()
	var count int
	if err := st.DB().QueryRow(query, args...).Scan(&count); err != nil {
		t.Fatal(err)
	}
	return count
}

func TestEnqueueDailyReportWaitsForLocalTime(t *testing.T) {
	eng, st := setupDailyReportEngine(t, "Asia/Shanghai", "08:00")
	location, err := time.LoadLocation("Asia/Shanghai")
	if err != nil {
		t.Fatal(err)
	}
	before := time.Date(2026, 8, 24, 7, 59, 0, 0, location)
	if err = eng.enqueueDailyReportIfDue(context.Background(), before); err != nil {
		t.Fatal(err)
	}
	if countRows(t, st, `SELECT COUNT(*) FROM jobs WHERE type=?`, JobDailyReport) != 0 {
		t.Fatal("report must not enqueue before the configured local time")
	}

	after := time.Date(2026, 8, 24, 8, 0, 0, 0, location)
	if err = eng.enqueueDailyReportIfDue(context.Background(), after); err != nil {
		t.Fatal(err)
	}
	if countRows(t, st, `SELECT COUNT(*) FROM jobs WHERE type=?`, JobDailyReport) != 1 {
		t.Fatal("report should enqueue once the local send time is reached")
	}
}

func TestEnqueueDailyReportUsesTimezoneDateAndDedupes(t *testing.T) {
	eng, st := setupDailyReportEngine(t, "Asia/Shanghai", "00:00")
	// 2026-08-23 16:00 UTC == 2026-08-24 00:00 Asia/Shanghai
	now := time.Date(2026, 8, 23, 16, 0, 0, 0, time.UTC)
	if err := eng.enqueueDailyReportIfDue(context.Background(), now); err != nil {
		t.Fatal(err)
	}
	if err := eng.enqueueDailyReportIfDue(context.Background(), now.Add(15*time.Second)); err != nil {
		t.Fatal(err)
	}
	if countRows(t, st, `SELECT COUNT(*) FROM jobs WHERE type=?`, JobDailyReport) != 1 {
		t.Fatal("unique job key must prevent a second automatic report for the same local day")
	}
	var uniqueKey, payload string
	if err := st.DB().QueryRow(`SELECT unique_key, payload FROM jobs WHERE type=?`, JobDailyReport).Scan(&uniqueKey, &payload); err != nil {
		t.Fatal(err)
	}
	if uniqueKey != "daily_report:20260824" {
		t.Fatalf("unique key = %q, want local Shanghai date", uniqueKey)
	}
	if payload != `{"day":"20260824"}` {
		t.Fatalf("payload = %q", payload)
	}
}

func TestEnqueueDailyReportAcceptsTimeWithSeconds(t *testing.T) {
	eng, st := setupDailyReportEngine(t, "Asia/Shanghai", "22:00:00")
	location, err := time.LoadLocation("Asia/Shanghai")
	if err != nil {
		t.Fatal(err)
	}
	before := time.Date(2026, 8, 24, 21, 59, 0, 0, location)
	if err = eng.enqueueDailyReportIfDue(context.Background(), before); err != nil {
		t.Fatal(err)
	}
	if countRows(t, st, `SELECT COUNT(*) FROM jobs WHERE type=?`, JobDailyReport) != 0 {
		t.Fatal("HH:MM:SS send time must not collapse to midnight")
	}
	after := time.Date(2026, 8, 24, 22, 0, 0, 0, location)
	if err = eng.enqueueDailyReportIfDue(context.Background(), after); err != nil {
		t.Fatal(err)
	}
	if countRows(t, st, `SELECT COUNT(*) FROM jobs WHERE type=?`, JobDailyReport) != 1 {
		t.Fatal("report should enqueue at the configured HH:MM:SS time")
	}
}

func TestSendDailyReportIsIdempotentForTheSameDay(t *testing.T) {
	eng, st := setupDailyReportEngine(t, "Asia/Shanghai", "00:00")
	job := domain.Job{Payload: `{"day":"20260824"}`}
	if _, err := eng.sendDailyReport(context.Background(), job); err != nil {
		t.Fatal(err)
	}
	if _, err := eng.sendDailyReport(context.Background(), job); err != nil {
		t.Fatal(err)
	}
	if countRows(t, st, `SELECT COUNT(*) FROM notification_outbox WHERE event_id=?`, "daily_report:20260824") != 1 {
		t.Fatal("retried scheduled report must reuse the same outbox event")
	}
}

func TestBusyLeaseDoesNotEnqueueDailyReport(t *testing.T) {
	eng, st := setupDailyReportEngine(t, "Asia/Shanghai", "00:00")
	other := New(st, nil, notify.New(), slog.Default(), 1)
	if _, err := st.AcquireLease(context.Background(), "monitor", other.owner, time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := eng.RunOnce(context.Background()); !errors.Is(err, ErrMonitorBusy) {
		t.Fatalf("expected busy lease, got %v", err)
	}
	if countRows(t, st, `SELECT COUNT(*) FROM jobs WHERE type=?`, JobDailyReport) != 0 {
		t.Fatal("follower instance must not schedule a daily report without the lease")
	}
}
