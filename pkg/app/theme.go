package app

import (
	"os/exec"
	"runtime"
	"strings"
	"time"

	"github.com/wottpal/blitzkvm/pkg/ui"
)

const systemThemeCacheTTL = time.Minute

func (a *App) currentTheme() ui.Theme {
	switch a.prefs.Theme {
	case themeLight:
		return ui.LightTheme()
	case themeDark:
		return ui.DarkTheme()
	case themeSystem:
		if a.systemThemeStale() {
			a.refreshSystemTheme()
		}
		if a.systemTheme == themeLight {
			return ui.LightTheme()
		}
		return ui.DarkTheme()
	default:
		return ui.DarkTheme()
	}
}

func (a *App) systemThemeStale() bool {
	a.mu.RLock()
	checkedAt := a.systemThemeCheckedAt
	a.mu.RUnlock()
	return checkedAt.IsZero() || time.Since(checkedAt) > systemThemeCacheTTL
}

func (a *App) refreshSystemTheme() {
	theme := detectSystemTheme()
	a.mu.Lock()
	a.systemTheme = theme
	a.systemThemeCheckedAt = time.Now()
	a.mu.Unlock()
}

func detectSystemTheme() Theme {
	switch runtime.GOOS {
	case "darwin":
		return detectMacOSTheme()
	case "windows":
		return detectWindowsTheme()
	default:
		return detectLinuxTheme()
	}
}

func detectLinuxTheme() Theme {
	output, err := exec.Command("gsettings", "get", "org.gnome.desktop.interface", "color-scheme").Output()
	if err == nil {
		value := strings.ToLower(string(output))
		if strings.Contains(value, "dark") {
			return themeDark
		}
		if strings.Contains(value, "light") || strings.Contains(value, "default") {
			return themeLight
		}
	}
	output, err = exec.Command("gsettings", "get", "org.gnome.desktop.interface", "gtk-theme").Output()
	if err == nil && strings.Contains(strings.ToLower(string(output)), "dark") {
		return themeDark
	}
	return themeDark
}

func detectMacOSTheme() Theme {
	output, err := exec.Command("defaults", "read", "-g", "AppleInterfaceStyle").Output()
	if err == nil && strings.Contains(strings.ToLower(string(output)), "dark") {
		return themeDark
	}
	return themeLight
}

func detectWindowsTheme() Theme {
	output, err := exec.Command("reg", "query", `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`, "/v", "AppsUseLightTheme").Output()
	if err != nil {
		return themeDark
	}
	value := strings.ToLower(string(output))
	if strings.Contains(value, "0x0") {
		return themeDark
	}
	if strings.Contains(value, "0x1") {
		return themeLight
	}
	return themeDark
}
