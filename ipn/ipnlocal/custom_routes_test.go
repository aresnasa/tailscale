// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

package ipnlocal

import (
	"net/netip"
	"os"
	"path/filepath"
	"testing"

	"tailscale.com/types/logger"
)

func TestLoadCustomIgnoreRoutes(t *testing.T) {
	dir := t.TempDir()

	b := &LocalBackend{varRoot: dir, logf: logger.Discard}

	// No file present: nil, no error.
	if got := b.loadCustomIgnoreRoutes(); got != nil {
		t.Fatalf("missing file: got %v, want nil", got)
	}

	// Write a file with a mix of valid, blank, comment and invalid lines.
	content := "" +
		"# leading comment\n" +
		"10.0.0.0/8\n" +
		"\n" +
		"  192.168.0.0/16  # trailing comment\n" +
		"not-a-cidr\n" +
		"172.16.0.0/12\n"
	if err := os.WriteFile(filepath.Join(dir, customIgnoreRoutesFilename), []byte(content), 0600); err != nil {
		t.Fatal(err)
	}

	got := b.loadCustomIgnoreRoutes()
	want := []string{"10.0.0.0/8", "192.168.0.0/16", "172.16.0.0/12"}
	if len(got) != len(want) {
		t.Fatalf("got %d prefixes %v, want %d (%v)", len(got), got, len(want), want)
	}
	for i, p := range got {
		wp := netip.MustParsePrefix(want[i])
		if p != wp {
			t.Errorf("entry %d: got %v, want %v", i, p, wp)
		}
	}
}

func TestCustomIgnoreRoutesPathEnv(t *testing.T) {
	t.Setenv("TS_IGNORE_ROUTES_FILE", "/explicit/path.conf")
	b := &LocalBackend{varRoot: t.TempDir(), logf: logger.Discard}
	if got := b.customIgnoreRoutesPath(); got != "/explicit/path.conf" {
		t.Fatalf("got %q, want /explicit/path.conf", got)
	}
}

func TestCustomIgnoreRoutesPathDefault(t *testing.T) {
	t.Setenv("TS_IGNORE_ROUTES_FILE", "")
	dir := t.TempDir()
	b := &LocalBackend{varRoot: dir, logf: logger.Discard}
	want := filepath.Join(dir, customIgnoreRoutesFilename)
	if got := b.customIgnoreRoutesPath(); got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}
