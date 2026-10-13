package client

import (
	"context"
)

func (c *Client) GetDeviceID(ctx context.Context) (string, error) {
	var deviceID string
	err := c.Call(ctx, "getDeviceID", nil, &deviceID)
	return deviceID, err
}

func (c *Client) Reboot(ctx context.Context) error {
	return c.Call(ctx, "reboot", RebootRequest{Force: false}, nil)
}

func (c *Client) GetStreamQualityFactor(ctx context.Context) (float64, error) {
	var quality float64
	err := c.Call(ctx, "getStreamQualityFactor", nil, &quality)
	return quality, err
}

func (c *Client) SetStreamQualityFactor(ctx context.Context, factor float64) error {
	return c.Call(ctx, "setStreamQualityFactor", SetQualityRequest{Factor: factor}, nil)
}

func (c *Client) GetKeyboardLayout(ctx context.Context) (string, error) {
	var layout string
	err := c.Call(ctx, "getKeyboardLayout", nil, &layout)
	return layout, err
}

func (c *Client) SetKeyboardLayout(ctx context.Context, layout string) error {
	return c.Call(ctx, "setKeyboardLayout", struct {
		Layout string `json:"layout"`
	}{Layout: layout}, nil)
}

func (c *Client) GetEDID(ctx context.Context) (string, error) {
	var edid string
	err := c.Call(ctx, "getEDID", nil, &edid)
	return edid, err
}

func (c *Client) SetEDID(ctx context.Context, edid string) error {
	return c.Call(ctx, "setEDID", SetEDIDRequest{EDID: edid}, nil)
}

func (c *Client) GetActiveExtension(ctx context.Context) (string, error) {
	var extension string
	err := c.Call(ctx, "getActiveExtension", nil, &extension)
	return extension, err
}

func (c *Client) GetATXState(ctx context.Context) (ATXState, error) {
	var state ATXState
	err := c.Call(ctx, "getATXState", nil, &state)
	return state, err
}

func (c *Client) SetATXPowerAction(ctx context.Context, action string) error {
	return c.Call(ctx, "setATXPowerAction", setATXPowerActionRequest{Action: action}, nil)
}

func (c *Client) SetActiveExtension(ctx context.Context, extensionID string) error {
	return c.Call(ctx, "setActiveExtension", setActiveExtensionRequest{ExtensionID: extensionID}, nil)
}

func (c *Client) GetDCPowerState(ctx context.Context) (DCPowerState, error) {
	var state DCPowerState
	err := c.Call(ctx, "getDCPowerState", nil, &state)
	return state, err
}

func (c *Client) SetDCPowerState(ctx context.Context, enabled bool) error {
	return c.Call(ctx, "setDCPowerState", setDCPowerStateRequest{Enabled: enabled}, nil)
}

func (c *Client) SetDCRestoreState(ctx context.Context, state int) error {
	return c.Call(ctx, "setDCRestoreState", setDCRestoreStateRequest{State: state}, nil)
}

func (c *Client) GetSerialSettings(ctx context.Context) (SerialSettings, error) {
	var settings SerialSettings
	err := c.Call(ctx, "getSerialSettings", nil, &settings)
	return settings, err
}

func (c *Client) SetSerialSettings(ctx context.Context, settings SerialSettings) error {
	return c.Call(ctx, "setSerialSettings", setSerialSettingsRequest{Settings: settings}, nil)
}

func (c *Client) SetSerialCommandHistory(ctx context.Context, history []string) error {
	return c.Call(ctx, "setSerialCommandHistory", setSerialCommandHistoryRequest{CommandHistory: history}, nil)
}

func (c *Client) SendCustomCommand(ctx context.Context, command string) error {
	return c.Call(ctx, "sendCustomCommand", sendCustomCommandRequest{Command: command}, nil)
}

func (c *Client) SetVideoCodecPreference(ctx context.Context, codec string) error {
	return c.Call(ctx, "setVideoCodecPreference", SetCodecPreferenceRequest{Codec: codec}, nil)
}

func (c *Client) GetLocalVersion(ctx context.Context) (LocalVersion, error) {
	var version LocalVersion
	err := c.Call(ctx, "getLocalVersion", nil, &version)
	return version, err
}

func (c *Client) GetUpdateStatus(ctx context.Context) (UpdateStatus, error) {
	var status UpdateStatus
	err := c.Call(ctx, "getUpdateStatus", nil, &status)
	return status, err
}

func (c *Client) GetPublicIPAddresses(ctx context.Context, refresh bool) ([]PublicIP, error) {
	var addresses []PublicIP
	err := c.Call(ctx, "getPublicIPAddresses", struct {
		Refresh bool `json:"refresh"`
	}{Refresh: refresh}, &addresses)
	return addresses, err
}

func (c *Client) SetBacklightSettings(ctx context.Context, settings BacklightSettings) error {
	return c.Call(ctx, "setBacklightSettings", SetBacklightSettingsRequest{Params: settings}, nil)
}

func (c *Client) SetVideoSleepMode(ctx context.Context, duration int) error {
	return c.Call(ctx, "setVideoSleepMode", SetVideoSleepModeRequest{Duration: duration}, nil)
}

func (c *Client) SetMQTTSettings(ctx context.Context, settings MQTTSettings) error {
	return c.Call(ctx, "setMqttSettings", MQTTSettingsRequest{Settings: settings}, nil)
}

func (c *Client) TestMQTTConnection(ctx context.Context, settings MQTTSettings) (MQTTTestResult, error) {
	var result MQTTTestResult
	err := c.Call(ctx, "testMqttConnection", MQTTSettingsRequest{Settings: settings}, &result)
	return result, err
}

func (c *Client) SetAutoUpdateState(ctx context.Context, enabled bool) error {
	return c.Call(ctx, "setAutoUpdateState", EnabledStateRequest{Enabled: enabled}, nil)
}

func (c *Client) GetNetworkSettings(ctx context.Context) (NetworkSettings, error) {
	var settings NetworkSettings
	err := c.Call(ctx, "getNetworkSettings", nil, &settings)
	return settings, err
}

func (c *Client) SetNetworkSettings(ctx context.Context, settings NetworkSettings) error {
	return c.Call(ctx, "setNetworkSettings", NetworkSettingsRequest{Settings: settings}, nil)
}

func (c *Client) SetTLSState(ctx context.Context, state TLSState) error {
	return c.Call(ctx, "setTLSState", SetTLSStateRequest{State: state}, nil)
}

func (c *Client) SetUSBEmulationState(ctx context.Context, enabled bool) error {
	return c.Call(ctx, "setUsbEmulationState", struct {
		Enabled bool `json:"enabled"`
	}{Enabled: enabled}, nil)
}

func (c *Client) GetUSBDevices(ctx context.Context) (USBDevices, error) {
	var devices USBDevices
	err := c.Call(ctx, "getUsbDevices", nil, &devices)
	return devices, err
}

func (c *Client) SetUSBDevices(ctx context.Context, devices USBDevices) error {
	return c.Call(ctx, "setUsbDevices", USBDevicesRequest{Devices: devices}, nil)
}

func (c *Client) SetDisplayRotation(ctx context.Context, rotation string) error {
	return c.Call(ctx, "setDisplayRotation", SetDisplayRotationRequest{
		Params: DisplayRotationState{Rotation: rotation},
	}, nil)
}

func (c *Client) SetDevChannelState(ctx context.Context, enabled bool) error {
	return c.Call(ctx, "setDevChannelState", EnabledStateRequest{Enabled: enabled}, nil)
}

func (c *Client) SetLocalLoopbackOnly(ctx context.Context, enabled bool) error {
	return c.Call(ctx, "setLocalLoopbackOnly", EnabledStateRequest{Enabled: enabled}, nil)
}

func (c *Client) SetSSHKeyState(ctx context.Context, sshKey string) error {
	return c.Call(ctx, "setSSHKeyState", SetSSHKeyStateRequest{SSHKey: sshKey}, nil)
}

func (c *Client) SetKeyboardMacros(ctx context.Context, macros []KeyboardMacro) error {
	return c.Call(ctx, "setKeyboardMacros", KeyboardMacrosRequest{
		Params: KeyboardMacrosParams{Macros: macros},
	}, nil)
}

func (c *Client) SetDeveloperModeState(ctx context.Context, enabled bool) error {
	return c.Call(ctx, "setDevModeState", EnabledStateRequest{Enabled: enabled}, nil)
}

func (c *Client) SetJigglerState(ctx context.Context, enabled bool) error {
	return c.Call(ctx, "setJigglerState", EnabledStateRequest{Enabled: enabled}, nil)
}

func (c *Client) SetJigglerConfig(ctx context.Context, cfg JigglerConfig) error {
	return c.Call(ctx, "setJigglerConfig", JigglerConfigRequest{JigglerConfig: cfg}, nil)
}

func (c *Client) GetKeyDownState(ctx context.Context) (KeysDownState, error) {
	var state KeysDownState
	err := c.Call(ctx, "getKeyDownState", nil, &state)
	return state, err
}
