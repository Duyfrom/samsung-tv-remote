package main

// The TV control tools shared by the in-app Claude chat and the MCP server.

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
)

// ToolHost runs the tools and owns the TV connection: the app's Controller or the MCP server's session.
type ToolHost interface {
	ResolvedHost() (string, error)    // the TV's IP; error when none is known
	ReadyChannel() (*Channel, error)  // connected channel (connects first); error when the TV is off
	InstalledApps() ([]App, error)    // in the user's Smart Hub order
	SetPower(on bool) (string, error) // Wake-on-LAN / power key; returns what happened
}

const toolsJSON = `[
 {"name": "press_keys", "description": "Press remote control buttons in order (about 0.4 s apart). Names: home, back, exit, up, down, left, right, enter (OK), menu, source, guide, info, tools, search, channelUp, channelDown, previousChannel, channelList, 0-9, red, green, yellow, blue, play, pause, stop, rewind, fastForward, record, mute, volumeUp, volumeDown, power — or any raw Samsung KEY_* code. The screen can't be seen, so menu navigation is blind: prefer launch_app, open_url and shortcuts when they fit.",
  "schema": {"type": "object", "properties": {"keys": {"type": "array", "items": {"type": "string"}, "description": "Button names in order"}}, "required": ["keys"]}},
 {"name": "type_text", "description": "Type text into the TV's on-screen keyboard (search boxes, browser address bar). Only works while that keyboard is open on the TV.",
  "schema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}},
 {"name": "list_apps", "description": "List the apps installed on the TV, in the user's Smart Hub order.",
  "schema": {"type": "object", "properties": {}, "required": []}},
 {"name": "launch_app", "description": "Open an installed app by name or id. Names match loosely and ignore case and accents (\"fpt\" opens FPT Play, \"youtube\" opens YouTube). Pass ` + "`link`" + ` to open straight to content: for YouTube a video id or watch URL plays that video.",
  "schema": {"type": "object", "properties": {"app": {"type": "string", "description": "App name or id"}, "link": {"type": "string", "description": "Optional deep link / launch data, e.g. a YouTube video id"}}, "required": ["app"]}},
 {"name": "play_youtube", "description": "Play a YouTube video on the TV. Give ` + "`video`" + ` (an 11-character id or a youtube.com / youtu.be URL), or ` + "`channel`" + ` (an @handle such as @mkbhd, a channel id, or a name that is the channel's handle) to play that channel's most recent video (Shorts skipped). Use this instead of launch_app + key presses for YouTube content. This TV shows a \"Who's watching?\" picker on every YouTube launch, so the first profile is chosen automatically (set ` + "`choose_profile`" + ` to false to skip). Returns the title playing.",
  "schema": {"type": "object", "properties": {"video": {"type": "string"}, "channel": {"type": "string"}, "choose_profile": {"type": "boolean", "description": "Press OK on the first profile after launch (default true)"}}, "required": []}},
 {"name": "open_url", "description": "Open a web page in the TV's Web Browser. The 2016 browser is slow and some modern sites don't render.",
  "schema": {"type": "object", "properties": {"url": {"type": "string"}}, "required": ["url"]}},
 {"name": "set_volume", "description": "Set the TV volume (0-100) with ` + "`level`" + `, or adjust it with ` + "`change`" + ` (e.g. 5 or -3).",
  "schema": {"type": "object", "properties": {"level": {"type": "integer", "minimum": 0, "maximum": 100}, "change": {"type": "integer"}}, "required": []}},
 {"name": "mute", "description": "Mute or unmute the TV.",
  "schema": {"type": "object", "properties": {"muted": {"type": "boolean"}}, "required": ["muted"]}},
 {"name": "power", "description": "Turn the TV on (Wake-on-LAN, takes a few seconds) or off.",
  "schema": {"type": "object", "properties": {"state": {"type": "string", "enum": ["on", "off"]}}, "required": ["state"]}},
 {"name": "get_status", "description": "Whether the TV is on, its volume and mute state, and which app is in front.",
  "schema": {"type": "object", "properties": {}, "required": []}},
 {"name": "wait", "description": "Wait before the next action, e.g. 4-6 seconds for an app to finish opening.",
  "schema": {"type": "object", "properties": {"seconds": {"type": "number", "minimum": 0.5, "maximum": 15}}, "required": ["seconds"]}},
 {"name": "list_shortcuts", "description": "List the user's saved shortcuts: named action sequences that reach places the remote can't jump to directly (e.g. a channel inside FPT Play). Check these before navigating inside an app.",
  "schema": {"type": "object", "properties": {}, "required": []}},
 {"name": "run_shortcut", "description": "Run a saved shortcut by name.",
  "schema": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}},
 {"name": "save_shortcut", "description": "Save a sequence of actions as a named shortcut so it can be replayed later, e.g. after a sequence you ran worked and the user asks you to remember it. Each step's value is a key name, text to type, app name or id, URL, or seconds to wait.",
  "schema": {"type": "object", "properties": {"name": {"type": "string"}, "steps": {"type": "array", "items": {"type": "object", "properties": {"action": {"type": "string", "enum": ["key", "text", "launch_app", "open_url", "wait"]}, "value": {"type": "string"}}, "required": ["action", "value"]}}}, "required": ["name", "steps"]}}
]`

type toolDef struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	Schema      map[string]any `json:"schema"`
}

var tools = func() []toolDef {
	var t []toolDef
	if err := json.Unmarshal([]byte(toolsJSON), &t); err != nil {
		panic(err)
	}
	return t
}()

// toolList renders the definitions for the Claude API ("input_schema") or MCP ("inputSchema").
func toolList(schemaKey string) []map[string]any {
	out := make([]map[string]any, len(tools))
	for i, t := range tools {
		out[i] = map[string]any{"name": t.Name, "description": t.Description, schemaKey: t.Schema}
	}
	return out
}

var (
	controlRe = regexp.MustCompile(`[\x00-\x1f\x7f-\x9f]+`)
	spaceRe   = regexp.MustCompile(`\s+`)
)

// plain hands outside text (video titles, channel and app names) to the model as data: one line, bounded,
// so it can't smuggle in fake structure or long instructions.
func plain(s string, max int) string {
	s = strings.TrimSpace(spaceRe.ReplaceAllString(controlRe.ReplaceAllString(s, " "), " "))
	if r := []rune(s); len(r) > max {
		s = string(r[:max])
	}
	return s
}

func sleep(seconds float64) { time.Sleep(time.Duration(seconds * float64(time.Second))) }

// findApp: exact id, then name equality, prefix, substring, or the name inside the query.
func findApp(query string, apps []App) *App {
	q := fold(query)
	if q == "" {
		return nil
	}
	for i := range apps {
		if apps[i].ID == query {
			return &apps[i]
		}
	}
	for _, match := range []func(name string) bool{
		func(n string) bool { return n == q },
		func(n string) bool { return strings.HasPrefix(n, q) },
		func(n string) bool { return strings.Contains(n, q) },
		func(n string) bool { return n != "" && strings.Contains(q, n) },
	} {
		for i := range apps {
			if match(fold(apps[i].Name)) {
				return &apps[i]
			}
		}
	}
	return nil
}

func appNames(apps []App) string {
	names := make([]string, len(apps))
	for i, a := range apps {
		names[i] = plain(a.Name, 60)
	}
	return strings.Join(names, ", ")
}

// webURL is the one gate for anything the TV's Web Browser will open (open_url, a browser launch link,
// shortcut steps): http(s) only.
func webURL(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", errors.New("Which URL?")
	}
	if !strings.Contains(raw, "://") {
		raw = "https://" + raw
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return "", fmt.Errorf("“%s” is not a valid URL.", plain(raw, 60))
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return "", errors.New("Only http and https links can be opened.")
	}
	return u.String(), nil
}

func launch(query, link string, host ToolHost) (string, error) {
	apps, err := host.InstalledApps()
	if err != nil {
		return "", err
	}
	app := findApp(query, apps)
	if app == nil {
		return "", fmt.Errorf("No app matches “%s”. Installed: %s", plain(query, 60), appNames(apps))
	}
	if app.ID == "org.tizen.browser" && link != "" { // the browser's launch data is a URL
		if link, err = webURL(link); err != nil {
			return "", err
		}
	}
	ch, err := host.ReadyChannel()
	if err != nil {
		return "", err
	}
	ch.LaunchApp(app.ID, app.AppType, link)
	if link != "" {
		return fmt.Sprintf("Opened %s with link %s.", app.Name, link), nil
	}
	return fmt.Sprintf("Opened %s.", app.Name), nil
}

func runShortcut(sc Shortcut, host ToolHost) error {
	for _, st := range sc.Steps {
		switch st.Action {
		case "launch_app":
			if _, err := launch(st.Value, "", host); err != nil {
				return err
			}
		case "wait":
			v, _ := strconv.ParseFloat(st.Value, 64)
			sleep(min(20, max(0, v)))
		case "key", "text", "open_url":
			ch, err := host.ReadyChannel()
			if err != nil {
				return err
			}
			switch st.Action {
			case "key":
				ch.SendKey(keyCode(st.Value))
				sleep(0.4)
			case "text":
				ch.SendText(st.Value)
				sleep(0.5)
			default:
				u, err := webURL(st.Value) // shortcuts are a file anyone can edit
				if err != nil {
					return err
				}
				ch.OpenURL(u)
			}
		default:
			return fmt.Errorf("unknown shortcut step “%s”", st.Action)
		}
	}
	return nil
}

func status(host ToolHost) (string, error) {
	address, err := host.ResolvedHost()
	if err != nil {
		return "", err
	}
	info, err := tvInfo(address, 2*time.Second)
	if err != nil {
		return fmt.Sprintf("The TV at %s is off or unreachable.", address), nil
	}
	parts := []string{fmt.Sprintf("%s (%s) is on at %s.", info.Name, info.ModelName, address)}
	if v, err := getVolume(address); err == nil {
		muted := ""
		if mu, _ := getMute(address); mu {
			muted = ", muted"
		}
		parts = append(parts, fmt.Sprintf("Volume %d%s.", v, muted))
	}
	if apps, err := host.InstalledApps(); err == nil {
		visible := make([]bool, len(apps))
		var wg sync.WaitGroup
		for i, a := range apps {
			wg.Add(1)
			go func() {
				defer wg.Done()
				s, _ := appStatus(address, a.ID, 2*time.Second)
				visible[i] = s != nil && s.Visible
			}()
		}
		wg.Wait()
		var front []string
		for i, a := range apps {
			if visible[i] {
				front = append(front, plain(a.Name, 60))
			}
		}
		if len(front) > 0 {
			parts = append(parts, "In front: "+strings.Join(front, ", ")+".")
		} else {
			parts = append(parts, "No Smart Hub web app is in front: it's TV/HDMI input, the home screen or a built-in app like the Web Browser.")
		}
	}
	return strings.Join(parts, " "), nil
}

func number(v any) (float64, bool) {
	f, ok := v.(float64)
	return f, ok
}

func perform(name string, in map[string]any, host ToolHost) (string, error) {
	str := func(k string) string { s, _ := in[k].(string); return s }
	switch name {
	case "press_keys":
		var keys []string
		switch v := in["keys"].(type) {
		case string: // lenient: "home, up"
			keys = strings.FieldsFunc(v, func(r rune) bool { return r == ',' || unicode.IsSpace(r) })
		case []any:
			for _, k := range v {
				if s, ok := k.(string); ok {
					keys = append(keys, s)
				}
			}
		}
		if len(keys) == 0 {
			return "", errors.New("`keys` must be a list of button names.")
		}
		if len(keys) > 40 {
			return "", errors.New("At most 40 keys per call.")
		}
		ch, err := host.ReadyChannel()
		if err != nil {
			return "", err
		}
		for _, k := range keys {
			ch.SendKey(keyCode(k))
			sleep(0.4)
		}
		return "Pressed " + strings.Join(keys, ", ") + ".", nil

	case "type_text":
		text := str("text")
		if text == "" {
			return "", errors.New("`text` is empty.")
		}
		ch, err := host.ReadyChannel()
		if err != nil {
			return "", err
		}
		ch.SendText(text)
		sleep(0.5)
		return "Typed “" + text + "”.", nil

	case "list_apps":
		apps, err := host.InstalledApps()
		if err != nil {
			return "", err
		}
		lines := make([]string, len(apps))
		for i, a := range apps {
			lines[i] = fmt.Sprintf("%s (%s)", plain(a.Name, 60), plain(a.ID, 60))
		}
		return strings.Join(lines, "\n"), nil

	case "launch_app":
		if str("app") == "" {
			return "", errors.New("Which app?")
		}
		return launch(str("app"), str("link"), host)

	case "play_youtube":
		address, err := host.ResolvedHost()
		if err != nil {
			return "", err
		}
		id, playing := videoID(str("video")), ""
		if id == "" && str("channel") != "" {
			v, err := latestVideo(str("channel"))
			if err != nil {
				return "", err
			}
			id = v.ID
			playing = fmt.Sprintf("“%s” by %s (%s) ", plain(v.Title, 100), plain(v.Channel, 60), plain(v.Published, 10))
		}
		if id == "" {
			return "", errors.New("Give `video` (an id or URL) or `channel` (an @handle).")
		}
		if _, err := tvInfo(address, 2*time.Second); err != nil {
			return "", errors.New("The TV is off. Turn it on first.")
		}
		if err := dialLaunch(address, "YouTube", "v="+id+"&t=0"); err != nil {
			return "", err
		}
		note := ""
		if choose, set := in["choose_profile"].(bool); !set || choose {
			sleep(4.5) // the "Who's watching?" picker appears within a couple of seconds
			ch, err := host.ReadyChannel()
			if err != nil {
				return "", err
			}
			ch.SendKey(keyCode("enter"))
			note = " Picked the first profile."
		}
		return fmt.Sprintf("Playing %shttps://youtu.be/%s.%s", playing, id, note), nil

	case "open_url":
		u, err := webURL(str("url"))
		if err != nil {
			return "", err
		}
		ch, err := host.ReadyChannel()
		if err != nil {
			return "", err
		}
		ch.OpenURL(u)
		return "Opened " + u + " in the TV's Web Browser.", nil

	case "set_volume":
		address, err := host.ResolvedHost()
		if err != nil {
			return "", err
		}
		before, err := getVolume(address)
		if err != nil {
			return "", err
		}
		target := 0
		if l, ok := number(in["level"]); ok {
			target = int(l)
		} else if c, ok := number(in["change"]); ok {
			target = before + int(c)
		} else {
			return "", errors.New("Give `level` or `change`.")
		}
		if err := setVolume(address, target); err != nil {
			return "", err
		}
		after, _ := getVolume(address)
		return fmt.Sprintf("Volume %d → %d.", before, after), nil // the old level makes "put it back" possible

	case "mute":
		muted, ok := in["muted"].(bool)
		if !ok {
			return "", errors.New("`muted` must be true or false.")
		}
		address, err := host.ResolvedHost()
		if err != nil {
			return "", err
		}
		if err := setMute(address, muted); err != nil {
			return "", err
		}
		if muted {
			return "Muted.", nil
		}
		return "Unmuted.", nil

	case "power":
		s := str("state")
		if s != "on" && s != "off" {
			return "", errors.New("`state` must be on or off.")
		}
		return host.SetPower(s == "on")

	case "get_status":
		return status(host)

	case "wait":
		s, ok := number(in["seconds"])
		if !ok || s <= 0 {
			s = 3
		}
		s = min(15, max(0.5, s))
		sleep(s)
		return fmt.Sprintf("Waited %g s.", s), nil

	case "list_shortcuts":
		all := loadShortcuts()
		if len(all) == 0 {
			return "No shortcuts saved yet.", nil
		}
		lines := make([]string, len(all))
		for i, s := range all {
			lines[i] = s.Name + ": " + s.summary()
		}
		return strings.Join(lines, "\n"), nil

	case "run_shortcut":
		sc := findShortcut(str("name"))
		if sc == nil {
			var names []string
			for _, s := range loadShortcuts() {
				names = append(names, s.Name)
			}
			return "", fmt.Errorf("No shortcut named “%s”. Saved: %s", plain(str("name"), 60), strings.Join(names, ", "))
		}
		if err := runShortcut(*sc, host); err != nil {
			return "", err
		}
		return "Ran shortcut “" + sc.Name + "”.", nil

	case "save_shortcut":
		label := strings.TrimSpace(str("name"))
		raw, _ := in["steps"].([]any)
		if label == "" || len(raw) == 0 {
			return "", errors.New("Give a `name` and at least one step.")
		}
		steps := make([]Step, 0, len(raw))
		for _, r := range raw {
			st, _ := r.(map[string]any)
			action, _ := st["action"].(string)
			if !slices.Contains(stepActions, action) {
				return "", fmt.Errorf("Unknown step action %v.", st["action"])
			}
			value := ""
			if v, ok := st["value"]; ok && v != nil {
				value = fmt.Sprint(v)
			}
			if action == "open_url" {
				u, err := webURL(value)
				if err != nil {
					return "", err
				}
				value = u
			}
			steps = append(steps, Step{action, value})
		}
		if err := saveShortcut(Shortcut{label, steps}); err != nil {
			return "", err
		}
		return fmt.Sprintf("Saved shortcut “%s” (%d steps).", label, len(steps)), nil
	}
	return "", fmt.Errorf("Unknown tool %s.", name)
}

// runTool runs one call; failures come back as text with isError so the model can react.
func runTool(name string, input map[string]any, host ToolHost) (string, bool) {
	if input == nil {
		input = map[string]any{}
	}
	text, err := perform(name, input, host)
	if err != nil {
		return err.Error(), true
	}
	return text, false
}
