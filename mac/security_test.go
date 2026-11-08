package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestDesktopSessionProtection(t *testing.T) {
	const host = "127.0.0.1:12345"
	const token = "test-session-token"
	h := protectDesktop(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }), host, token)
	for _, c := range []struct {
		name, method, path, requestHost, origin, header string
		want                                            int
	}{
		{"page", "GET", "/", host, "", "", 204},
		{"missing-token", "GET", "/api/state", host, "", "", 403},
		{"valid-state", "GET", "/api/state", host, "", token, 204},
		{"cross-origin", "POST", "/api/stop", host, "https://example.invalid", token, 403},
		{"wrong-host", "GET", "/", "attacker.invalid:12345", "", "", 403},
		{"get-mutation", "GET", "/api/stop", host, "", token, 405},
		{"valid-mutation", "POST", "/api/stop", host, "http://" + host, token, 204},
		{"photo-token", "GET", "/photo?session=" + token, host, "", "", 204},
		{"photo-missing-token", "GET", "/photo", host, "", "", 403},
		{"quit-token", "POST", "/api/quit?session=" + token, host, "http://" + host, "", 204},
		{"quit-missing-token", "POST", "/api/quit", host, "", "", 403},
	} {
		t.Run(c.name, func(t *testing.T) {
			r := httptest.NewRequest(c.method, c.path, nil)
			r.Host = c.requestHost
			r.Header.Set("Origin", c.origin)
			r.Header.Set("X-CamLink-UI-Token", c.header)
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if w.Code != c.want {
				t.Fatalf("got %d want %d", w.Code, c.want)
			}
		})
	}
}

func TestRescanDoesNotClaimTransferVerification(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "manual.JPG"), []byte("local file without receipt"), 0600); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	d := &desk{byID: map[string]int{}, folder: dir, running: true, started: start}
	d.onLive("active", "pending.JPG", 0, 20, false, false, start)
	w := httptest.NewRecorder()
	d.rescan(w)
	if w.Code != 200 || d.verified != 0 || d.bytes != 0 {
		t.Fatalf("rescan falsely verified: %+v", d.files)
	}
	if d.files[0].Status != "接收中" || d.files[1].Status != "本機檔案" {
		t.Fatalf("unexpected statuses %+v", d.files)
	}
	d.onLive("active", "pending.JPG", 20, 20, true, false, start)
	if d.files[0].Status != "未核對" || d.files[1].Status != "本機檔案" {
		t.Fatalf("rescan corrupted transfer row indexes %+v", d.files)
	}
	d.rescan(httptest.NewRecorder())
	if d.verified != 0 || d.files[0].Status != "未核對" {
		t.Fatal("rescan changed a failed transfer to verified")
	}
}

func TestReceiverHandshakeAndInvalidPaths(t *testing.T) {
	h := handler(t.TempDir(), "fixture")
	for _, c := range []struct {
		method, path string
		want         int
	}{
		{"HEAD", "/inbox/", 200},
		{"GET", "/inbox/photo.JPG", 405},
		{"PUT", "/inbox/../escape.JPG", 400},
		{"PUT", "/other/photo.JPG", 400},
	} {
		r := httptest.NewRequest(c.method, c.path, strings.NewReader("x"))
		r.SetBasicAuth("camlink", "fixture")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != c.want {
			t.Fatalf("%s %s got %d want %d", c.method, c.path, w.Code, c.want)
		}
		if c.want == 200 && w.Header().Get("X-CamLink-Receiver") != "1" {
			t.Fatal("missing receiver handshake")
		}
	}
}

func TestFileRowsMatchDesktopJSON(t *testing.T) {
	d := &desk{files: []fileRow{{Time: "12:00:00", Name: "photo.JPG", Size: "1 MB", Rate: "2 MB/s", Status: "已核對"}}}
	w := httptest.NewRecorder()
	d.writeState(w)
	var state struct {
		Files []map[string]string `json:"files"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &state); err != nil {
		t.Fatal(err)
	}
	if len(state.Files) != 1 {
		t.Fatal("missing file row")
	}
	for _, key := range []string{"time", "name", "size", "rate", "status"} {
		if state.Files[0][key] == "" {
			t.Fatalf("desktop field %s missing: %s", key, w.Body.String())
		}
	}
}
