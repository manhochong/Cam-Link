package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

var (
	liveMu sync.Mutex
	liveFn func(id, name string, got, size int64, finished, ok bool, started time.Time)
)

func reportLive(id, name string, got, size int64, finished, ok bool, started time.Time) {
	liveMu.Lock()
	fn := liveFn
	liveMu.Unlock()
	if fn != nil {
		fn(id, name, got, size, finished, ok, started)
	}
}

type identity struct {
	Cert, Key []byte
	Password  string
}

var filename = regexp.MustCompile("(?i)^[a-z0-9][a-z0-9_.-]{0,190}\\.jpe?g$")

func profile(dir string) (id identity, err error) {
	if err = os.MkdirAll(dir, 0700); err != nil {
		return
	}
	name := filepath.Join(dir, "identity.json")
	raw, e := os.ReadFile(name)
	if e == nil {
		err = json.Unmarshal(raw, &id)
		return
	}
	if !os.IsNotExist(e) {
		err = e
		return
	}
	key, e := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if e != nil {
		return id, e
	}
	serial, e := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	if e != nil {
		return id, e
	}
	cert := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: "Cam Link Receiver"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().AddDate(5, 0, 0), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, e := x509.CreateCertificate(rand.Reader, cert, cert, &key.PublicKey, key)
	if e != nil {
		return id, e
	}
	k, e := x509.MarshalPKCS8PrivateKey(key)
	if e != nil {
		return id, e
	}
	secret := make([]byte, 6)
	if _, e = rand.Read(secret); e != nil {
		return id, e
	}
	id = identity{pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: k}), hex.EncodeToString(secret)}
	tmp, e := os.CreateTemp(dir, ".identity-")
	if e != nil {
		return id, e
	}
	defer os.Remove(tmp.Name())
	e = json.NewEncoder(tmp).Encode(id)
	closeErr := tmp.Close()
	if e != nil {
		return id, e
	}
	if closeErr != nil {
		return id, closeErr
	}
	return id, os.Link(tmp.Name(), name)
}

func handler(dir, password string) http.Handler {
	slots := make(chan struct{}, 3)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case slots <- struct{}{}:
			defer func() { <-slots }()
		default:
			w.WriteHeader(503)
			return
		}
		u, p, ok := r.BasicAuth()
		if !ok || u != "camlink" || subtle.ConstantTimeCompare([]byte(p), []byte(password)) != 1 {
			w.WriteHeader(401)
			return
		}
		if r.Method == "HEAD" && r.URL.Path == "/inbox/" {
			w.Header().Set("X-CamLink-Receiver", "1")
			w.WriteHeader(200)
			return
		}
		name, ok := strings.CutPrefix(r.URL.Path, "/inbox/")
		if !ok {
			w.WriteHeader(400)
			return
		}
		if decoded, err := url.PathUnescape(name); err == nil {
			name = decoded
		}
		if !filename.MatchString(name) {
			w.WriteHeader(400)
			return
		}
		if r.Method != "PUT" {
			w.WriteHeader(405)
			return
		}
		expected := r.Header.Get("X-CamLink-SHA256")
		digest, e := hex.DecodeString(expected)
		if e != nil || len(digest) != 32 || r.ContentLength <= 0 || r.ContentLength > 512<<20 {
			w.WriteHeader(400)
			return
		}
		tmp, e := os.CreateTemp(dir, ".camlink-*.part")
		if e != nil {
			w.WriteHeader(507)
			return
		}
		defer os.Remove(tmp.Name())
		id := hex.EncodeToString([]byte(time.Now().Format("150405.000000")))
		started := time.Now()
		reportLive(id, name, 0, r.ContentLength, false, false, started)
		n, e := copyProgress(tmp, r.Body, r.ContentLength, func(got int64) {
			reportLive(id, name, got, r.ContentLength, false, false, started)
		})
		if e == nil {
			e = tmp.Sync()
		}
		closeErr := tmp.Close()
		if e != nil || closeErr != nil || n != r.ContentLength {
			reportLive(id, name, n, r.ContentLength, true, false, started)
			w.WriteHeader(422)
			return
		}
		verify := func(path string) bool {
			f, e := os.Open(path)
			if e != nil {
				return false
			}
			defer f.Close()
			h := sha256.New()
			n, e := io.Copy(h, f)
			return e == nil && n == r.ContentLength && hex.EncodeToString(h.Sum(nil)) == expected
		}
		if !verify(tmp.Name()) {
			reportLive(id, name, n, r.ContentLength, true, false, started)
			w.WriteHeader(422)
			return
		}
		final := filepath.Join(dir, name)
		if e = os.Link(tmp.Name(), final); e != nil {
			if !os.IsExist(e) || !verify(final) {
				reportLive(id, name, n, r.ContentLength, true, false, started)
				w.WriteHeader(409)
				return
			}
		}
		reportLive(id, name, r.ContentLength, r.ContentLength, true, true, started)
		w.Header().Set("X-CamLink-SHA256", expected)
		w.WriteHeader(201)
	})
}

func copyProgress(dst io.Writer, src io.Reader, total int64, tick func(int64)) (int64, error) {
	buf := make([]byte, 128*1024)
	var got int64
	last := time.Now()
	for got < total {
		want := total - got
		if want > int64(len(buf)) {
			want = int64(len(buf))
		}
		nr, er := src.Read(buf[:want])
		if nr > 0 {
			nw, ew := dst.Write(buf[:nr])
			got += int64(nw)
			if tick != nil && time.Since(last) >= 160*time.Millisecond {
				last = time.Now()
				tick(got)
			}
			if ew != nil {
				return got, ew
			}
			if nw != nr {
				return got, io.ErrShortWrite
			}
		}
		if er != nil {
			if er == io.EOF {
				break
			}
			return got, er
		}
	}
	if tick != nil {
		tick(got)
	}
	if got != total {
		return got, io.ErrUnexpectedEOF
	}
	return got, nil
}

func script(source string, args ...string) (string, error) {
	cmd := append([]string{"-e", source, "--"}, args...)
	data, err := exec.Command("/usr/bin/osascript", cmd...).Output()
	return strings.TrimSpace(string(data)), err
}
func main() {
	if err := desktop(); err != nil {
		script("on run argv\ndisplay alert \"Cam Link 無法接收\" message (item 1 of argv)\nend run", err.Error())
	}
}
