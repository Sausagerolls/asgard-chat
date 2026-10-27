// Command asgard-relay is the push relay for the official Asgard apps.
// It runs on Google Cloud Run (see relay/README.md) and holds the only copy of
// the Apple and Google push credentials. Self-hosted servers never need them.
package main

import (
	"context"
	"encoding/base64"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/giantmushroom/asgard-chat/server/internal/push"
	"github.com/giantmushroom/asgard-chat/server/internal/relay"
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	// Cloud Logging reads "severity" and "message" from JSON lines.
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{ReplaceAttr: func(_ []string, a slog.Attr) slog.Attr {
		switch a.Key {
		case slog.LevelKey:
			a.Key = "severity"
			if a.Value.String() == "WARN" {
				a.Value = slog.StringValue("WARNING")
			}
		case slog.MessageKey:
			a.Key = "message"
		}
		return a
	}})))
	if err := run(); err != nil {
		slog.Error("relay stopped", "err", err)
		os.Exit(1)
	}
}

func run() error {
	master, err := base64.StdEncoding.DecodeString(strings.TrimSpace(os.Getenv("RELAY_MASTER_KEY")))
	if err != nil || len(master) != 32 {
		return errorf("RELAY_MASTER_KEY must be 32 random bytes, base64 encoded (openssl rand -base64 32)")
	}
	up := push.New()
	if k := os.Getenv("APNS_KEY"); k != "" {
		if err := up.ConfigureAPNs([]byte(k), env("APNS_KEY_ID", ""), env("APNS_TEAM_ID", ""), env("APNS_TOPIC", "com.giantmushroom.asgardchat")); err != nil {
			return errorf("APNs: " + err.Error())
		}
	}
	if c := os.Getenv("FCM_CREDENTIALS"); c != "" {
		if err := up.ConfigureFCM([]byte(c)); err != nil {
			return errorf("FCM: " + err.Error())
		}
	}
	apns, fcm := up.Enabled()
	slog.Info("relay starting", "apns", apns, "fcm", fcm)

	blocked := map[string]bool{}
	for _, id := range strings.Split(os.Getenv("RELAY_BLOCKED_SERVERS"), ",") {
		if id = strings.TrimSpace(id); id != "" {
			blocked[id] = true
		}
	}
	num := func(k string, def float64) float64 {
		v, err := strconv.ParseFloat(os.Getenv(k), 64)
		if err != nil {
			return def
		}
		return v
	}
	r, err := relay.New(relay.Config{
		MasterKey: master, Blocked: blocked,
		PushesPerSec: num("RELAY_PUSHES_PER_SEC", 20), PushBurst: num("RELAY_PUSH_BURST", 200),
		DailyPerServer: int(num("RELAY_DAILY_PER_SERVER", 50_000)), RegisterPerIP: int(num("RELAY_REGISTER_PER_IP", 60)),
	}, up)
	if err != nil {
		return err
	}

	srv := &http.Server{Addr: ":" + env("PORT", "8080"), Handler: r.Handler(), ReadHeaderTimeout: 10 * time.Second}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		srv.Shutdown(shutdown)
	}()
	if err := srv.ListenAndServe(); err != http.ErrServerClosed {
		return err
	}
	return nil
}

type errorf string

func (e errorf) Error() string { return string(e) }
