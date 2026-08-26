// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

package netstack

import (
	"fmt"
	"net/url"

	"golang.org/x/net/proxy"
)

// socks5Dialer parses a socks5:// URL and returns a proxy.Dialer that
// dials through the SOCKS5 proxy at the URL's host:port, honoring an
// optional username/password.
func socks5Dialer(u *url.URL) (proxy.Dialer, error) {
	var auth *proxy.Auth
	if u.User != nil {
		pw, _ := u.User.Password()
		auth = &proxy.Auth{
			User:     u.User.Username(),
			Password: pw,
		}
	}
	d, err := proxy.SOCKS5("tcp", u.Host, auth, proxy.Direct)
	if err != nil {
		return nil, fmt.Errorf("socks5 dialer: %w", err)
	}
	return d, nil
}
