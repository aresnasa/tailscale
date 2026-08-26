// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

package ipnlocal

import (
	"bufio"
	"net/netip"
	"os"
	"path/filepath"
	"strings"

	"tailscale.com/envknob"
)

// customIgnoreRoutesFilename is the name of the optional file, placed
// in the TailscaleVarRoot (e.g. /var/lib/tailscale), that lists
// extra CIDR prefixes to treat as IgnoreRoutes. This lets an
// administrator keep a machine's own routing table (or another VPN's
// address space) out of the tunnel without touching prefs.
//
// The file is plain text: one CIDR per line. Blank lines and lines
// whose first non-space character is '#' are ignored.
const customIgnoreRoutesFilename = "ignore-routes.conf"

// customIgnoreRoutesPath returns the path to the custom ignore-routes
// file, or "" if no usable location is known. An explicit path given
// via the TS_IGNORE_ROUTES_FILE environment variable takes
// precedence; otherwise the file is looked up under the daemon's
// TailscaleVarRoot.
func (b *LocalBackend) customIgnoreRoutesPath() string {
	if p := envknob.String("TS_IGNORE_ROUTES_FILE"); p != "" {
		return p
	}
	if root := b.TailscaleVarRoot(); root != "" {
		return filepath.Join(root, customIgnoreRoutesFilename)
	}
	return ""
}

// loadCustomIgnoreRoutes reads the custom ignore-routes file (if any)
// and returns the parsed prefixes. A missing file is not an error and
// yields nil. Malformed entries are skipped with a log line.
//
// The result is not deduplicated; the caller merges it with the
// prefs-derived IgnoreRoutes and hands the combined list to the route
// manager, which normalizes it.
func (b *LocalBackend) loadCustomIgnoreRoutes() []netip.Prefix {
	path := b.customIgnoreRoutesPath()
	if path == "" {
		return nil
	}
	f, err := os.Open(path)
	if err != nil {
		if !os.IsNotExist(err) {
			b.logf("ignore-routes: failed to open %q: %v", path, err)
		}
		return nil
	}
	defer f.Close()

	var out []netip.Prefix
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		// Allow an optional trailing comment after the CIDR.
		if i := strings.IndexByte(line, '#'); i >= 0 {
			line = strings.TrimSpace(line[:i])
			if line == "" {
				continue
			}
		}
		pfx, err := netip.ParsePrefix(line)
		if err != nil {
			b.logf("ignore-routes: skipping invalid entry %q in %q: %v", line, path, err)
			continue
		}
		out = append(out, pfx.Masked())
	}
	if err := sc.Err(); err != nil {
		b.logf("ignore-routes: error reading %q: %v", path, err)
		return out
	}
	return out
}
