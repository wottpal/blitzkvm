package emulator

import (
	"fmt"
	"net/http"
	neturl "net/url"
	"strconv"
	"strings"
	"time"
)

// mountURLInfo is the firmware's VirtualMediaUrlInfo.
type mountURLInfo struct {
	Usable bool   `json:"usable"`
	Reason string `json:"reason,omitempty"`
	Size   int64  `json:"size"`
}

// checkMountURL mirrors rpcCheckMountUrl (usb_mass_storage.go): the image
// must be served over http(s) with byte ranges and a known size, because
// the device reads it on demand.
func checkMountURL(raw string) mountURLInfo {
	raw = strings.TrimSpace(raw)
	parsed, err := neturl.Parse(raw)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		return mountURLInfo{Reason: "Enter a valid HTTP or HTTPS image URL."}
	}
	req, err := http.NewRequest(http.MethodGet, raw, nil)
	if err != nil {
		return mountURLInfo{Reason: "Enter a valid HTTP or HTTPS image URL."}
	}
	req.Header.Set("Range", "bytes=0-0")
	resp, err := (&http.Client{Timeout: 10 * time.Second}).Do(req)
	if err != nil {
		return mountURLInfo{Reason: "The URL is not available."}
	}
	_ = resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return mountURLInfo{Reason: fmt.Sprintf("The URL is not available (HTTP %d).", resp.StatusCode)}
	}
	if resp.StatusCode != http.StatusPartialContent {
		return mountURLInfo{Reason: "The server does not support byte-range requests."}
	}
	contentRange := strings.TrimSpace(resp.Header.Get("Content-Range"))
	slash := strings.LastIndex(contentRange, "/")
	if slash < 0 {
		return mountURLInfo{Reason: "The server did not report the image size."}
	}
	size, err := strconv.ParseInt(contentRange[slash+1:], 10, 64)
	if err != nil || size <= 0 {
		return mountURLInfo{Reason: "The server did not report the image size."}
	}
	return mountURLInfo{Usable: true, Size: size}
}
