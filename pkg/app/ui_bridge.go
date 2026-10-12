package app

import (
	"time"

	"github.com/hajimehoshi/ebiten/v2"

	"github.com/wottpal/blitzkvm/pkg/ui"
)

func (a *App) newUIContext(screen *ebiten.Image, runtime *ui.Runtime, register func(chromeButton)) *ui.Context {
	if runtime != nil {
		runtime.BeginFrame()
	}
	return &ui.Context{
		Screen:          screen,
		Now:             time.Now(),
		Theme:           a.currentTheme(),
		MeasureText:     ui.MeasureText,
		MeasureWrapped:  ui.WrappedTextHeight,
		DrawText:        ui.DrawText,
		DrawWrappedText: ui.DrawWrappedText,
		Runtime:         runtime,
		OnAction:        a.invokeAction,
		RegisterHitTarget: func(hit ui.HitTarget) {
			register(chromeButton{
				id:      hit.ID,
				enabled: hit.Enabled,
				rect: rect{
					x: hit.Rect.X,
					y: hit.Rect.Y,
					w: hit.Rect.W,
					h: hit.Rect.H,
				},
			})
		},
	}
}

func (a *App) drawUIRoot(screen *ebiten.Image, runtime *ui.Runtime, register func(chromeButton), root ui.Element) {
	if root == nil {
		return
	}
	ctx := a.newUIContext(screen, runtime, register)
	bounds := screen.Bounds()
	root.Draw(ctx, ui.Rect{W: float64(bounds.Dx()), H: float64(bounds.Dy())})
}
