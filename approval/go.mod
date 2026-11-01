module github.com/wottpal/blitzkvm/approval

// The firmware (Go 1.25) builds this module too: keep it within 1.24.
go 1.24.0

require (
	github.com/cloudflare/circl v1.6.4
	golang.org/x/crypto v0.45.0
)

require golang.org/x/sys v0.38.0 // indirect
