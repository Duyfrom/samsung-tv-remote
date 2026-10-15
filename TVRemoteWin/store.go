package main

// Small JSON files shared by the app and the MCP server, in the same folder the macOS app uses:
// %APPDATA%\TV Remote on Windows, ~/Library/Application Support/TV Remote on macOS.

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"unicode"

	"golang.org/x/text/unicode/norm"
)

func dataDir() string {
	if d := os.Getenv("TV_REMOTE_DATA_DIR"); d != "" {
		return d
	}
	d, err := os.UserConfigDir()
	if err != nil {
		d = os.TempDir()
	}
	return filepath.Join(d, "TV Remote")
}

func readJSON(file string, v any) bool {
	data, err := os.ReadFile(file)
	return err == nil && json.Unmarshal(data, v) == nil
}

// writeJSON is atomic (temp file + rename): the app and the MCP server both read these files.
func writeJSON(file string, v any) error {
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	tmp := fmt.Sprintf("%s.%d.tmp", file, os.Getpid())
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, file)
}

type Settings struct {
	Host        string            `json:"host,omitempty"`
	Mac         string            `json:"mac,omitempty"`
	Tokens      map[string]string `json:"tokens,omitempty"`
	APIKeyDPAPI string            `json:"apiKeyDpapi,omitempty"` // Windows: API key encrypted with DPAPI
}

var settingsMu sync.Mutex

func settingsFile() string { return filepath.Join(dataDir(), "settings.json") }

func loadSettings() Settings {
	var s Settings
	readJSON(settingsFile(), &s)
	return s
}

// updateSettings reads fresh, applies f and writes back.
func updateSettings(f func(*Settings)) {
	settingsMu.Lock()
	defer settingsMu.Unlock()
	s := loadSettings()
	f(&s)
	_ = writeJSON(settingsFile(), s)
}

// ---- shortcuts ----------------------------------------------------------------------------------
// A named, replayable sequence of remote actions ("VTV1" = open FPT Play, wait, arrows, OK).
// Same JSON as the macOS app: [{name, steps: [{action, value}]}].

type Step struct {
	Action string `json:"action"` // key | text | launch_app | open_url | wait
	Value  string `json:"value"`
}

type Shortcut struct {
	Name  string `json:"name"`
	Steps []Step `json:"steps"`
}

var stepActions = []string{"key", "text", "launch_app", "open_url", "wait"}

func shortcutsFile() string { return filepath.Join(dataDir(), "shortcuts.json") }

// fold makes names compare case- and accent-insensitively ("Phim Việt" == "phim viet").
func fold(s string) string {
	var b strings.Builder
	for _, r := range norm.NFD.String(s) {
		switch {
		case unicode.Is(unicode.Mn, r):
		case r == 'đ' || r == 'Đ':
			b.WriteRune('d')
		default:
			b.WriteRune(unicode.ToLower(r))
		}
	}
	return strings.TrimSpace(b.String())
}

func loadShortcuts() []Shortcut {
	var all []Shortcut
	readJSON(shortcutsFile(), &all)
	out := all[:0]
	for _, s := range all {
		if s.Name != "" && s.Steps != nil {
			out = append(out, s)
		}
	}
	return out
}

func findShortcut(name string) *Shortcut {
	for _, s := range loadShortcuts() {
		if fold(s.Name) == fold(name) {
			return &s
		}
	}
	return nil
}

func saveShortcut(sc Shortcut) error {
	var keep []Shortcut
	for _, s := range loadShortcuts() {
		if fold(s.Name) != fold(sc.Name) {
			keep = append(keep, s)
		}
	}
	return writeJSON(shortcutsFile(), append(keep, sc))
}

func deleteShortcut(name string) error {
	keep := []Shortcut{}
	for _, s := range loadShortcuts() {
		if fold(s.Name) != fold(name) {
			keep = append(keep, s)
		}
	}
	return writeJSON(shortcutsFile(), keep)
}

func (s Shortcut) summary() string {
	parts := make([]string, len(s.Steps))
	for i, st := range s.Steps {
		if st.Action == "wait" {
			parts[i] = "wait " + st.Value + "s"
		} else {
			parts[i] = st.Action + " " + st.Value
		}
	}
	return strings.Join(parts, " → ")
}
