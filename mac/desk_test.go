package main

import (
	"bytes"
	"image"
	"image/jpeg"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestQRMatchesPairPayload(t *testing.T) {
	text := "camlink://pair?ip=192.168.1.20&code=ab12cd34ef56"
	modules := qrModules(text)
	if modules == nil || len(modules) != 33 || len(modules[0]) != 33 {
		t.Fatalf("version 4 square, got %d", len(modules))
	}
	if !modules[0][0] || modules[1][1] || !modules[2][2] {
		t.Fatal("finder pattern")
	}
	if qrModules(text+"0123456789abcdef") != nil {
		t.Fatal("over 62 bytes must be refused")
	}
}

func TestLiveRound(t *testing.T) {
	start := time.Now()
	d := &desk{byID: map[string]int{}, folder: t.TempDir(), running: true, started: start}
	d.onLive("a", "a.JPG", 0, 100, false, false, start)
	d.onLive("a", "a.JPG", 100, 100, true, true, start)
	if d.verified != 1 || d.active != 0 || d.bytes != 100 || len(d.files) != 1 || d.files[0].Status != "已核對" {
		t.Fatalf("verified %d active %d bytes %d files %+v", d.verified, d.active, d.bytes, d.files)
	}
	d.onLive("b", "b.JPG", 50, 200, false, false, start)
	if d.active != 1 || d.files[0].Name != "b.JPG" || d.files[1].Name != "a.JPG" {
		t.Fatalf("%+v active %d", d.files, d.active)
	}
	d.onLive("b", "b.JPG", 200, 200, true, false, start)
	if d.verified != 1 || d.active != 0 || d.files[0].Status != "未核對" {
		t.Fatalf("verified %d active %d %+v", d.verified, d.active, d.files)
	}
	d.onLive("a", "a.JPG", 100, 100, false, false, start)
	if d.files[1].Status != "已核對" || d.verified != 1 {
		t.Fatalf("verified mark lost %+v", d.files)
	}
}

func TestJpegPreview(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "tiny.JPG")
	img := image.NewRGBA(image.Rect(0, 0, 40, 30))
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 90}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, buf.Bytes(), 0644); err != nil {
		t.Fatal(err)
	}
	out, err := jpegPreview(path, 1800)
	if err != nil || len(out) == 0 {
		t.Fatalf("preview %v len=%d", err, len(out))
	}
}

func TestNewestPhoto(t *testing.T) {
	dir := t.TempDir()
	older := filepath.Join(dir, "older.JPG")
	newer := filepath.Join(dir, "newer.JPG")
	if err := os.WriteFile(older, []byte("a"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(newer, []byte("b"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "note.txt"), []byte("x"), 0644); err != nil {
		t.Fatal(err)
	}
	oldTime := time.Now().Add(-2 * time.Hour)
	newTime := time.Now().Add(-time.Minute)
	if err := os.Chtimes(older, oldTime, oldTime); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(newer, newTime, newTime); err != nil {
		t.Fatal(err)
	}
	path, name := newestPhoto(dir)
	if name != "newer.JPG" || path != newer {
		t.Fatalf("got %s %s", path, name)
	}
}
