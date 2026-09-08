package tls

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
)

// The decoy is what an active prober sees, and its default is the weakest part
// of the cover story.
//
// Go's http.NotFoundHandler answers with the literal body "404 page not found\n"
// and sends no Server header. A host that carries a valid public certificate,
// negotiates h2, and then answers that identifies itself as a bare Go program in
// one unauthenticated request - regardless of which path is probed. A censor
// that actively probes endpoints does exactly this.
//
// The fallback therefore answers like an ordinary web server that has no
// content configured, which is unremarkable and says nothing about what else
// the host runs. It deliberately does NOT invent a landing page: a welcome page
// shipped in the binary would be byte-identical on every WildPaqet host and
// become a fingerprint of its own (see TestDecoyHasNoSharedWelcomeFallback).
// An operator who points decoy_url at a real site gets that site, and that
// remains the better configuration.
const decoyServerName = "nginx"

// writeDecoyStatus renders a stock web-server error page for a status code.
func writeDecoyStatus(w http.ResponseWriter, status int) {
	body := fmt.Sprintf(`<html>
<head><title>%d %s</title></head>
<body>
<center><h1>%d %s</h1></center>
<hr><center>%s</center>
</body>
</html>
`, status, http.StatusText(status), status, http.StatusText(status), decoyServerName)
	h := w.Header()
	h.Set("Server", decoyServerName)
	h.Set("Content-Type", "text/html")
	h.Set("Content-Length", fmt.Sprint(len(body)))
	w.WriteHeader(status)
	_, _ = io.WriteString(w, body)
}

// builtinDecoy answers every unauthenticated request the way a configured-but-
// empty virtual host would.
type builtinDecoy struct{}

func (builtinDecoy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet, http.MethodHead, http.MethodPost:
		writeDecoyStatus(w, http.StatusNotFound)
	default:
		writeDecoyStatus(w, http.StatusMethodNotAllowed)
	}
}

func newDecoyHandler(rawURL string) http.Handler {
	if rawURL != "" {
		if target, err := url.Parse(rawURL); err == nil && target.Host != "" && (target.Scheme == "http" || target.Scheme == "https") {
			proxy := httputil.NewSingleHostReverseProxy(target)
			// Requests are made to an explicitly configured backend, not to the
			// arbitrary Host supplied by a visitor.
			director := proxy.Director
			proxy.Director = func(r *http.Request) {
				director(r)
				r.Host = target.Host
			}
			proxy.ErrorLog = log.New(io.Discard, "", 0)
			proxy.ErrorHandler = func(w http.ResponseWriter, _ *http.Request, _ error) {
				// An unreachable backend must not expose Go's plain-text error
				// body; a real proxy renders its own gateway page.
				writeDecoyStatus(w, http.StatusBadGateway)
			}
			return proxy
		}
	}
	return builtinDecoy{}
}
