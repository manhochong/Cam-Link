package main

import (
	"bytes"
	"crypto/sha256"
	"crypto/tls"
	"embed"
	"encoding/hex"
	"encoding/json"
	"image"
	"image/jpeg"
	"io/fs"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

//go:embed ui.html logo.png
var deskFiles embed.FS

const appVersion = "0.2.25"

type fileRow struct {
	Time, Name, Size, Rate, Status string
}

type desk struct {
	mu         sync.Mutex
	ip         string
	folder     string
	running    bool
	revealed   bool
	host       string
	code       string
	finger     string
	verified   int
	active     int
	bytes      int64
	started    time.Time
	state      string
	current    string
	speed      string
	progress   int
	photo      string
	photoName  string
	photoAt    int64
	photoThumb []byte
	files      []fileRow
	qr         []string
	byID       map[string]int
	inbox      *http.Server
	quit       chan struct{}
	quitAt     time.Time
}

func desktop() error {
	d := &desk{quit: make(chan struct{}), byID: map[string]int{}}
	d.folder = d.rememberedFolder()
	liveMu.Lock()
	liveFn = d.onLive
	liveMu.Unlock()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	mux := http.NewServeMux()
	page, _ := fs.ReadFile(deskFiles, "ui.html")
	logo, _ := fs.ReadFile(deskFiles, "logo.png")
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write(page)
	})
	mux.HandleFunc("/logo", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "image/png")
		w.Write(logo)
	})
	mux.HandleFunc("/api/hello", func(w http.ResponseWriter, r *http.Request) {
		d.mu.Lock()
		d.quitAt = time.Time{}
		d.mu.Unlock()
		writeJSON(w, 200, map[string]any{"ok": true})
	})
	mux.HandleFunc("/api/state", func(w http.ResponseWriter, r *http.Request) { d.writeState(w) })
	mux.HandleFunc("/api/start", func(w http.ResponseWriter, r *http.Request) { d.start(w, r) })
	mux.HandleFunc("/api/stop", func(w http.ResponseWriter, r *http.Request) { d.stop(); writeJSON(w, 200, map[string]any{"ok": true}) })
	mux.HandleFunc("/api/reveal", func(w http.ResponseWriter, r *http.Request) {
		d.reveal()
		writeJSON(w, 200, map[string]any{"ok": true})
	})
	mux.HandleFunc("/api/browse", func(w http.ResponseWriter, r *http.Request) { d.browse(w) })
	mux.HandleFunc("/api/open", func(w http.ResponseWriter, r *http.Request) { d.openFolder(w, r) })
	mux.HandleFunc("/api/rescan", func(w http.ResponseWriter, r *http.Request) { d.rescan(w) })
	mux.HandleFunc("/api/auto", func(w http.ResponseWriter, r *http.Request) { d.setAuto(w, r) })
	mux.HandleFunc("/api/preview", func(w http.ResponseWriter, r *http.Request) { d.preview(w, r) })
	mux.HandleFunc("/api/quit", func(w http.ResponseWriter, r *http.Request) { d.armQuit(); w.WriteHeader(204) })
	mux.HandleFunc("/photo", func(w http.ResponseWriter, r *http.Request) { d.photoFile(w, r) })
	ui := &http.Server{Handler: mux}
	go ui.Serve(ln)
	url := "http://" + ln.Addr().String() + "/"
	if err = exec.Command("open", url).Start(); err != nil {
		ui.Close()
		return err
	}
	go d.watchQuit()
	if autoStartOn() {
		go func() {
			time.Sleep(600 * time.Millisecond)
			d.mu.Lock()
			folder := d.folder
			d.mu.Unlock()
			ips := ipv4s()
			if len(ips) == 0 || folder == "" || d.isRunning() {
				return
			}
			req, _ := http.NewRequest("POST", "/api/start", strings.NewReader(`{"ip":`+strconv.Quote(ips[0])+`,"folder":`+strconv.Quote(folder)+`}`))
			req.Header.Set("Content-Type", "application/json")
			d.start(&statusWriter{}, req)
		}()
	}
	<-d.quit
	d.stop()
	ui.Close()
	return nil
}

type statusWriter struct {
	code int
	hdr  http.Header
}

func (s *statusWriter) Header() http.Header {
	if s.hdr == nil {
		s.hdr = http.Header{}
	}
	return s.hdr
}
func (s *statusWriter) Write(b []byte) (int, error) { return len(b), nil }
func (s *statusWriter) WriteHeader(code int)        { s.code = code }

func (d *desk) isRunning() bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.running
}

func autoStartOn() bool {
	config, err := os.UserConfigDir()
	if err != nil {
		return false
	}
	raw, err := os.ReadFile(filepath.Join(config, "Cam Link Receiver", "auto_start.txt"))
	return err == nil && strings.TrimSpace(string(raw)) == "1"
}

func notify(title, text string) {
	_ = exec.Command("osascript", "-e", `display notification `+strconv.Quote(text)+` with title `+strconv.Quote(title)).Start()
}

func (d *desk) watchQuit() {
	for {
		time.Sleep(400 * time.Millisecond)
		d.mu.Lock()
		due := !d.quitAt.IsZero() && time.Now().After(d.quitAt)
		d.mu.Unlock()
		if due {
			close(d.quit)
			return
		}
	}
}

func (d *desk) armQuit() {
	d.mu.Lock()
	d.quitAt = time.Now().Add(1500 * time.Millisecond)
	d.mu.Unlock()
}

func (d *desk) rememberedFolder() string {
	home, err := os.UserHomeDir()
	base := ""
	if err == nil {
		base = filepath.Join(home, "Pictures", "Cam Link")
	}
	config, err := os.UserConfigDir()
	if err != nil {
		return base
	}
	raw, err := os.ReadFile(filepath.Join(config, "Cam Link Receiver", "folder.txt"))
	if err != nil || strings.TrimSpace(string(raw)) == "" {
		return base
	}
	return strings.TrimSpace(string(raw))
}

func ipv4s() []string {
	var ips []string
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return ips
	}
	for _, addr := range addrs {
		if ip, ok := addr.(*net.IPNet); ok && ip.IP.To4() != nil && !ip.IP.IsLoopback() {
			ips = append(ips, ip.IP.String())
		}
	}
	return ips
}

func (d *desk) writeState(w http.ResponseWriter) {
	d.mu.Lock()
	ips := ipv4s()
	body := map[string]any{
		"version": appVersion, "ips": ips, "ip": d.ip, "folder": d.folder, "running": d.running, "revealed": d.revealed,
		"host": d.host, "code": d.code, "finger": d.finger, "verified": d.verified, "active": d.active,
		"mb": formatMB(d.bytes), "state": d.state, "current": d.current, "speed": d.speed, "progress": d.progress,
		"photoName": d.photoName, "files": d.files, "qr": d.qr,
	}
	if d.photo != "" {
		body["photo"] = "/photo?w=1800&t=" + strconv.FormatInt(d.photoAt, 10)
	}
	body["autoStart"] = autoStartOn()
	if d.ip == "" && len(ips) > 0 {
		body["ip"] = ips[0]
	}
	if !d.running {
		body["host"] = "開始接收後顯示"
		body["code"] = "—"
		body["finger"] = "與手機畫面上的 16 位比對"
		body["qr"] = nil
	}
	d.mu.Unlock()
	writeJSON(w, 200, body)
}

func (d *desk) start(w http.ResponseWriter, r *http.Request) {
	var req struct{ IP, Folder string }
	if json.NewDecoder(r.Body).Decode(&req) != nil {
		writeJSON(w, 400, map[string]string{"error": "請選擇本機網絡及收相資料夾"})
		return
	}
	req.Folder = strings.TrimSpace(req.Folder)
	if req.IP == "" || req.Folder == "" {
		writeJSON(w, 400, map[string]string{"error": "請選擇本機網絡及收相資料夾"})
		return
	}
	if err := os.MkdirAll(req.Folder, 0755); err != nil {
		writeJSON(w, 400, map[string]string{"error": err.Error()})
		return
	}
	config, err := os.UserConfigDir()
	if err != nil {
		writeJSON(w, 400, map[string]string{"error": err.Error()})
		return
	}
	dir := filepath.Join(config, "Cam Link Receiver")
	_ = os.MkdirAll(dir, 0700)
	_ = os.WriteFile(filepath.Join(dir, "folder.txt"), []byte(req.Folder), 0600)
	id, err := profile(dir)
	if err != nil {
		writeJSON(w, 400, map[string]string{"error": err.Error()})
		return
	}
	key, err := tls.X509KeyPair(id.Cert, id.Key)
	if err != nil {
		writeJSON(w, 400, map[string]string{"error": err.Error()})
		return
	}
	ln, err := net.Listen("tcp4", net.JoinHostPort(req.IP, "9443"))
	if err != nil {
		writeJSON(w, 400, map[string]string{"error": err.Error()})
		return
	}
	sum := sha256.Sum256(key.Certificate[0])
	payload := "camlink://pair?ip=" + req.IP + "&code=" + id.Password
	modules := qrModules(payload)
	var rows []string
	for _, row := range modules {
		var b strings.Builder
		for _, on := range row {
			if on {
				b.WriteByte('1')
			} else {
				b.WriteByte('0')
			}
		}
		rows = append(rows, b.String())
	}
	srv := &http.Server{Handler: handler(req.Folder, id.Password), ReadHeaderTimeout: 8 * time.Second, ReadTimeout: 4 * time.Minute, WriteTimeout: 4 * time.Minute, MaxHeaderBytes: 8192}
	tlsLn := tls.NewListener(ln, &tls.Config{Certificates: []tls.Certificate{key}, MinVersion: tls.VersionTLS12})
	d.mu.Lock()
	if d.running {
		d.mu.Unlock()
		ln.Close()
		writeJSON(w, 400, map[string]string{"error": "已在接收"})
		return
	}
	d.running = true
	d.ip = req.IP
	d.folder = req.Folder
	d.revealed = false
	d.host = req.IP + ":9443"
	d.code = id.Password
	d.finger = strings.ToUpper(hex.EncodeToString(sum[:8]))
	d.verified, d.active = 0, 0
	d.bytes = 0
	d.started = time.Now()
	d.state = "可以接收"
	d.current = "等待手機傳來的 JPG"
	d.speed = "按「顯示 QR」配對，指紋必須相同"
	d.progress = 0
	d.photo, d.photoName = newestPhoto(req.Folder)
	d.photoThumb = nil
	if d.photo != "" {
		d.photoAt = time.Now().UnixNano()
	} else {
		d.photoAt = 0
	}
	d.files = nil
	d.byID = map[string]int{}
	d.qr = rows
	d.inbox = srv
	d.mu.Unlock()
	go srv.Serve(tlsLn)
	writeJSON(w, 200, map[string]any{"ok": true})
}

func (d *desk) setAuto(w http.ResponseWriter, r *http.Request) {
	var req struct {
		On bool `json:"on"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req)
	config, err := os.UserConfigDir()
	if err != nil {
		writeJSON(w, 400, map[string]string{"error": err.Error()})
		return
	}
	dir := filepath.Join(config, "Cam Link Receiver")
	_ = os.MkdirAll(dir, 0700)
	value := "0"
	if req.On {
		value = "1"
	}
	_ = os.WriteFile(filepath.Join(dir, "auto_start.txt"), []byte(value), 0600)
	writeJSON(w, 200, map[string]any{"ok": true, "autoStart": req.On})
}

func (d *desk) preview(w http.ResponseWriter, r *http.Request) {
	var req struct{ Name string }
	_ = json.NewDecoder(r.Body).Decode(&req)
	name := filepath.Base(strings.TrimSpace(req.Name))
	if !filename.MatchString(name) {
		writeJSON(w, 400, map[string]string{"error": "檔名無效"})
		return
	}
	d.mu.Lock()
	path := filepath.Join(d.folder, name)
	d.photo, d.photoName, d.photoThumb = path, name, nil
	d.photoAt = time.Now().UnixNano()
	d.mu.Unlock()
	writeJSON(w, 200, map[string]any{"ok": true})
}

func (d *desk) rescan(w http.ResponseWriter) {
	d.mu.Lock()
	folder := d.folder
	d.mu.Unlock()
	entries, err := os.ReadDir(folder)
	if err != nil {
		writeJSON(w, 400, map[string]string{"error": "請先選擇收相資料夾"})
		return
	}
	type item struct {
		name string
		mod  time.Time
		size int64
	}
	var found []item
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || !filename.MatchString(name) {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		found = append(found, item{name, info.ModTime(), info.Size()})
	}
	sort.Slice(found, func(i, j int) bool { return found[i].mod.After(found[j].mod) })
	d.mu.Lock()
	known := map[string]bool{}
	for i := range d.files {
		known[d.files[i].Name] = true
		if d.files[i].Status != "已核對" {
			d.files[i].Status = "已核對"
		}
	}
	added := 0
	for _, f := range found {
		if known[f.name] {
			continue
		}
		d.files = append([]fileRow{{f.mod.Format("15:04:05"), f.name, amount(f.size) + " / " + amount(f.size), "—", "已核對"}}, d.files...)
		d.verified++
		d.bytes += f.size
		added++
		known[f.name] = true
	}
	if len(found) > 0 {
		d.photo = filepath.Join(folder, found[0].name)
		d.photoName = found[0].name
		d.photoAt = time.Now().UnixNano()
		d.photoThumb = nil
		d.state = "剛核對一張"
		d.current = found[0].name
		d.speed = "已補核對資料夾內 " + itoa(int64(len(found))) + " 張"
	}
	d.mu.Unlock()
	notify("補核對完成", "資料夾內 "+itoa(int64(len(found)))+" 張 JPG")
	writeJSON(w, 200, map[string]any{"ok": true, "count": len(found), "added": added})
}

func (d *desk) stop() {
	d.mu.Lock()
	srv := d.inbox
	d.inbox = nil
	got := d.verified
	d.running = false
	d.revealed = false
	d.qr = nil
	d.host, d.code, d.finger = "", "", ""
	d.progress = 0
	d.speed = ""
	if got > 0 {
		d.state = "接收已停止"
		d.current = "已停止。已核對的 JPG 留在資料夾。"
	} else {
		d.state = ""
		d.current = "照片會出現在左邊"
	}
	d.mu.Unlock()
	if srv != nil {
		srv.Close()
	}
}

func (d *desk) reveal() {
	d.mu.Lock()
	if d.running {
		d.revealed = !d.revealed
	}
	d.mu.Unlock()
}

func (d *desk) browse(w http.ResponseWriter) {
	path, err := script("POSIX path of (choose folder with prompt \"選擇儲存 Cam Link 原圖的資料夾\")")
	if err != nil || path == "" {
		writeJSON(w, 200, map[string]string{"folder": ""})
		return
	}
	d.mu.Lock()
	if !d.running {
		d.folder = path
	}
	d.mu.Unlock()
	writeJSON(w, 200, map[string]string{"folder": path})
}

func (d *desk) openFolder(w http.ResponseWriter, r *http.Request) {
	var req struct{ Folder string }
	_ = json.NewDecoder(r.Body).Decode(&req)
	path := strings.TrimSpace(req.Folder)
	if path == "" {
		d.mu.Lock()
		path = d.folder
		d.mu.Unlock()
	}
	if path == "" {
		writeJSON(w, 400, map[string]string{"error": "請先選擇收相資料夾"})
		return
	}
	if err := os.MkdirAll(path, 0755); err != nil {
		writeJSON(w, 400, map[string]string{"error": err.Error()})
		return
	}
	if err := exec.Command("open", path).Start(); err != nil {
		writeJSON(w, 400, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true})
}

func (d *desk) photoFile(w http.ResponseWriter, r *http.Request) {
	d.mu.Lock()
	path, folder, stamp, cached := d.photo, d.folder, d.photoAt, d.photoThumb
	d.mu.Unlock()
	clean, root := filepath.Clean(path), filepath.Clean(folder)
	rel, err := filepath.Rel(root, clean)
	if path == "" || err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		http.NotFound(w, r)
		return
	}
	max := 1800
	if raw := r.URL.Query().Get("w"); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil && n >= 320 && n <= 4000 {
			max = n
		}
	}
	if len(cached) > 0 {
		w.Header().Set("Content-Type", "image/jpeg")
		w.Header().Set("Cache-Control", "no-store")
		w.Write(cached)
		return
	}
	if thumb, err := jpegPreview(clean, max); err == nil {
		d.mu.Lock()
		if d.photoAt == stamp && d.photo == path {
			d.photoThumb = thumb
		}
		d.mu.Unlock()
		w.Header().Set("Content-Type", "image/jpeg")
		w.Header().Set("Cache-Control", "no-store")
		w.Write(thumb)
		return
	}
	http.ServeFile(w, r, clean)
}

func jpegPreview(path string, max int) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	img, err := jpeg.Decode(file)
	if err != nil {
		return nil, err
	}
	bounds := img.Bounds()
	width, height := bounds.Dx(), bounds.Dy()
	longest := width
	if height > longest {
		longest = height
	}
	if longest <= max {
		var buf bytes.Buffer
		if err = jpeg.Encode(&buf, img, &jpeg.Options{Quality: 85}); err != nil {
			return nil, err
		}
		return buf.Bytes(), nil
	}
	nw := width * max / longest
	nh := height * max / longest
	if nw < 1 {
		nw = 1
	}
	if nh < 1 {
		nh = 1
	}
	out := image.NewRGBA(image.Rect(0, 0, nw, nh))
	for y := 0; y < nh; y++ {
		sy := bounds.Min.Y + y*height/nh
		for x := 0; x < nw; x++ {
			sx := bounds.Min.X + x*width/nw
			out.Set(x, y, img.At(sx, sy))
		}
	}
	var buf bytes.Buffer
	if err = jpeg.Encode(&buf, out, &jpeg.Options{Quality: 85}); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func (d *desk) onLive(id, name string, got, size int64, finished, ok bool, started time.Time) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if !d.running {
		return
	}
	index, exists := d.byID[id]
	if !exists {
		d.files = append([]fileRow{{time.Now().Format("15:04:05"), name, "", "", "接收中"}}, d.files...)
		for k, v := range d.byID {
			d.byID[k] = v + 1
		}
		d.byID[id] = 0
		index = 0
		d.active++
	}
	row := &d.files[index]
	row.Size = amount(got) + " / " + amount(size)
	sec := time.Since(started).Seconds()
	if sec < 0.05 {
		sec = 0.05
	}
	row.Rate = trimRate(float64(got) / 1048576.0 / sec)
	_, done := d.byID[id+"#done"]
	if finished && !done {
		d.byID[id+"#done"] = 1
		if ok {
			row.Status = "已核對"
		} else {
			row.Status = "未核對"
		}
		if d.active > 0 {
			d.active--
		}
		if ok {
			d.verified++
			d.bytes += size
			d.photo = filepath.Join(d.folder, name)
			d.photoName = name
			d.photoAt = time.Now().UnixNano()
			d.photoThumb = nil
			if d.verified == 1 {
				go notify("第一張已核對", name)
			}
		} else {
			go notify("需處理", name+" 未核對")
		}
	} else if !done {
		row.Status = "接收中"
	}
	if finished && d.active == 0 && d.verified > 0 {
		go notify("本輪傳完", "已核對 "+itoa(int64(d.verified))+" 張")
	}
	span := time.Since(d.started).Seconds()
	if span < 0.05 {
		span = 0.05
	}
	if d.active > 0 {
		d.state = "正在接收"
	} else if d.verified > 0 {
		d.state = "剛核對一張"
	} else {
		d.state = "可以接收"
	}
	d.current = name
	d.speed = amount(got) + " / " + amount(size) + "    " + trimRate(float64(got)/1048576.0/sec) + "    全程 " + trimRate(float64(d.bytes)/1048576.0/span)
	if size > 0 {
		d.progress = int(float64(got) / float64(size) * 100)
		if d.progress > 100 {
			d.progress = 100
		}
	}
}

func newestPhoto(folder string) (string, string) {
	entries, err := os.ReadDir(folder)
	if err != nil {
		return "", ""
	}
	var best string
	var bestTime time.Time
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || !filename.MatchString(name) {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		if best == "" || info.ModTime().After(bestTime) {
			best, bestTime = name, info.ModTime()
		}
	}
	if best == "" {
		return "", ""
	}
	return filepath.Join(folder, best), best
}

func amount(n int64) string {
	if n >= 1048576 {
		return trimFixed(float64(n)/1048576.0) + " MB"
	}
	if n < 0 {
		n = 0
	}
	return itoa(n/1024) + " KB"
}

func formatMB(n int64) string { return trimFixed(float64(n) / 1048576.0) }

func trimRate(v float64) string { return trimFixed(v) + " MB/s" }

func trimFixed(v float64) string {
	s := strings.TrimRight(strings.TrimRight(sprintf1(v), "0"), ".")
	if s == "" {
		return "0.0"
	}
	if !strings.Contains(s, ".") {
		return s + ".0"
	}
	return s
}

func sprintf1(v float64) string {
	neg := v < 0
	if neg {
		v = -v
	}
	n := int64(v*10 + 0.5)
	s := itoa(n / 10)
	s += "." + itoa(n%10)
	if neg {
		return "-" + s
	}
	return s
}

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(body)
}
