// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

package netstack

import (
	"context"
	"fmt"
	"net"
	"net/url"
	"os"

	"golang.org/x/net/proxy"
	"tailscale.com/envknob"
	"tailscale.com/net/netx"
	"tailscale.com/types/logger"
)

// forwardProxyEnv is the environment variable that, when set, routes
// forwarded TCP flows (exit-node / subnet-router egress) through the
// specified proxy. Supported schemes: socks5, http.
//
// Example: TS_FORWARD_PROXY=socks5://127.0.0.1:7891
//
// This lets an exit node forward its egress through a local proxy such
// as Clash Verge, so that peers using the exit node can reach the
// internet through the proxy even when the exit node itself cannot
// reach the destination directly (e.g. behind a firewall).
const forwardProxyEnv = "TS_FORWARD_PROXY"

// newForwardProxyDialer reads the TS_FORWARD_PROXY environment variable
// and, if set, returns a DialFunc that dials through the configured
// proxy. Returns nil when the variable is empty, leaving forwardTCP to
// use the default net.Dialer.
func newForwardProxyDialer(logf logger.Logf) netx.DialFunc {
	proxyURL := envknob.String(forwardProxyEnv)
	if proxyURL == "" {
		// Also honor the lower-case form some tools set.
		proxyURL = os.Getenv("ts_forward_proxy")
	}
	if proxyURL == "" {
		return nil
	}
	u, err := url.Parse(proxyURL)
	if err != nil {
		logf("netstack: invalid %s=%q: %v; ignoring", forwardProxyEnv, proxyURL, err)
		return nil
	}
	switch u.Scheme {
	case "socks5", "socks5h":
		d, err := socks5Dialer(u)
		if err != nil {
			logf("netstack: %s: %v; ignoring", forwardProxyEnv, err)
			return nil
		}
		cd, ok := d.(proxy.ContextDialer)
		if !ok {
			logf("netstack: %s: socks5 dialer does not implement ContextDialer; ignoring", forwardProxyEnv)
			return nil
		}
		logf("netstack: forward proxy enabled: %s", proxyURL)
		return func(ctx context.Context, network, addr string) (net.Conn, error) {
			return cd.DialContext(ctx, network, addr)
		}
	case "http", "https":
		logf("netstack: forward proxy enabled: %s", proxyURL)
		return httpProxyDialer(u)
	default:
		logf("netstack: %s: unsupported scheme %q; ignoring", forwardProxyEnv, u.Scheme)
		return nil
	}
}

// httpProxyDialer returns a DialFunc that connects to the target via an
// HTTP CONNECT proxy. The returned function always uses "tcp" as the
// network regardless of the requested network, matching the behaviour
// of HTTP CONNECT proxies.
func httpProxyDialer(u *url.URL) netx.DialFunc {
	proxyAddr := u.Host
	if proxyAddr == "" {
		proxyAddr = u.Path
	}
	return func(ctx context.Context, network, addr string) (net.Conn, error) {
		var d net.Dialer
		c, err := d.DialContext(ctx, "tcp", proxyAddr)
		if err != nil {
			return nil, fmt.Errorf("connect to proxy %s: %w", proxyAddr, err)
		}
		// Issue a CONNECT request to tunnel to the target.
		connectReq := fmt.Sprintf("CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", addr, addr)
		if _, err := c.Write([]byte(connectReq)); err != nil {
			c.Close()
			return nil, fmt.Errorf("write CONNECT to proxy: %w", err)
		}
		br := make([]byte, 1024)
		n, err := c.Read(br)
		if err != nil {
			c.Close()
			return nil, fmt.Errorf("read CONNECT response: %w", err)
		}
		resp := string(br[:n])
		// Expect "HTTP/1.1 200 ..." or "HTTP/1.0 200 ...".
		if len(resp) < 12 || resp[9] != '2' {
			c.Close()
			return nil, fmt.Errorf("proxy CONNECT failed: %s", resp)
		}
		return c, nil
	}
}
