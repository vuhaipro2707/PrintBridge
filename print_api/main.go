package main

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type RouteConfig struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	WatchDir string `json:"watch_dir"`
}

type Config struct {
	ListenAddr  string        `json:"listen_addr"`
	APIKey      string        `json:"api_key"`
	MaxUploadMB int64         `json:"max_upload_mb"`
	Routes      []RouteConfig `json:"routes"`
}

type routeInfo struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	PendingCount int    `json:"pending_count"`
}

type server struct {
	routesByKey map[string]RouteConfig
	routesOrder []RouteConfig
	apiKey      string
	maxBytes    int64
	seq         atomic.Uint64
	convertMu   sync.Mutex
}

var unsafeNameChars = regexp.MustCompile(`[^a-zA-Z0-9._-]+`)

func loadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("không đọc được %s: %w", path, err)
	}
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("lỗi cú pháp JSON trong %s: %w", path, err)
	}
	if strings.TrimSpace(cfg.ListenAddr) == "" {
		cfg.ListenAddr = ":8080"
	}
	if envPort := strings.TrimSpace(os.Getenv("LISTEN_ADDR")); envPort != "" {
		cfg.ListenAddr = envPort
	}
	if envKey, ok := os.LookupEnv("API_KEY"); ok {
		cfg.APIKey = strings.TrimSpace(envKey)
	}
	if cfg.MaxUploadMB <= 0 {
		cfg.MaxUploadMB = 50
	}
	if len(cfg.Routes) == 0 {
		return nil, errors.New("cấu hình chưa có route nào trong 'routes'")
	}
	return &cfg, nil
}

func newServer(cfg *Config, baseDir string) (*server, error) {
	s := &server{
		routesByKey: make(map[string]RouteConfig),
		apiKey:      strings.TrimSpace(cfg.APIKey),
		maxBytes:    cfg.MaxUploadMB * 1024 * 1024,
	}

	for i, r := range cfg.Routes {
		id := strings.TrimSpace(r.ID)
		name := strings.TrimSpace(r.Name)
		if id == "" {
			id = fmt.Sprintf("route_%d", i+1)
		}
		if name == "" {
			name = id
		}
		if strings.TrimSpace(r.WatchDir) == "" {
			return nil, fmt.Errorf("route '%s' thiếu watch_dir", id)
		}

		watchDir := r.WatchDir
		if !filepath.IsAbs(watchDir) {
			watchDir = filepath.Clean(filepath.Join(baseDir, watchDir))
		}
		if err := os.MkdirAll(watchDir, 0755); err != nil {
			return nil, fmt.Errorf("không tạo được thư mục '%s': %w", watchDir, err)
		}

		resolved := RouteConfig{
			ID:       id,
			Name:     name,
			WatchDir: watchDir,
		}
		s.routesOrder = append(s.routesOrder, resolved)
		s.routesByKey[strings.ToLower(id)] = resolved
		s.routesByKey[strings.ToLower(name)] = resolved
	}

	return s, nil
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func (s *server) withMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, X-API-Key, Authorization")

		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}

		// /health luôn mở để Docker/load balancer check sống chết
		if r.URL.Path != "/health" && s.apiKey != "" {
			provided := strings.TrimSpace(r.Header.Get("X-API-Key"))
			if provided == "" {
				auth := strings.TrimSpace(r.Header.Get("Authorization"))
				if strings.HasPrefix(strings.ToLower(auth), "bearer ") {
					provided = strings.TrimSpace(auth[7:])
				}
			}
			if subtle.ConstantTimeCompare([]byte(provided), []byte(s.apiKey)) != 1 {
				writeJSON(w, http.StatusUnauthorized, map[string]string{
					"error": "Thiếu hoặc sai API Key",
				})
				return
			}
		}

		next.ServeHTTP(w, r)
	})
}

func countPendingPDFs(dir string) int {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0
	}
	count := 0
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(strings.ToLower(e.Name()), ".pdf") {
			count++
		}
	}
	return count
}

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"status":       "ok",
		"auth_enabled": s.apiKey != "",
		"routes_count": len(s.routesOrder),
	})
}

func (s *server) handleRoutes(w http.ResponseWriter, r *http.Request) {
	list := make([]routeInfo, 0, len(s.routesOrder))
	for _, rt := range s.routesOrder {
		list = append(list, routeInfo{
			ID:           rt.ID,
			Name:         rt.Name,
			PendingCount: countPendingPDFs(rt.WatchDir),
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"routes": list,
	})
}

func sanitizeStem(filename string) string {
	base := filepath.Base(filename)
	ext := filepath.Ext(base)
	stem := strings.TrimSuffix(base, ext)
	stem = unsafeNameChars.ReplaceAllString(stem, "_")
	stem = strings.Trim(stem, "._-")
	if stem == "" {
		stem = "document"
	}
	if len(stem) > 60 {
		stem = stem[:60]
	}
	return stem
}

func isOfficeExtension(ext string) bool {
	switch strings.ToLower(ext) {
	case ".doc", ".docx", ".xls", ".xlsx":
		return true
	default:
		return false
	}
}

func findSofficeBinary() string {
	for _, name := range []string{"soffice", "libreoffice"} {
		if p, err := exec.LookPath(name); err == nil {
			return p
		}
	}
	return ""
}

func (s *server) convertOfficeToPDF(ctx context.Context, inputBytes []byte, originalName string) ([]byte, error) {
	bin := findSofficeBinary()
	if bin == "" {
		return nil, errors.New("server chưa cài LibreOffice (soffice) để chuyển Word/Excel sang PDF")
	}

	tmpDir, err := os.MkdirTemp("", "lo_convert_*")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(tmpDir)

	ext := strings.ToLower(filepath.Ext(originalName))
	stem := sanitizeStem(originalName)
	inputPath := filepath.Join(tmpDir, stem+ext)
	if err := os.WriteFile(inputPath, inputBytes, 0600); err != nil {
		return nil, err
	}

	profileDir := filepath.Join(tmpDir, "profile")
	if err := os.MkdirAll(profileDir, 0700); err != nil {
		return nil, err
	}

	// LibreOffice headless dùng chung profile dễ lỗi lock nếu chạy song song.
	s.convertMu.Lock()
	defer s.convertMu.Unlock()

	cmdCtx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()

	cmd := exec.CommandContext(
		cmdCtx,
		bin,
		"--headless",
		"--norestore",
		"--nofirststartwizard",
		"-env:UserInstallation=file://"+profileDir,
		"--convert-to",
		"pdf",
		"--outdir",
		tmpDir,
		inputPath,
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("LibreOffice lỗi (%v): %s", err, strings.TrimSpace(string(out)))
	}

	pdfPath := filepath.Join(tmpDir, stem+".pdf")
	pdfBytes, err := os.ReadFile(pdfPath)
	if err != nil {
		return nil, fmt.Errorf("không tìm thấy file PDF sau khi chuyển đổi: %w", err)
	}
	if !bytes.HasPrefix(pdfBytes, []byte("%PDF-")) {
		return nil, errors.New("file chuyển đổi không phải PDF hợp lệ")
	}
	return pdfBytes, nil
}

func (s *server) handleConvert(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, s.maxBytes+1024*1024)
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": fmt.Sprintf("Dữ liệu upload không hợp lệ hoặc vượt quá %dMB", s.maxBytes/(1024*1024)),
		})
		return
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "Thiếu trường 'file'",
		})
		return
	}
	defer file.Close()

	ext := strings.ToLower(filepath.Ext(header.Filename))
	rawBytes, err := io.ReadAll(io.LimitReader(file, s.maxBytes+1))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "Không đọc được nội dung file",
		})
		return
	}
	if int64(len(rawBytes)) > s.maxBytes {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": fmt.Sprintf("File vượt quá giới hạn %dMB", s.maxBytes/(1024*1024)),
		})
		return
	}

	var pdfBytes []byte
	if ext == ".pdf" {
		if !bytes.HasPrefix(rawBytes, []byte("%PDF-")) {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "File không phải PDF hợp lệ",
			})
			return
		}
		pdfBytes = rawBytes
	} else if isOfficeExtension(ext) {
		converted, err := s.convertOfficeToPDF(r.Context(), rawBytes, header.Filename)
		if err != nil {
			log.Printf("❌ Lỗi convert %s: %v", header.Filename, err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{
				"error": err.Error(),
			})
			return
		}
		pdfBytes = converted
		log.Printf("🔄 Đã chuyển %s (%d bytes) -> PDF (%d bytes)", header.Filename, len(rawBytes), len(pdfBytes))
	} else {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "Chỉ hỗ trợ .pdf, .doc, .docx, .xls, .xlsx",
		})
		return
	}

	outName := sanitizeStem(header.Filename) + ".pdf"
	w.Header().Set("Content-Type", "application/pdf")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, outName))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(pdfBytes)
}

func (s *server) handlePrint(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, s.maxBytes+1024*1024)
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": fmt.Sprintf("Dữ liệu upload không hợp lệ hoặc vượt quá %dMB", s.maxBytes/(1024*1024)),
		})
		return
	}

	routeKey := strings.TrimSpace(r.FormValue("route"))
	if routeKey == "" {
		routeKey = strings.TrimSpace(r.FormValue("printer"))
	}
	if routeKey == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "Thiếu tham số 'route' (mã máy in)",
		})
		return
	}

	route, ok := s.routesByKey[strings.ToLower(routeKey)]
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{
			"error": fmt.Sprintf("Không tìm thấy route '%s'", routeKey),
		})
		return
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "Thiếu trường 'file'",
		})
		return
	}
	defer file.Close()

	ext := strings.ToLower(filepath.Ext(header.Filename))
	if ext != ".pdf" && !isOfficeExtension(ext) {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "Chỉ chấp nhận file .pdf, .doc, .docx, .xls, .xlsx",
		})
		return
	}

	rawBytes, err := io.ReadAll(io.LimitReader(file, s.maxBytes+1))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "Không đọc được nội dung file",
		})
		return
	}
	if int64(len(rawBytes)) > s.maxBytes {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": fmt.Sprintf("File vượt quá giới hạn %dMB", s.maxBytes/(1024*1024)),
		})
		return
	}

	var pdfBytes []byte
	if ext == ".pdf" {
		if !bytes.HasPrefix(rawBytes, []byte("%PDF-")) {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "File không phải PDF hợp lệ",
			})
			return
		}
		pdfBytes = rawBytes
	} else {
		converted, err := s.convertOfficeToPDF(r.Context(), rawBytes, header.Filename)
		if err != nil {
			log.Printf("❌ Lỗi convert %s: %v", header.Filename, err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{
				"error": err.Error(),
			})
			return
		}
		pdfBytes = converted
	}

	seq := s.seq.Add(1)
	finalName := fmt.Sprintf("%s_%04d_%s.pdf", time.Now().Format("20060102_150405"), seq%10000, sanitizeStem(header.Filename))
	finalPath := filepath.Join(route.WatchDir, finalName)
	tmpPath := finalPath + ".tmp"

	if err := os.WriteFile(tmpPath, pdfBytes, 0644); err != nil {
		_ = os.Remove(tmpPath)
		log.Printf("❌ Lỗi ghi file %s: %v", tmpPath, err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{
			"error": "Lỗi ghi dữ liệu file PDF",
		})
		return
	}

	if err := os.Rename(tmpPath, finalPath); err != nil {
		_ = os.Remove(tmpPath)
		log.Printf("❌ Lỗi rename %s -> %s: %v", tmpPath, finalPath, err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{
			"error": "Không thể hoàn tất lưu file vào hàng đợi in",
		})
		return
	}

	log.Printf("📥 [%s] Nhận %s -> %s (%d bytes)", route.Name, header.Filename, finalName, len(pdfBytes))

	writeJSON(w, http.StatusCreated, map[string]any{
		"status":     "queued",
		"route":      route.ID,
		"route_name": route.Name,
		"job_file":   finalName,
		"size_bytes": len(pdfBytes),
	})
}

func main() {
	wd, _ := os.Getwd()
	defaultCfg := filepath.Join(wd, "config.json")
	cfgPath := flag.String("config", defaultCfg, "Đường dẫn file cấu hình JSON")
	flag.Parse()

	cfg, err := loadConfig(*cfgPath)
	if err != nil {
		log.Fatalf("❌ Lỗi cấu hình: %v", err)
	}

	srv, err := newServer(cfg, filepath.Dir(*cfgPath))
	if err != nil {
		log.Fatalf("❌ Lỗi khởi tạo server: %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", srv.handleHealth)
	mux.HandleFunc("GET /api/routes", srv.handleRoutes)
	mux.HandleFunc("POST /api/convert", srv.handleConvert)
	mux.HandleFunc("POST /api/print", srv.handlePrint)

	log.Printf("🚀 Print API đang lắng nghe tại %s (auth=%v, libreoffice=%v)", cfg.ListenAddr, srv.apiKey != "", findSofficeBinary() != "")
	for _, rt := range srv.routesOrder {
		log.Printf("📂 [%s] (%s) -> %s", rt.ID, rt.Name, rt.WatchDir)
	}

	if err := http.ListenAndServe(cfg.ListenAddr, srv.withMiddleware(mux)); err != nil {
		log.Fatalf("❌ Server dừng lỗi: %v", err)
	}
}
