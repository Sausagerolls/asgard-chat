// Package adminui serves the embedded web admin panel at /admin.
package adminui

import (
	"embed"
	"io/fs"
	"net/http"
)

//go:embed static
var static embed.FS

func Handler() http.Handler {
	sub, _ := fs.Sub(static, "static")
	files := http.FileServer(http.FS(sub))
	return http.StripPrefix("/admin", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// The panel uses relative asset paths, so it must be served from /admin/.
		if r.URL.Path == "" {
			http.Redirect(w, r, "/admin/", http.StatusMovedPermanently)
			return
		}
		w.Header().Set("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'; frame-ancestors 'none'")
		files.ServeHTTP(w, r)
	}))
}
