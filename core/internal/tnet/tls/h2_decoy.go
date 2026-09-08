package tls

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// The decoy is what an active prober sees, and it has to survive two different
// questions.
//
// The first is "what is this host?". Go's http.NotFoundHandler answers every
// path with the literal body "404 page not found" and no Server header, which
// names the host as a bare Go program in one unauthenticated request. That is
// what a censor's probe asks, and it used to get an answer.
//
// The second is "where are all the others?". If every WildPaqet server replied
// with the same bytes, one internet-wide scan for that reply would enumerate
// the whole fleet - no secret and no probing needed. A disguise everybody wears
// identically is a uniform, so answering *plausibly* is not enough on its own;
// the answer also has to differ per install.
//
// So each server derives a web-server identity from its own shared secret: which
// nginx build it claims to be, whether that build prints its version, when its
// index.html was last written, and therefore its ETag. The secret is different
// everywhere and never leaves the host, so the values cannot be predicted from
// outside and no two deployments match. It is a keyed hash rather than a random
// draw, so one server keeps its identity across restarts - a real file does not
// change its date when the machine reboots.
//
// Pointing decoy_url at a site the operator actually runs is still better than
// any of this, and the wizard says so.

// decoyBuild is one nginx identity. The pages travel with the version on
// purpose: nginx changed both its default index and its error pages in the 1.23
// series, so a 2020 version string serving the 2023 markup is exactly the kind
// of internal contradiction a fingerprinter looks for.
type decoyBuild struct {
	version  string
	index    string
	notFound string // %s is the footer nginx prints, which equals the Server value
}

// Versions that real distributions actually ship, so a derived value is one that
// exists in the wild rather than something invented.
var decoyBuilds = []decoyBuild{
	{"1.14.0 (Ubuntu)", decoyIndexPre123, decoyNotFoundPre123},   // Ubuntu 18.04
	{"1.18.0 (Ubuntu)", decoyIndexPre123, decoyNotFoundPre123},   // Ubuntu 20.04
	{"1.20.1", decoyIndexPre123, decoyNotFoundPre123},            // RHEL 9 / AlmaLinux
	{"1.22.1", decoyIndexPre123, decoyNotFoundPre123},            // Debian 12
	{"1.24.0 (Ubuntu)", decoyIndexPost123, decoyNotFoundPost123}, // Ubuntu 24.04
	{"1.26.3", decoyIndexPost123, decoyNotFoundPost123},          // recent stable
}

// decoyNewestModTime is the most recent date an index.html may claim. Every
// identity lands in a window below it, so the page is always older than the
// response that carries it - a Last-Modified in the future is one of the few
// things a file on a disk genuinely cannot produce. A default page written once
// at install and never touched again is the ordinary case, so this needs no
// upkeep as it ages.
var decoyNewestModTime = time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)

const (
	decoyMinAgeDays = 30
	decoyMaxAgeDays = 1000
)

// decoyIdentity is one server's stable, self-derived web-server persona.
type decoyIdentity struct {
	server   string
	index    string
	notFound string
	modTime  time.Time
	etag     string
}

func newDecoyIdentity(secret []byte) decoyIdentity {
	// Keyed and domain-separated, so the ETag this ends up publishing cannot
	// say anything about the secret or about anything else derived from it.
	mac := hmac.New(sha256.New, secret)
	_, _ = mac.Write([]byte("wildpaqet-decoy-identity-v1"))
	h := mac.Sum(nil)

	build := decoyBuilds[int(h[0])%len(decoyBuilds)]

	// "server_tokens off" is ordinary on a hardened host and hides the version
	// from the header and the error-page footer alike. Taking it half the time
	// splits the fleet across one more axis.
	server := "nginx"
	if h[1]&1 == 0 {
		server = "nginx/" + build.version
	}

	newest := decoyNewestModTime
	if now := time.Now().UTC(); now.Before(newest) {
		newest = now
	}
	days := int(binary.BigEndian.Uint16(h[2:4]))%(decoyMaxAgeDays-decoyMinAgeDays) + decoyMinAgeDays
	secs := int(binary.BigEndian.Uint32(h[4:8]) % 86400)
	modTime := newest.Add(-time.Duration(days)*24*time.Hour - time.Duration(secs)*time.Second)

	return decoyIdentity{
		server:   server,
		index:    build.index,
		notFound: build.notFound,
		modTime:  modTime,
		// nginx's own ETag for a static file: modification time and size, both
		// hex, joined by a dash. It is computed from the other two headers
		// rather than drawn, because an ETag that contradicts its own
		// Last-Modified and Content-Length is worse than sending none - nothing
		// that serves files produces that combination.
		etag: fmt.Sprintf(`"%x-%x"`, modTime.Unix(), len(build.index)),
	}
}

func (d decoyIdentity) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet, http.MethodHead:
	default:
		// A static site has nothing to POST to.
		d.writeStatus(w, http.StatusMethodNotAllowed)
		return
	}
	if r.URL.Path != "/" && r.URL.Path != "/index.html" {
		// Everything that is not the index is a 404, the tunnel's own cover
		// path included. A server whose root holds one index.html answers
		// exactly this way, and being one 404 among many is what keeps the
		// cover path from standing out.
		d.writeStatus(w, http.StatusNotFound)
		return
	}

	w.Header().Set("Server", d.server)
	w.Header().Set("Content-Type", "text/html")
	w.Header().Set("ETag", d.etag)
	// ServeContent is doing a file server's job here rather than saving lines:
	// Last-Modified, Accept-Ranges, Content-Length, If-Modified-Since,
	// If-None-Match, Range and HEAD all have to behave as they would for a file
	// on disk. A hand-written 200 gets each of those wrong, and a probe that
	// replays the ETag and is answered 200 instead of 304 has just learned the
	// page is generated.
	http.ServeContent(w, r, "", d.modTime, strings.NewReader(d.index))
}

// writeStatus renders the error page the claimed nginx build would render.
func (d decoyIdentity) writeStatus(w http.ResponseWriter, status int) {
	body := fmt.Sprintf(d.notFound, status, http.StatusText(status), status, http.StatusText(status), d.server)
	h := w.Header()
	h.Set("Server", d.server)
	h.Set("Content-Type", "text/html")
	h.Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(status)
	// net/http drops this for HEAD, which is what nginx does too.
	_, _ = io.WriteString(w, body)
}

func newDecoyHandler(rawURL string, secret []byte) http.Handler {
	identity := newDecoyIdentity(secret)
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
				identity.writeStatus(w, http.StatusBadGateway)
			}
			return proxy
		}
	}
	return identity
}

// The default pages as the matching nginx builds ship them. nginx 1.23.2 added
// the color-scheme rule to the index and dropped bgcolor="white" from the error
// pages, which is why there are two of each.

const decoyIndexPre123 = `<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
<style>
    body {
        width: 35em;
        margin: 0 auto;
        font-family: Tahoma, Verdana, Arial, sans-serif;
    }
</style>
</head>
<body>
<h1>Welcome to nginx!</h1>
<p>If you see this page, the nginx web server is successfully installed and
working. Further configuration is required.</p>

<p>For online documentation and support please refer to
<a href="http://nginx.org/">nginx.org</a>.<br/>
Commercial support is available at
<a href="http://nginx.com/">nginx.com</a>.</p>

<p><em>Thank you for using nginx.</em></p>
</body>
</html>
`

const decoyIndexPost123 = `<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
<style>
html { color-scheme: light dark; }
body { width: 35em; margin: 0 auto;
font-family: Tahoma, Verdana, Arial, sans-serif; }
</style>
</head>
<body>
<h1>Welcome to nginx!</h1>
<p>If you see this page, the nginx web server is successfully installed and
working. Further configuration is required.</p>

<p>For online documentation and support please refer to
<a href="http://nginx.org/">nginx.org</a>.<br/>
Commercial support is available at
<a href="http://nginx.com/">nginx.com</a>.</p>

<p><em>Thank you for using nginx.</em></p>
</body>
</html>
`

const decoyNotFoundPre123 = `<html>
<head><title>%d %s</title></head>
<body bgcolor="white">
<center><h1>%d %s</h1></center>
<hr><center>%s</center>
</body>
</html>
`

const decoyNotFoundPost123 = `<html>
<head><title>%d %s</title></head>
<body>
<center><h1>%d %s</h1></center>
<hr><center>%s</center>
</body>
</html>
`
