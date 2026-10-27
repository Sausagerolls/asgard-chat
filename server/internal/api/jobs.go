package api

import (
	"context"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
)

// RunJobs runs periodic maintenance until ctx is cancelled.
func (s *Server) RunJobs(ctx context.Context) {
	fast := time.NewTicker(5 * time.Second)
	slow := time.NewTicker(time.Minute)
	defer fast.Stop()
	defer slow.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-fast.C:
			s.RunScheduled(ctx)
		case <-slow.C:
			s.janitor(ctx)
		}
	}
}

func (s *Server) janitor(ctx context.Context) {
	exec := func(what, sql string, args ...any) {
		if tag, err := s.db.Exec(ctx, sql, args...); err != nil {
			slog.Error("janitor", "task", what, "err", err)
		} else if n := tag.RowsAffected(); n > 0 {
			slog.Info("janitor", "task", what, "rows", n)
		}
	}
	// Disappearing messages, plus anything that references them.
	exec("expire messages", `DELETE FROM messages WHERE expires_at < now()`)
	exec("expire stories", `DELETE FROM stories WHERE expires_at < now()`)
	exec("expire sessions", `DELETE FROM sessions WHERE expires_at < now()`)
	exec("expire device links", `DELETE FROM device_links WHERE expires_at < now()`)
	if days := s.settings(ctx).MessageRetentionDays; days > 0 {
		exec("retention", `DELETE FROM messages WHERE sent_at < now() - make_interval(days => $1)`, days)
	}
	// Expired media blobs.
	rows, err := s.db.Query(ctx, `DELETE FROM media WHERE expires_at < now() RETURNING object_key`)
	if err == nil {
		keys, _ := pgx.CollectRows(rows, pgx.RowTo[string])
		for _, k := range keys {
			if s.store != nil {
				s.store.Delete(ctx, k)
			}
		}
	}
}
