// Command asgard runs the Asgard Chat server and its admin CLI.
//
//	asgard serve                      run the server (default)
//	asgard migrate                    apply database migrations and exit
//	asgard invite create [-uses N] [-admin] [-hours H] [-note TEXT]
//	asgard invite list
//	asgard user list
//	asgard user reset-password USERNAME
//	asgard user set-admin USERNAME true|false
//	asgard user disable USERNAME true|false
//	asgard healthcheck                exit 0 if the local server answers /healthz
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"text/tabwriter"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/giantmushroom/asgard-chat/server/internal/api"
	"github.com/giantmushroom/asgard-chat/server/internal/auth"
	"github.com/giantmushroom/asgard-chat/server/internal/config"
	"github.com/giantmushroom/asgard-chat/server/internal/db"
	"github.com/giantmushroom/asgard-chat/server/internal/push"
	"github.com/giantmushroom/asgard-chat/server/internal/realtime"
	"github.com/giantmushroom/asgard-chat/server/internal/storage"
)

var version = "dev"

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: logLevel()})))
	api.Version = version
	args := os.Args[1:]
	if len(args) == 0 {
		args = []string{"serve"}
	}
	var err error
	switch args[0] {
	case "serve":
		err = serve()
	case "healthcheck":
		err = healthcheck()
	case "migrate", "invite", "user":
		err = cli(args)
	case "version":
		fmt.Println(version)
	default:
		err = fmt.Errorf("unknown command %q (try: serve, migrate, invite, user, healthcheck, version)", args[0])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func logLevel() slog.Level {
	if os.Getenv("ASGARD_DEBUG") == "1" {
		return slog.LevelDebug
	}
	return slog.LevelInfo
}

func open(ctx context.Context) (*config.Config, *pgxpool.Pool, error) {
	cfg, err := config.Load()
	if err != nil {
		return nil, nil, err
	}
	pool, err := db.Open(ctx, cfg.DatabaseURL)
	if err != nil {
		return nil, nil, err
	}
	if err := db.Migrate(ctx, pool); err != nil {
		pool.Close()
		return nil, nil, err
	}
	return cfg, pool, nil
}

func serve() error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	cfg, pool, err := open(ctx)
	if err != nil {
		return err
	}
	defer pool.Close()

	var store storage.Store
	switch cfg.StorageKind {
	case "s3":
		store, err = storage.NewS3(ctx, cfg.S3Endpoint, cfg.S3AccessKey, cfg.S3SecretKey, cfg.S3Bucket, cfg.S3Region, cfg.S3UseSSL)
	case "fs":
		store, err = storage.NewFS(cfg.MediaDir)
	default:
		err = fmt.Errorf("ASGARD_STORAGE must be fs or s3")
	}
	if err != nil {
		return fmt.Errorf("media storage: %w", err)
	}
	ps, err := push.New(cfg.APNsKeyPath, cfg.APNsKeyID, cfg.APNsTeamID, cfg.APNsTopic, cfg.APNsSandbox, cfg.FCMCredsPath)
	if err != nil {
		return err
	}
	if !cfg.PushEnabled() {
		slog.Warn("push notifications disabled: configure APNs and/or FCM secrets")
	}
	srv := api.New(cfg, pool, realtime.NewHub(), ps, store)
	if err := bootstrap(ctx, cfg, srv, pool); err != nil {
		return err
	}
	go srv.RunJobs(ctx)

	httpSrv := &http.Server{Addr: cfg.ListenAddr, Handler: srv.Router(), ReadHeaderTimeout: 15 * time.Second}
	errc := make(chan error, 1)
	go func() {
		slog.Info("asgard listening", "addr", cfg.ListenAddr, "public_url", cfg.PublicURL, "version", version)
		errc <- httpSrv.ListenAndServe()
	}()
	select {
	case err := <-errc:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	case <-ctx.Done():
	}
	slog.Info("shutting down")
	shutdown, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	return httpSrv.Shutdown(shutdown)
}

// bootstrap prints a one-time admin invite when the server has no users yet.
func bootstrap(ctx context.Context, cfg *config.Config, srv *api.Server, pool *pgxpool.Pool) error {
	var users int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM users WHERE NOT is_bot`).Scan(&users); err != nil {
		return err
	}
	if users > 0 {
		return nil
	}
	code := strings.ToUpper(cfg.BootstrapInvite)
	if code == "" {
		var existing string
		if pool.QueryRow(ctx, `SELECT code FROM invites WHERE make_admin AND uses < max_uses ORDER BY created_at LIMIT 1`).Scan(&existing) == nil {
			code = existing
		} else {
			inv, err := api.CreateInvite(ctx, srv, nil, "bootstrap admin", 1, true, 0)
			if err != nil {
				return err
			}
			code = inv.Code
		}
	} else {
		pool.Exec(ctx, `INSERT INTO invites(code, note, max_uses, make_admin) VALUES ($1, 'bootstrap admin', 1, true) ON CONFLICT DO NOTHING`, code)
	}
	slog.Info("no users yet: sign up in the app with this admin invite code", "invite", code, "url", cfg.PublicURL+"/invite/"+code)
	return nil
}

func healthcheck() error {
	addr := os.Getenv("ASGARD_LISTEN")
	if addr == "" {
		addr = ":8080"
	}
	if strings.HasPrefix(addr, ":") {
		addr = "127.0.0.1" + addr
	}
	c := &http.Client{Timeout: 4 * time.Second}
	resp, err := c.Get("http://" + addr + "/healthz")
	if err != nil {
		return err
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("healthz returned %d", resp.StatusCode)
	}
	return nil
}

func cli(args []string) error {
	ctx := context.Background()
	cfg, pool, err := open(ctx)
	if err != nil {
		return err
	}
	defer pool.Close()
	srv := api.New(cfg, pool, realtime.NewHub(), nil, nil)
	tw := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	defer tw.Flush()

	sub := ""
	if len(args) > 1 {
		sub = args[1]
	}
	switch args[0] + " " + sub {
	case "migrate ":
		fmt.Println("migrations applied")
	case "invite create":
		fs := flag.NewFlagSet("invite create", flag.ExitOnError)
		uses := fs.Int("uses", 1, "how many people can use it")
		admin := fs.Bool("admin", false, "make the new user a server admin")
		hours := fs.Int("hours", 168, "expiry in hours (0 = never)")
		note := fs.String("note", "", "note shown in the admin panel")
		fs.Parse(args[2:])
		inv, err := api.CreateInvite(ctx, srv, nil, *note, *uses, *admin, *hours)
		if err != nil {
			return err
		}
		fmt.Fprintf(tw, "code\t%s\nlink\t%s\nuses\t%d\n", inv.Code, inv.URL, inv.MaxUses)
	case "invite list":
		rows, err := pool.Query(ctx, `SELECT code, uses, max_uses, make_admin, coalesce(to_char(expires_at, 'YYYY-MM-DD HH24:MI'), 'never'), note FROM invites ORDER BY created_at DESC`)
		if err != nil {
			return err
		}
		defer rows.Close()
		fmt.Fprintln(tw, "CODE\tUSED\tADMIN\tEXPIRES\tNOTE")
		for rows.Next() {
			var code, exp, note string
			var uses, max int
			var admin bool
			rows.Scan(&code, &uses, &max, &admin, &exp, &note)
			fmt.Fprintf(tw, "%s\t%d/%d\t%v\t%s\t%s\n", code, uses, max, admin, exp, note)
		}
	case "user list":
		rows, err := pool.Query(ctx, `SELECT username, display_name, is_admin, is_bot, disabled, (SELECT count(*) FROM devices d WHERE d.user_id = u.id) FROM users u ORDER BY created_at`)
		if err != nil {
			return err
		}
		defer rows.Close()
		fmt.Fprintln(tw, "USERNAME\tNAME\tADMIN\tBOT\tDISABLED\tDEVICES")
		for rows.Next() {
			var u, n string
			var a, b, d bool
			var devices int
			rows.Scan(&u, &n, &a, &b, &d, &devices)
			fmt.Fprintf(tw, "%s\t%s\t%v\t%v\t%v\t%d\n", u, n, a, b, d, devices)
		}
	case "user reset-password":
		if len(args) < 3 {
			return errors.New("usage: asgard user reset-password USERNAME")
		}
		temp := strings.ToLower(auth.RandomCode(4))
		hash, err := auth.HashPassword(temp)
		if err != nil {
			return err
		}
		tag, err := pool.Exec(ctx, `UPDATE users SET password_hash = $2 WHERE username = $1 AND NOT is_bot`, strings.ToLower(args[2]), hash)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return fmt.Errorf("no user %q", args[2])
		}
		fmt.Fprintf(tw, "temporary password\t%s\n", temp)
	case "user set-admin", "user disable":
		if len(args) < 4 {
			return fmt.Errorf("usage: asgard user %s USERNAME true|false", sub)
		}
		v, err := strconv.ParseBool(args[3])
		if err != nil {
			return err
		}
		col := map[string]string{"set-admin": "is_admin", "disable": "disabled"}[sub]
		tag, err := pool.Exec(ctx, `UPDATE users SET `+col+` = $2 WHERE username = $1`, strings.ToLower(args[2]), v)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return fmt.Errorf("no user %q", args[2])
		}
		if sub == "disable" && v {
			pool.Exec(ctx, `DELETE FROM sessions WHERE user_id = (SELECT id FROM users WHERE username = $1)`, strings.ToLower(args[2]))
		}
		fmt.Fprintf(tw, "%s\t%s = %v\n", args[2], col, v)
	default:
		return fmt.Errorf("unknown command %q", strings.Join(args, " "))
	}
	return nil
}
