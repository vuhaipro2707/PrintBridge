package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/alexbrainman/printer"
	"github.com/fsnotify/fsnotify"
)

// RouteConfig định nghĩa một cặp thư mục theo dõi <-> máy in đích.
type RouteConfig struct {
	Name             string `json:"name"`
	WatchDir         string `json:"watch_dir"`
	TargetPrinter    string `json:"target_printer"`
	DeleteAfterPrint *bool  `json:"delete_after_print,omitempty"`
}

func (r RouteConfig) shouldDeleteAfterPrint() bool {
	if r.DeleteAfterPrint == nil {
		return true
	}
	return *r.DeleteAfterPrint
}

func (r RouteConfig) displayName() string {
	if strings.TrimSpace(r.Name) != "" {
		return r.Name
	}
	return r.TargetPrinter
}

// Config chứa toàn bộ cấu hình của multi-printer daemon.
type Config struct {
	LogDir           string        `json:"log_dir"`
	LogFile          string        `json:"log_file"`
	PDFToPrinterPath string        `json:"pdf_to_printer_path"`
	Routes           []RouteConfig `json:"routes"`
}

type printJob struct {
	filePath string
	route    RouteConfig
}

type daemon struct {
	baseDir          string
	pdfToPrinterPath string
	routesByDir      map[string]RouteConfig
	printerQueues    map[string]chan printJob

	inFlightMu sync.Mutex
	inFlight   map[string]struct{}

	workersWg sync.WaitGroup
}

func getBaseDir() string {
	exePath, err := os.Executable()
	if err != nil {
		wd, _ := os.Getwd()
		return wd
	}
	return filepath.Dir(exePath)
}

func resolvePath(baseDir, p string) string {
	if p == "" {
		return ""
	}
	if filepath.IsAbs(p) {
		return filepath.Clean(p)
	}
	return filepath.Clean(filepath.Join(baseDir, p))
}

func normalizeKey(p string) string {
	return strings.ToLower(filepath.Clean(p))
}

func loadConfig(configPath string) (*Config, error) {
	data, err := os.ReadFile(configPath)
	if err != nil {
		return nil, fmt.Errorf("không đọc được file cấu hình %s: %w", configPath, err)
	}

	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("lỗi cú pháp JSON trong %s: %w", configPath, err)
	}

	if cfg.LogDir == "" {
		cfg.LogDir = "logs"
	}
	if cfg.LogFile == "" {
		cfg.LogFile = "agent_log.txt"
	}
	if len(cfg.Routes) == 0 {
		return nil, fmt.Errorf("file cấu hình chưa có route nào trong mục 'routes'")
	}

	for i, r := range cfg.Routes {
		if strings.TrimSpace(r.WatchDir) == "" {
			return nil, fmt.Errorf("route #%d thiếu 'watch_dir'", i+1)
		}
		if strings.TrimSpace(r.TargetPrinter) == "" {
			return nil, fmt.Errorf("route #%d thiếu 'target_printer'", i+1)
		}
	}

	return &cfg, nil
}

func setupLogging(logDir, logFileName string) (*os.File, error) {
	if err := os.MkdirAll(logDir, 0755); err != nil {
		return nil, err
	}
	logFilePath := filepath.Join(logDir, logFileName)
	logFile, err := os.OpenFile(logFilePath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return nil, err
	}
	multiWriter := io.MultiWriter(os.Stdout, logFile)
	log.SetOutput(multiWriter)
	log.SetFlags(log.Ldate | log.Ltime)
	return logFile, nil
}

func findPDFToPrinter(baseDir, configuredPath string) string {
	candidates := []string{}
	if strings.TrimSpace(configuredPath) != "" {
		candidates = append(candidates, resolvePath(baseDir, configuredPath))
	}
	candidates = append(candidates,
		filepath.Join(baseDir, "PDFtoPrinter.exe"),
		filepath.Join(baseDir, "..", "PDFtoPrinter.exe"),
	)

	for _, c := range candidates {
		if c == "" {
			continue
		}
		if fi, err := os.Stat(c); err == nil && !fi.IsDir() {
			return c
		}
	}
	return ""
}

func waitForFileReady(filePath string, maxAttempts int, delay time.Duration) bool {
	var lastSize int64 = -1
	for i := 0; i < maxAttempts; i++ {
		fi, err := os.Stat(filePath)
		if err == nil {
			currSize := fi.Size()
			if currSize > 0 && currSize == lastSize {
				file, err := os.OpenFile(filePath, os.O_RDWR, 0666)
				if err == nil {
					file.Close()
					return true
				}
			}
			lastSize = currSize
		}
		time.Sleep(delay)
	}
	return false
}

func (d *daemon) printFile(filePath, printerName string) error {
	if d.pdfToPrinterPath != "" {
		log.Printf("ℹ️ [%s] Sử dụng PDFtoPrinter.exe để in...", printerName)
		cmd := exec.Command(d.pdfToPrinterPath, filePath, printerName)
		cmd.Dir = filepath.Dir(d.pdfToPrinterPath)

		output, err := cmd.CombinedOutput()
		if err != nil {
			log.Printf("❌ [%s] PDFtoPrinter output: %s (Lỗi: %v)", printerName, string(output), err)
			return err
		}
		return nil
	}

	log.Printf("⚠️ [%s] Không tìm thấy PDFtoPrinter.exe. Dùng PowerShell dự phòng...", printerName)
	cmdStr := fmt.Sprintf(`Start-Process -FilePath "%s" -Verb PrintTo -ArgumentList '"%s"' -PassThru | Out-Null`, filePath, printerName)
	cmd := exec.Command("powershell", "-Command", cmdStr)
	return cmd.Run()
}

func waitForPrinterQueue(printerName string, timeout time.Duration) {
	p, err := printer.Open(printerName)
	if err != nil {
		log.Printf("⚠️ [%s] Không thể mở kết nối máy in để theo dõi Spooler: %v", printerName, err)
		time.Sleep(5 * time.Second)
		return
	}
	defer p.Close()

	deadline := time.Now().Add(timeout)
	detectedJob := false

	for time.Now().Before(deadline) {
		jobs, err := p.Jobs()
		if err == nil {
			if len(jobs) > 0 {
				detectedJob = true
			} else if detectedJob {
				log.Printf("✓ [%s] Máy in đã xử lý xong tác vụ trong hàng đợi.", printerName)
				time.Sleep(4 * time.Second)
				return
			}
		}
		time.Sleep(500 * time.Millisecond)
	}

	if !detectedJob {
		log.Printf("ℹ️ [%s] Hàng đợi rảnh (máy in đã nạp bộ đệm xong). Áp dụng độ trễ bảo vệ...", printerName)
		time.Sleep(4 * time.Second)
	} else {
		log.Printf("⚠️ [%s] Quá thời gian chờ hàng đợi, tiếp tục quy trình...", printerName)
	}
}

func (d *daemon) markInFlight(filePath string) bool {
	key := normalizeKey(filePath)
	d.inFlightMu.Lock()
	defer d.inFlightMu.Unlock()
	if _, exists := d.inFlight[key]; exists {
		return false
	}
	d.inFlight[key] = struct{}{}
	return true
}

func (d *daemon) clearInFlight(filePath string) {
	key := normalizeKey(filePath)
	d.inFlightMu.Lock()
	defer d.inFlightMu.Unlock()
	delete(d.inFlight, key)
}

func (d *daemon) enqueueFile(filePath string, route RouteConfig) {
	fileName := filepath.Base(filePath)
	if !strings.HasSuffix(strings.ToLower(fileName), ".pdf") {
		return
	}
	if !d.markInFlight(filePath) {
		return
	}

	printerKey := strings.ToLower(strings.TrimSpace(route.TargetPrinter))
	queue, ok := d.printerQueues[printerKey]
	if !ok {
		d.clearInFlight(filePath)
		log.Printf("❌ Không tìm thấy hàng đợi cho máy in: %s", route.TargetPrinter)
		return
	}

	log.Printf("📥 [%s] Đưa vào hàng đợi: %s", route.displayName(), fileName)
	queue <- printJob{
		filePath: filePath,
		route:    route,
	}
}

func (d *daemon) processJob(job printJob) {
	defer d.clearInFlight(job.filePath)

	fileName := filepath.Base(job.filePath)
	printerName := job.route.TargetPrinter
	label := job.route.displayName()

	log.Printf("⏳ [%s] Kiểm tra trạng thái ghi file: %s...", label, fileName)
	if !waitForFileReady(job.filePath, 20, 500*time.Millisecond) {
		log.Printf("❌ [%s] File chưa sẵn sàng hoặc bị khóa: %s", label, fileName)
		return
	}

	log.Printf("➔ [%s] Nhận file: %s. Đang gửi lệnh in tới '%s'...", label, fileName, printerName)
	if err := d.printFile(job.filePath, printerName); err != nil {
		log.Printf("❌ [%s] Lỗi gửi lệnh in file %s: %v", label, fileName, err)
		return
	}

	log.Printf("⏳ [%s] Đang chờ máy in '%s' xử lý tác vụ...", label, printerName)
	waitForPrinterQueue(printerName, 15*time.Second)

	if !job.route.shouldDeleteAfterPrint() {
		log.Printf("✓ [%s] In hoàn tất! Giữ lại file theo cấu hình: %s", label, fileName)
		return
	}

	for i := 0; i < 5; i++ {
		if err := os.Remove(job.filePath); err == nil {
			log.Printf("✓ [%s] In hoàn tất! Đã xóa file trung gian: %s", label, fileName)
			return
		}
		time.Sleep(1 * time.Second)
	}
	log.Printf("⚠️ [%s] Không thể xóa file trung gian sau 5 lần thử: %s", label, fileName)
}

func (d *daemon) startPrinterWorker(printerKey string, queue chan printJob) {
	d.workersWg.Add(1)
	go func() {
		defer d.workersWg.Done()
		for job := range queue {
			d.processJob(job)
		}
	}()
}

func (d *daemon) scanExistingFiles() {
	for _, route := range d.routesByDir {
		entries, err := os.ReadDir(route.WatchDir)
		if err != nil {
			log.Printf("⚠️ [%s] Không thể quét thư mục %s: %v", route.displayName(), route.WatchDir, err)
			continue
		}
		for _, entry := range entries {
			if entry.IsDir() {
				continue
			}
			fullPath := filepath.Join(route.WatchDir, entry.Name())
			d.enqueueFile(fullPath, route)
		}
	}
}

func main() {
	baseDir := getBaseDir()
	defaultConfigPath := filepath.Join(baseDir, "config.json")
	configFlag := flag.String("config", defaultConfigPath, "Đường dẫn tới file cấu hình JSON")
	flag.Parse()

	cfg, err := loadConfig(*configFlag)
	if err != nil {
		log.Fatalf("❌ Lỗi cấu hình: %v", err)
	}

	logDir := resolvePath(baseDir, cfg.LogDir)
	logFile, err := setupLogging(logDir, cfg.LogFile)
	if err != nil {
		log.Printf("⚠️ Không thể mở file log (%v), chỉ ghi ra console.", err)
	} else {
		defer logFile.Close()
	}

	d := &daemon{
		baseDir:          baseDir,
		pdfToPrinterPath: findPDFToPrinter(baseDir, cfg.PDFToPrinterPath),
		routesByDir:      make(map[string]RouteConfig),
		printerQueues:    make(map[string]chan printJob),
		inFlight:         make(map[string]struct{}),
	}

	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		log.Fatalf("❌ Lỗi khởi tạo File Watcher: %v", err)
	}
	defer watcher.Close()

	log.Println("🚀 Multi-Folder Print Daemon đã khởi động!")
	log.Printf("⚙️ File cấu hình: %s", *configFlag)
	log.Printf("📝 File nhật ký: %s", filepath.Join(logDir, cfg.LogFile))
	if d.pdfToPrinterPath != "" {
		log.Printf("🖨️ PDFtoPrinter: %s", d.pdfToPrinterPath)
	} else {
		log.Printf("⚠️ Không tìm thấy PDFtoPrinter.exe, sẽ dùng PowerShell dự phòng.")
	}
	log.Println("--------------------------------------------------")

	for _, r := range cfg.Routes {
		resolvedDir := resolvePath(baseDir, r.WatchDir)
		if err := os.MkdirAll(resolvedDir, 0755); err != nil {
			log.Fatalf("❌ Không thể tạo thư mục '%s': %v", resolvedDir, err)
		}

		dirKey := normalizeKey(resolvedDir)
		if _, dup := d.routesByDir[dirKey]; dup {
			log.Fatalf("❌ Thư mục '%s' bị cấu hình trùng lặp trong routes", resolvedDir)
		}

		r.WatchDir = resolvedDir
		d.routesByDir[dirKey] = r

		printerKey := strings.ToLower(strings.TrimSpace(r.TargetPrinter))
		if _, exists := d.printerQueues[printerKey]; !exists {
			q := make(chan printJob, 128)
			d.printerQueues[printerKey] = q
			d.startPrinterWorker(printerKey, q)
		}

		if err := watcher.Add(resolvedDir); err != nil {
			log.Fatalf("❌ Không thể theo dõi thư mục '%s': %v", resolvedDir, err)
		}

		log.Printf("📂 [%s] %s  ==>  🖨️ %s", r.displayName(), resolvedDir, r.TargetPrinter)
	}
	log.Println("--------------------------------------------------")

	d.scanExistingFiles()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)

	go func() {
		for {
			select {
			case event, ok := <-watcher.Events:
				if !ok {
					return
				}
				if event.Op&(fsnotify.Create|fsnotify.Write) != 0 {
					parentKey := normalizeKey(filepath.Dir(event.Name))
					if route, found := d.routesByDir[parentKey]; found {
						if strings.HasSuffix(strings.ToLower(event.Name), ".pdf") {
							log.Printf("🔍 [%s] Phát hiện file: %s (Hành động: %s)", route.displayName(), filepath.Base(event.Name), event.Op.String())
							d.enqueueFile(event.Name, route)
						}
					}
				}
			case err, ok := <-watcher.Errors:
				if !ok {
					return
				}
				log.Printf("❌ Watcher gặp lỗi: %v", err)
			}
		}
	}()

	<-sigCh
	log.Println("🛑 Nhận tín hiệu dừng. Đang đóng watcher và hoàn tất các tác vụ đang in...")
	watcher.Close()
	for _, q := range d.printerQueues {
		close(q)
	}
	d.workersWg.Wait()
	log.Println("👋 Đã tắt Multi-Folder Print Daemon an toàn.")
}
