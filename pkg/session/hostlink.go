package session

import (
	"context"
	"errors"
	"net"

	"github.com/wottpal/blitzkvm/pkg/protocol/hidrpc"
)

// HasFirmwareFeature reports whether the connected firmware lists name
// (getFirmwareFeatures); false while not connected.
func (c *Controller) HasFirmwareFeature(ctx context.Context, name string) bool {
	current := c.clientIfConnected()
	return current != nil && current.HasFirmwareFeature(ctx, name)
}

// DialHostSSH opens a stream to the computer's SSH server through the
// firmware's host link (client.FeatureHostLink).
func (c *Controller) DialHostSSH(ctx context.Context) (net.Conn, error) {
	current := c.clientIfConnected()
	if current == nil {
		return nil, errors.New("not connected")
	}
	return current.DialHostSSH(ctx)
}

// TapKey presses and releases one key with modifiers (HID usages) through
// the device's macro engine, so the chord lands whole even on a slow link.
func (c *Controller) TapKey(ctx context.Context, modifier, key byte) error {
	current := c.clientIfConnected()
	if current == nil {
		return errors.New("not connected")
	}
	var press hidrpc.KeyboardMacroStep
	press.Modifier = modifier
	press.Keys[0] = key
	press.Delay = 60
	return current.TypeMacro(ctx, []hidrpc.KeyboardMacroStep{press, {Delay: 40}})
}
