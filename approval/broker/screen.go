package broker

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"image"
	"image/jpeg"
	"math"

	"github.com/wottpal/blitzkvm/approval/wire"
)

// EncodeScreen makes a screen's JPEG, as small as it must be: lower
// qualities until it fits wire.MaxScreen, then half the size (a screen of
// dense text compresses worst).
func EncodeScreen(img *image.YCbCr) ([]byte, error) {
	var buf bytes.Buffer
	for range 3 {
		for _, q := range []int{70, 55, 40} {
			buf.Reset()
			if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: q}); err != nil {
				return nil, err
			}
			if buf.Len() <= wire.MaxScreen {
				return buf.Bytes(), nil
			}
		}
		img = halve(img)
	}
	return nil, errors.New("the screen doesn't fit")
}

// ScreenFromYUYV turns a captured YUYV frame (4:2:2, limited range, as HDMI
// bridges send it) into full-range YCbCr, as JPEG has it.
func ScreenFromYUYV(width, height int, yuyv []byte) (*image.YCbCr, error) {
	if width < 2 || height < 1 || width%2 != 0 || len(yuyv) < width*height*2 {
		return nil, fmt.Errorf("frame %dx%d with %d bytes", width, height, len(yuyv))
	}
	var luma, chroma [256]uint8
	for i := range 256 {
		luma[i] = uint8(min(max(math.Round(float64(i-16)*255/219), 0), 255))
		chroma[i] = uint8(min(max(math.Round(float64(i-128)*255/224)+128, 0), 255))
	}
	img := image.NewYCbCr(image.Rect(0, 0, width, height), image.YCbCrSubsampleRatio422)
	for y := range height {
		row := yuyv[y*width*2:]
		for x := 0; x < width; x += 2 {
			p := row[x*2:]
			img.Y[y*img.YStride+x] = luma[p[0]]
			img.Y[y*img.YStride+x+1] = luma[p[2]]
			img.Cb[y*img.CStride+x/2] = chroma[p[1]]
			img.Cr[y*img.CStride+x/2] = chroma[p[3]]
		}
	}
	return img, nil
}

// halve scales a picture to half its width and height, each sample the
// mean of four.
func halve(src *image.YCbCr) *image.YCbCr {
	r := src.Rect
	dst := image.NewYCbCr(image.Rect(0, 0, max(1, r.Dx()/2), max(1, r.Dy()/2)), src.SubsampleRatio)
	plane := func(d []byte, dStride, dw, dh int, s []byte, sStride, sw, sh int) {
		for y := range dh {
			y0, y1 := min(2*y, sh-1), min(2*y+1, sh-1)
			for x := range dw {
				x0, x1 := min(2*x, sw-1), min(2*x+1, sw-1)
				sum := int(s[y0*sStride+x0]) + int(s[y0*sStride+x1]) + int(s[y1*sStride+x0]) + int(s[y1*sStride+x1])
				d[y*dStride+x] = byte((sum + 2) / 4)
			}
		}
	}
	plane(dst.Y, dst.YStride, dst.Rect.Dx(), dst.Rect.Dy(), src.Y, src.YStride, r.Dx(), r.Dy())
	// Chroma planes are CStride wide (NewYCbCr makes them so).
	dRows, sRows := len(dst.Cb)/max(1, dst.CStride), len(src.Cb)/max(1, src.CStride)
	plane(dst.Cb, dst.CStride, dst.CStride, dRows, src.Cb, src.CStride, src.CStride, sRows)
	plane(dst.Cr, dst.CStride, dst.CStride, dRows, src.Cr, src.CStride, src.CStride, sRows)
	return dst
}

// takeScreen takes a picture of the target's screen for a new request and
// sends it to every approver, after the request and without a push (the
// iPhone app fetches it with the request). One grab at a time: a request
// that comes while one runs goes without.
func (b *Broker) takeScreen(id string) {
	if b.cfg.Screen == nil {
		return
	}
	select {
	case b.screening <- struct{}{}:
		defer func() { <-b.screening }()
	default:
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), screenTimeout)
	defer cancel()
	jpeg, err := b.cfg.Screen(ctx)
	if err != nil || len(jpeg) == 0 || len(jpeg) > wire.MaxScreen {
		b.cfg.Logf("approvals: no screen for %s: %v (%d bytes)", id, err, len(jpeg))
		return
	}
	sum := sha256.Sum256(jpeg)
	env, err := wire.Sign(b.key, "screen", wire.Screen{V: 1, Request: id, Taken: b.cfg.Now().Unix(), SHA256: sum[:]})
	if err != nil {
		return
	}
	msg := map[string]any{"op": "screen", "screen": env, "jpeg": wire.Bytes(jpeg)}
	b.mu.Lock()
	p := b.pending[id]
	if p == nil || p.state != "pending" {
		b.mu.Unlock()
		return
	}
	p.screen = msg
	var ids []string
	if b.roster != nil {
		for _, a := range b.roster.Approvers {
			ids = append(ids, a.ID)
		}
	}
	b.mu.Unlock()
	for _, a := range ids {
		b.deliver(a, msg, nil)
	}
}
