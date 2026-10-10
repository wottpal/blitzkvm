package emulator

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/lkarlslund/jetkvm-desktop/pkg/client"
	"github.com/lkarlslund/jetkvm-desktop/pkg/protocol/jsonrpc"
	"github.com/lkarlslund/jetkvm-desktop/pkg/virtualmedia"
)

const mqttPasswordMask = "********"

func (sess *session) handleRPC(data []byte) error {
	decoded, err := jsonrpc.DecodeMessage(data)
	if err != nil {
		return err
	}
	req, ok := decoded.(jsonrpc.Request)
	if !ok {
		return nil
	}
	srv := sess.serverRef
	if delay := srv.cfg.Faults.RPCDelay; delay > 0 {
		time.Sleep(delay)
	}
	if method := srv.cfg.Faults.DropRPCMethod; method != "" && method == req.Method {
		return nil
	}

	// The firmware fetches the image URL to check it; not under srv.mu.
	var urlCheck *mountURLInfo
	if req.Method == "checkMountUrl" || req.Method == "mountWithHTTP" {
		if params, ok := req.Params.(map[string]any); ok {
			if url, ok := params["url"].(string); ok {
				info := checkMountURL(url)
				urlCheck = &info
			}
		}
	}

	srv.mu.Lock()
	resp, after := sess.dispatchRPC(req, urlCheck)
	srv.mu.Unlock()
	if after != nil {
		after()
	}
	if srv.cfg.Faults.ApplyButDropRPCMethod == req.Method {
		return nil
	}
	if resp.Error == nil && voidMethods[req.Method] {
		// Upstream omits "result" for error-only handlers.
		resp.Result = nil
	}

	payload, err := jsonrpc.Marshal(resp)
	if err != nil {
		return err
	}
	sess.mu.Lock()
	rpc := sess.rpc
	sess.mu.Unlock()
	if rpc == nil {
		return nil
	}
	return rpc.SendText(string(payload))
}

// dispatchRPC runs with srv.mu held. Side effects that must not run under the
// lock (events, timers) are returned as after.
func (sess *session) dispatchRPC(req jsonrpc.Request, urlCheck *mountURLInfo) (resp jsonrpc.Response, after func()) {
	srv := sess.serverRef
	st := &srv.state
	ok := func(result any) jsonrpc.Response { return jsonrpc.NewResponse(req.ID, result) }
	failed := func(message string) jsonrpc.Response {
		// Upstream wraps handler errors as -32603 with the text in data.
		return jsonrpc.NewErrorResponse(req.ID, -32603, "Internal error", message)
	}
	// Upstream never answers -32602: parameter errors are handler errors.
	invalid := failed
	if spec, found := rpcParams[req.Method]; found {
		params, _ := req.Params.(map[string]any)
		for _, name := range spec.required {
			if _, present := params[name]; !present {
				return failed("missing parameter: " + name), nil
			}
		}
	}

	switch req.Method {
	case "ping":
		return ok("pong"), nil
	case "getDeviceID":
		return ok(st.DeviceID), nil
	case "getVideoState":
		return ok(srv.videoInputStateLocked()), nil
	case "getNetworkSettings":
		return ok(cloneNetworkSettings(st.NetworkSettings)), nil
	case "getNetworkState":
		return ok(cloneNetworkState(st.NetworkState)), nil
	case "renewDHCPLease":
		if st.NetworkState.DHCPLease != nil {
			lease := *st.NetworkState.DHCPLease
			lease.LeaseExpiry = time.Now().Add(8 * time.Hour)
			st.NetworkState.DHCPLease = &lease
		}
		return ok(nil), nil
	case "getPublicIPAddresses":
		return ok([]client.PublicIP{
			{IPAddress: "198.51.100.10", LastUpdated: time.Now().Add(-4 * time.Minute)},
			{IPAddress: "2001:db8::10", LastUpdated: time.Now().Add(-4 * time.Minute)},
		}), nil
	case "getTailscaleStatus":
		return ok(client.TailscaleStatus{
			Installed:    true,
			Running:      true,
			BackendState: "Running",
			ControlURL:   "https://controlplane.tailscale.com",
			Self: &client.TailscalePeer{
				HostName:     "jetkvm-emulator",
				DNSName:      "jetkvm-emulator.tailnet.example.",
				TailscaleIPs: []string{"100.64.0.10", "fd7a:115c:a1e0::10"},
				Online:       true,
				OS:           "linux",
			},
		}), nil
	case "setNetworkSettings":
		params, err := decodeParams[client.NetworkSettingsRequest](req.Params)
		if err != nil {
			return invalid("invalid settings"), nil
		}
		st.NetworkSettings = cloneNetworkSettings(params.Settings)
		if hostname := strings.TrimSpace(params.Settings.Hostname); hostname != "" {
			st.Hostname = hostname
			networkState := cloneNetworkState(st.NetworkState)
			networkState.Hostname = hostname
			st.NetworkState = networkState
		}
		return ok(cloneNetworkSettings(st.NetworkSettings)), nil
	case "getKeyboardLedState":
		return ok(map[string]bool{
			"num_lock":    st.KeyboardLEDMask&0x01 != 0,
			"caps_lock":   st.KeyboardLEDMask&0x02 != 0,
			"scroll_lock": st.KeyboardLEDMask&0x04 != 0,
			"compose":     st.KeyboardLEDMask&0x08 != 0,
			"kana":        st.KeyboardLEDMask&0x10 != 0,
			"shift":       st.KeyboardLEDMask&0x40 != 0,
		}), nil
	case "getKeyDownState":
		return ok(keysDownState(st.KeyboardModifiers, st.KeysDown)), nil
	case "getStreamQualityFactor":
		return ok(st.StreamQualityFactor), nil
	case "getAutoUpdateState":
		return ok(st.AutoUpdateEnabled), nil
	case "setAutoUpdateState":
		params, err := decodeParams[client.EnabledStateRequest](req.Params)
		if err != nil {
			return invalid("invalid enabled"), nil
		}
		st.AutoUpdateEnabled = params.Enabled
		return ok(params.Enabled), nil
	case "setStreamQualityFactor":
		params, err := decodeParams[client.SetQualityRequest](req.Params)
		if err != nil {
			return invalid("invalid factor"), nil
		}
		st.StreamQualityFactor = params.Factor
		return ok(nil), nil
	case "wheelReport":
		params, err := decodeParams[client.WheelReportRequest](req.Params)
		if err != nil {
			return invalid("invalid wheel report"), nil
		}
		srv.appendInputLocked("rpc", "rpc.wheelReport", fmt.Sprintf("wheelY=%d wheelX=%d", int8(params.WheelY), int8(params.WheelX)))
		return ok(nil), nil
	case "reboot":
		if _, err := decodeParams[client.RebootRequest](req.Params); err != nil {
			return invalid("invalid reboot params"), nil
		}
		st.VideoState = "rebooting"
		return ok(nil), func() {
			// Like hwReboot: willReboot, a 1 s wait before the reply, then
			// the device is gone (session and HTTP) for RebootDowntime.
			_ = sess.sendEvent("willReboot", nil)
			time.Sleep(time.Second)
			srv.mu.Lock()
			srv.offlineUntil = time.Now().Add(srv.cfg.RebootDowntime)
			serveCtx := srv.serveCtx
			srv.mu.Unlock()
			if serveCtx == nil {
				serveCtx = context.Background()
			}
			go func() {
				time.Sleep(100 * time.Millisecond) // the reply goes out first
				sess.close()
				// A client may have reconnected during the wait; the
				// reboot ends that session too.
				srv.mu.Lock()
				current := srv.session
				srv.mu.Unlock()
				if current != nil {
					current.close()
				}
				select {
				case <-time.After(srv.cfg.RebootDowntime):
				case <-serveCtx.Done():
					return
				}
				srv.mu.Lock()
				srv.state.VideoState = "ready"
				srv.mu.Unlock()
			}()
		}
	case "tryUpdate", "factoryReset":
		return ok(nil), nil
	case "getKeyboardLayout":
		return ok(st.KeyboardLayout), nil
	case "setKeyboardLayout":
		params, err := decodeParams[struct {
			Layout string `json:"layout"`
		}](req.Params)
		if err != nil || strings.TrimSpace(params.Layout) == "" {
			return invalid("missing layout"), nil
		}
		st.KeyboardLayout = params.Layout
		return ok(nil), nil
	case "getEDID":
		return ok(st.EDID), nil
	case "setEDID":
		params, err := decodeParams[client.SetEDIDRequest](req.Params)
		if err != nil {
			return invalid("missing edid"), nil
		}
		st.EDID = params.EDID
		return ok(nil), nil
	case "getVideoCodecPreference":
		return ok(st.VideoCodec), nil
	case "setVideoCodecPreference":
		params, err := decodeParams[client.SetCodecPreferenceRequest](req.Params)
		if err != nil || strings.TrimSpace(params.Codec) == "" {
			return invalid("missing codec"), nil
		}
		st.VideoCodec = params.Codec
		return ok(nil), nil
	case "getActiveExtension":
		return ok(st.ActiveExtension), nil
	case "setActiveExtension":
		params, err := decodeParams[struct {
			ExtensionID string `json:"extensionId"`
		}](req.Params)
		if err != nil {
			return invalid("missing extensionId"), nil
		}
		st.ActiveExtension = params.ExtensionID
		return ok(nil), nil
	case "getDCPowerState":
		return ok(st.DCPowerState), nil
	case "setDCPowerState":
		params, err := decodeParams[client.EnabledStateRequest](req.Params)
		if err != nil {
			return invalid("missing enabled"), nil
		}
		st.DCPowerState.IsOn = params.Enabled
		if params.Enabled {
			st.DCPowerState.Current = 1.2
			st.DCPowerState.Power = 14.4
		} else {
			st.DCPowerState.Current = 0.0
			st.DCPowerState.Power = 0.0
		}
		srv.appendInputLocked("rpc", "rpc.setDCPowerState", fmt.Sprintf("enabled=%t", params.Enabled))
		return ok(nil), nil
	case "setDCRestoreState":
		params, err := decodeParams[struct {
			State int `json:"state"`
		}](req.Params)
		if err != nil {
			return invalid("missing state"), nil
		}
		st.DCPowerState.RestoreState = params.State
		srv.appendInputLocked("rpc", "rpc.setDCRestoreState", fmt.Sprintf("state=%d", params.State))
		return ok(nil), nil
	case "getATXState":
		return ok(mapsClone(st.ATXState)), nil
	case "setATXPowerAction":
		params, err := decodeParams[struct {
			Action string `json:"action"`
		}](req.Params)
		if err != nil || params.Action == "" {
			return invalid("missing action"), nil
		}
		switch params.Action {
		case "power-short", "power-long", "reset":
			srv.appendInputLocked("rpc", "rpc.setATXPowerAction", params.Action)
			return ok(nil), nil
		default:
			return failed("invalid action"), nil
		}
	case "getSerialSettings":
		return ok(cloneSerialSettings(st.SerialSettings)), nil
	case "setSerialSettings":
		params, err := decodeParams[struct {
			Settings client.SerialSettings `json:"settings"`
		}](req.Params)
		if err != nil {
			return invalid("missing settings"), nil
		}
		st.SerialSettings = cloneSerialSettings(params.Settings)
		return ok(nil), nil
	case "getSerialCommandHistory":
		return ok(append([]string(nil), st.SerialCommandHistory...)), nil
	case "setSerialCommandHistory":
		params, err := decodeParams[struct {
			CommandHistory []string `json:"commandHistory"`
		}](req.Params)
		if err != nil {
			return invalid("missing commandHistory"), nil
		}
		st.SerialCommandHistory = append([]string(nil), params.CommandHistory...)
		return ok(nil), nil
	case "sendCustomCommand":
		params, err := decodeParams[struct {
			Command string `json:"command"`
		}](req.Params)
		if err != nil || params.Command == "" {
			return invalid("missing command"), nil
		}
		srv.appendInputLocked("rpc", "rpc.sendCustomCommand", params.Command)
		return ok(nil), nil
	case "getUsbEmulationState":
		return ok(st.USBEmulation), nil
	case "setUsbEmulationState":
		params, err := decodeParams[struct {
			Enabled bool `json:"enabled"`
		}](req.Params)
		if err != nil {
			return invalid("missing enabled"), nil
		}
		st.USBEmulation = params.Enabled
		return ok(nil), nil
	case "getCloudState":
		return ok(client.CloudState{Connected: st.CloudURL != "", URL: st.CloudURL, AppURL: st.CloudAppURL}), nil
	case "getTLSState":
		return ok(client.TLSState{Mode: st.TLSMode, Certificate: st.TLSCertificate, PrivateKey: st.TLSPrivateKey}), nil
	case "setTLSState":
		params, err := decodeParams[client.SetTLSStateRequest](req.Params)
		if err != nil || strings.TrimSpace(params.State.Mode) == "" {
			return invalid("missing mode"), nil
		}
		st.TLSMode = params.State.Mode
		st.TLSCertificate = params.State.Certificate
		st.TLSPrivateKey = params.State.PrivateKey
		return ok(nil), nil
	case "getUsbConfig":
		return ok(st.USBConfig), nil
	case "getUsbDevices":
		return ok(st.USBDevices), nil
	case "setUsbDevices":
		params, err := decodeParams[struct {
			Devices USBDevices `json:"devices"`
		}](req.Params)
		if err != nil {
			return invalid("missing devices"), nil
		}
		st.USBDevices = params.Devices
		// Upstream persists the audio choice (config.AudioEnabled) too.
		st.AudioEnabled = params.Devices.Audio
		return ok(nil), nil
	case "getDisplayRotation":
		return ok(client.DisplayRotationState{Rotation: st.DisplayRotation}), nil
	case "setDisplayRotation":
		params, err := decodeParams[client.SetDisplayRotationRequest](req.Params)
		if err != nil || strings.TrimSpace(params.Params.Rotation) == "" {
			return invalid("missing rotation"), nil
		}
		st.DisplayRotation = params.Params.Rotation
		return ok(nil), nil
	case "getBacklightSettings":
		return ok(st.BacklightSettings), nil
	case "setBacklightSettings":
		params, err := decodeParams[client.SetBacklightSettingsRequest](req.Params)
		if err != nil {
			return invalid("missing params"), nil
		}
		st.BacklightSettings = params.Params
		return ok(nil), nil
	case "getVideoSleepMode":
		return ok(client.VideoSleepMode{Enabled: st.VideoSleepDuration >= 0, Duration: st.VideoSleepDuration}), nil
	case "setVideoSleepMode":
		params, err := decodeParams[client.SetVideoSleepModeRequest](req.Params)
		if err != nil {
			return invalid("missing duration"), nil
		}
		st.VideoSleepDuration = params.Duration
		return ok(nil), nil
	case "getMqttSettings":
		settings := st.MQTTSettings
		if settings.Password != "" {
			settings.Password = mqttPasswordMask
		}
		return ok(settings), nil
	case "setMqttSettings":
		params, err := decodeParams[client.MQTTSettingsRequest](req.Params)
		if err != nil {
			return invalid("missing settings"), nil
		}
		next := params.Settings
		if next.Password == mqttPasswordMask {
			next.Password = st.MQTTSettings.Password
		}
		st.MQTTSettings = next
		st.MQTTConnected = next.Enabled
		st.MQTTError = ""
		return ok(nil), nil
	case "getMqttStatus":
		return ok(client.MQTTStatus{Connected: st.MQTTConnected, Error: st.MQTTError}), nil
	case "testMqttConnection":
		params, err := decodeParams[client.MQTTSettingsRequest](req.Params)
		if err != nil {
			return invalid("missing settings"), nil
		}
		if strings.TrimSpace(params.Settings.Broker) == "" {
			return ok(client.MQTTTestResult{Success: false, Error: "broker address is required"}), nil
		}
		return ok(client.MQTTTestResult{Success: true}), nil
	case "getKeyboardMacros":
		return ok(cloneKeyboardMacros(st.KeyboardMacros)), nil
	case "setKeyboardMacros":
		params, err := decodeParams[client.KeyboardMacrosRequest](req.Params)
		if err != nil {
			return invalid("missing macros"), nil
		}
		st.KeyboardMacros = cloneKeyboardMacros(params.Params.Macros)
		// Upstream returns (nil, nil): the response carries no result.
		return ok(nil), nil
	case "getDevModeState":
		return ok(client.DeveloperModeState{Enabled: st.DeveloperMode}), nil
	case "setDevModeState":
		params, err := decodeParams[client.EnabledStateRequest](req.Params)
		if err != nil {
			return invalid("missing enabled"), nil
		}
		st.DeveloperMode = params.Enabled
		return ok(nil), nil
	case "getDevChannelState":
		return ok(st.DevChannel), nil
	case "setDevChannelState":
		params, err := decodeParams[client.EnabledStateRequest](req.Params)
		if err != nil {
			return invalid("missing enabled"), nil
		}
		st.DevChannel = params.Enabled
		return ok(nil), nil
	case "getLocalLoopbackOnly":
		return ok(st.LoopbackOnly), nil
	case "setLocalLoopbackOnly":
		params, err := decodeParams[client.EnabledStateRequest](req.Params)
		if err != nil {
			return invalid("missing enabled"), nil
		}
		st.LoopbackOnly = params.Enabled
		return ok(nil), nil
	case "getSSHKeyState":
		return ok(st.SSHKey), nil
	case "setSSHKeyState":
		params, err := decodeParams[client.SetSSHKeyStateRequest](req.Params)
		if err != nil {
			return invalid("missing sshKey"), nil
		}
		st.SSHKey = params.SSHKey
		return ok(nil), nil
	case "getJigglerState":
		return ok(st.JigglerEnabled), nil
	case "setJigglerState":
		params, err := decodeParams[client.EnabledStateRequest](req.Params)
		if err != nil {
			return invalid("missing enabled"), nil
		}
		st.JigglerEnabled = params.Enabled
		return ok(nil), nil
	case "getJigglerConfig":
		return ok(st.JigglerConfig), nil
	case "setJigglerConfig":
		params, err := decodeParams[client.JigglerConfigRequest](req.Params)
		if err != nil {
			return invalid("missing jigglerConfig"), nil
		}
		st.JigglerConfig = params.JigglerConfig
		return ok(nil), nil
	case "getVirtualMediaState":
		return ok(srv.media), nil
	case "unmountImage":
		srv.media = nil
		return ok(nil), nil
	case "mountWithHTTP":
		params, err := decodeParams[client.MountWithHTTPRequest](req.Params)
		if err != nil || strings.TrimSpace(params.URL) == "" || params.Mode == "" {
			return invalid("missing mount params"), nil
		}
		if srv.media != nil {
			return failed("another virtual media is already mounted"), nil
		}
		if urlCheck == nil || !urlCheck.Usable {
			reason := "invalid URL"
			if urlCheck != nil {
				reason = urlCheck.Reason
			}
			return failed(reason), nil
		}
		srv.media = &virtualmedia.State{Source: virtualmedia.SourceHTTP, Mode: params.Mode, URL: strings.TrimSpace(params.URL), Size: urlCheck.Size}
		return ok(nil), nil
	case "checkMountUrl":
		if urlCheck == nil {
			return failed("missing parameter: url"), nil
		}
		return ok(urlCheck), nil
	case "mountWithStorage":
		params, err := decodeParams[client.MountWithStorageRequest](req.Params)
		filename := filepath.Base(strings.TrimSpace(params.Filename))
		if err != nil || filename == "" || params.Mode == "" {
			return invalid("missing mount params"), nil
		}
		if srv.media != nil {
			return failed("another virtual media is already mounted"), nil
		}
		file, found := srv.storage[filename]
		if !found || strings.HasSuffix(filename, ".incomplete") {
			return failed("storage file not found"), nil
		}
		srv.media = &virtualmedia.State{Source: virtualmedia.SourceStorage, Mode: params.Mode, Filename: filename, Size: int64(len(file.data))}
		return ok(nil), nil
	case "listStorageFiles":
		files := make([]virtualmedia.StorageFile, 0, len(srv.storage))
		for name, file := range srv.storage {
			files = append(files, virtualmedia.StorageFile{Filename: name, Size: int64(len(file.data)), CreatedAt: file.createdAt})
		}
		sort.Slice(files, func(i, j int) bool { return files[i].CreatedAt.After(files[j].CreatedAt) })
		return ok(client.StorageFilesResponse{Files: files}), nil
	case "getStorageSpace":
		var used int64
		for _, file := range srv.storage {
			used += int64(len(file.data))
		}
		total := int64(2 * 1024 * 1024 * 1024)
		return ok(virtualmedia.StorageSpace{BytesUsed: used, BytesFree: total - used}), nil
	case "deleteStorageFile":
		params, err := decodeParams[client.DeleteStorageFileRequest](req.Params)
		filename := filepath.Base(strings.TrimSpace(params.Filename))
		if err != nil || filename == "" {
			return invalid("missing filename"), nil
		}
		if _, found := srv.storage[filename]; !found {
			return failed("file does not exist"), nil
		}
		delete(srv.storage, filename)
		return ok(nil), nil
	case "startStorageFileUpload":
		params, err := decodeParams[client.StorageUploadRequest](req.Params)
		filename := filepath.Base(strings.TrimSpace(params.Filename))
		if err != nil || filename == "" || params.Size <= 0 {
			return invalid("invalid upload params"), nil
		}
		if _, found := srv.storage[filename]; found {
			return failed("file already exists"), nil
		}
		// A transfer still running for this file (e.g. one the client
		// cancelled whose bytes are still arriving) ends here, so it cannot
		// append after the partial size was measured.
		for id, other := range srv.uploads {
			if other.filename == filename {
				other.superseded = true
				delete(srv.uploads, id)
			}
		}
		file := srv.storage[filename+".incomplete"]
		uploadID := fmt.Sprintf("upload_%d", time.Now().UnixNano())
		srv.uploads[uploadID] = &pendingUpload{filename: filename, size: params.Size}
		return ok(virtualmedia.UploadStart{AlreadyUploadedBytes: int64(len(file.data)), DataChannel: uploadID}), nil
	case "getLocalVersion":
		return ok(client.LocalVersion{AppVersion: srv.cfg.DeviceVersion, SystemVersion: "0.2.8"}), nil
	case "getUpdateStatus":
		local := client.LocalVersion{AppVersion: srv.cfg.DeviceVersion, SystemVersion: "0.2.8"}
		return ok(client.UpdateStatus{Local: local, Remote: local}), nil
	default:
		return jsonrpc.NewErrorResponse(req.ID, -32601, "Method not found", nil), nil
	}
}

func decodeParams[T any](raw any) (T, error) {
	var out T
	if raw == nil {
		return out, nil
	}
	data, err := json.Marshal(raw)
	if err != nil {
		return out, err
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return out, err
	}
	return out, nil
}

func cloneStrings(src []string) []string {
	if src == nil {
		return nil
	}
	return append([]string(nil), src...)
}

func mapsClone(src map[string]any) map[string]any {
	dst := make(map[string]any, len(src))
	for key, value := range src {
		dst[key] = value
	}
	return dst
}

func cloneKeyboardMacros(src []client.KeyboardMacro) []client.KeyboardMacro {
	if src == nil {
		return nil
	}
	out := make([]client.KeyboardMacro, 0, len(src))
	for _, macro := range src {
		steps := make([]client.KeyboardMacroStep, 0, len(macro.Steps))
		for _, step := range macro.Steps {
			steps = append(steps, client.KeyboardMacroStep{
				Keys:      cloneStrings(step.Keys),
				Modifiers: cloneStrings(step.Modifiers),
				Delay:     step.Delay,
			})
		}
		out = append(out, client.KeyboardMacro{ID: macro.ID, Name: macro.Name, Steps: steps, SortOrder: macro.SortOrder})
	}
	return out
}

func cloneSerialSettings(src client.SerialSettings) client.SerialSettings {
	dst := src
	dst.Buttons = append([]client.QuickButton(nil), src.Buttons...)
	return dst
}

func cloneNetworkSettings(src client.NetworkSettings) client.NetworkSettings {
	dst := src
	if src.IPv4Static != nil {
		ipv4 := *src.IPv4Static
		ipv4.DNS = cloneStrings(src.IPv4Static.DNS)
		dst.IPv4Static = &ipv4
	}
	if src.IPv6Static != nil {
		ipv6 := *src.IPv6Static
		ipv6.DNS = cloneStrings(src.IPv6Static.DNS)
		dst.IPv6Static = &ipv6
	}
	dst.LLDPTxTLVs = cloneStrings(src.LLDPTxTLVs)
	dst.TimeSyncOrdering = cloneStrings(src.TimeSyncOrdering)
	dst.TimeSyncNTPServers = cloneStrings(src.TimeSyncNTPServers)
	dst.TimeSyncHTTPUrls = cloneStrings(src.TimeSyncHTTPUrls)
	return dst
}

func cloneNetworkState(src client.NetworkState) client.NetworkState {
	dst := src
	dst.IPv4Addresses = cloneStrings(src.IPv4Addresses)
	if src.DHCPLease != nil {
		lease := *src.DHCPLease
		lease.DNSServers = cloneStrings(src.DHCPLease.DNSServers)
		lease.NTPServers = cloneStrings(src.DHCPLease.NTPServers)
		lease.Routers = cloneStrings(src.DHCPLease.Routers)
		dst.DHCPLease = &lease
	}
	if src.IPv6Addresses != nil {
		dst.IPv6Addresses = append([]client.IPv6Address(nil), src.IPv6Addresses...)
	}
	return dst
}

// keysDownWire is the firmware's KeysDownState JSON: keys as a number array
// (upstream usbgadget.ByteSlice), not base64 as a plain []byte would be.
type keysDownWire struct {
	Modifier byte      `json:"modifier"`
	Keys     byteSlice `json:"keys"`
}

type byteSlice []byte

func (b byteSlice) MarshalJSON() ([]byte, error) {
	values := make([]int, len(b))
	for i, v := range b {
		values[i] = int(v)
	}
	return json.Marshal(values)
}

func keysDownState(modifier byte, keys []byte) keysDownWire {
	return keysDownWire{Modifier: modifier, Keys: append(byteSlice(nil), keys...)}
}

// TrimBaseURL normalises an emulator listen address into a base URL.
func TrimBaseURL(addr string) string {
	return "http://" + strings.TrimPrefix(addr, "http://")
}

func (s *Server) applyKeypress(key byte, press bool) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if modifierBit, ok := modifierMask(key); ok {
		if press {
			s.state.KeyboardModifiers |= modifierBit
		} else {
			s.state.KeyboardModifiers &^= modifierBit
		}
		return
	}

	keys := append([]byte(nil), s.state.KeysDown...)
	if len(keys) < 6 {
		padded := make([]byte, 6)
		copy(padded, keys)
		keys = padded
	}
	if press {
		for _, existing := range keys {
			if existing == key {
				s.state.KeysDown = keys
				return
			}
		}
		for i, existing := range keys {
			if existing == 0 {
				keys[i] = key
				s.state.KeysDown = keys
				return
			}
		}
		// A 7th key overflows the 6-key buffer: the host gets an
		// ErrorRollOver report and the device then tracks no keys down.
		s.state.KeysDown = make([]byte, 6)
		s.appendInputLocked("emulator", "rollover", fmt.Sprintf("key=%d", key))
		return
	}

	next := make([]byte, 0, len(keys))
	for _, existing := range keys {
		if existing != 0 && existing != key {
			next = append(next, existing)
		}
	}
	for len(next) < 6 {
		next = append(next, 0)
	}
	s.state.KeysDown = next
}

// setKeyboardReport applies a full 0x02-style report (modifier byte + keys).
func (s *Server) setKeyboardReport(modifier byte, keys []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	next := make([]byte, 6)
	copy(next, keys)
	s.state.KeyboardModifiers = modifier
	s.state.KeysDown = next
}

func modifierMask(key byte) (byte, bool) {
	if key >= 224 && key <= 231 {
		return 1 << (key - 224), true
	}
	return 0, false
}
