package main

import (
	"crypto/sha256"
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDelivery(t *testing.T) {
	dir := t.TempDir()
	h := handler(dir, "fixture")
	original := "fixture-original"
	sum := fmt.Sprintf("%x", sha256.Sum256([]byte(original)))
	for _, c := range []struct {
		body, sha, pass string
		status          int
	}{{original, sum, "wrong", 401}, {original, sum, "fixture", 201}, {original, sum, "fixture", 201}, {"different", sum, "fixture", 422}, {"new", fmt.Sprintf("%x", sha256.Sum256([]byte("new"))), "fixture", 409}} {
		req := httptest.NewRequest("PUT", "/inbox/photo.JPG", strings.NewReader(c.body))
		req.SetBasicAuth("camlink", c.pass)
		req.Header.Set("X-CamLink-SHA256", c.sha)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		if w.Code != c.status {
			t.Fatalf("got %d want %d", w.Code, c.status)
		}
	}
	p, e := os.ReadFile(filepath.Join(dir, "photo.JPG"))
	if e != nil || string(p) != original {
		t.Fatal("original changed")
	}
}
