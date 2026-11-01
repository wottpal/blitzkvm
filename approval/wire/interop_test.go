package wire

import (
	"encoding/json"
	"os"
	"testing"
	"time"
)

// TestSwiftInterop checks what ApprovalKit made from the vectors (a box and
// a decision with a sealed secret). Run ApprovalKit's tests with
// APPROVALKIT_INTEROP_OUT=<file>, then this one with APPROVALKIT_INTEROP_IN.
func TestSwiftInterop(t *testing.T) {
	path := os.Getenv("APPROVALKIT_INTEROP_IN")
	if path == "" {
		t.Skip("APPROVALKIT_INTEROP_IN not set")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var in struct {
		Decision string `json:"decision"`
		Box      string `json:"box"`
	}
	if err := json.Unmarshal(data, &in); err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(vectorsPath)
	var v Vectors
	_ = json.Unmarshal(raw, &v)
	seal, _ := SealKeyFromScalar(v.Keys["phoneSeal"].Scalar)
	box, _ := B64.DecodeString(in.Box)
	if msg, err := seal.OpenBox(box); err != nil || string(msg) != "from swift" {
		t.Fatalf("Swift box: %v %q", err, msg)
	}
	var env Envelope
	if err := json.Unmarshal([]byte(in.Decision), &env); err != nil {
		t.Fatal(err)
	}
	roster, _ := AcceptRoster(nil, v.Roster)
	req, err := VerifyRequest(roster, v.Request, time.Unix(v.Now, 0))
	if err != nil {
		t.Fatal(err)
	}
	d, err := VerifyDecision(roster, req, &env, time.Unix(v.Now, 0))
	if err != nil {
		t.Fatalf("Swift decision: %v", err)
	}
	reqSeal, _ := SealKeyFromScalar(v.Keys["requestSeal"].Scalar)
	if pw, err := reqSeal.OpenSecret(d.Secret, req.RequestDigest); err != nil || string(pw) != "pw" {
		t.Fatalf("Swift secret: %v", err)
	}
}
