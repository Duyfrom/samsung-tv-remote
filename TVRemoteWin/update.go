package main

// "Check for updates": the newest windows-v* release on GitHub, downloaded and checked against the .sha256
// file published next to it before anything runs.

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

const releasesAPI = "https://api.github.com/repos/Duyfrom/samsung-tv-remote/releases?per_page=30"

type release struct {
	Tag        string `json:"tag_name"`
	Draft      bool   `json:"draft"`
	Prerelease bool   `json:"prerelease"`
	Page       string `json:"html_url"`
	Assets     []struct {
		Name string `json:"name"`
		URL  string `json:"browser_download_url"`
	} `json:"assets"`
}

type update struct {
	Version  string `json:"version"`
	Page     string `json:"page"`
	asset    string // installer URL
	checksum string // its .sha256 URL
}

// newer reports whether version a (1.2.10) is newer than b.
func newer(a, b string) bool {
	pa, pb := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < max(len(pa), len(pb)); i++ {
		var x, y int
		if i < len(pa) {
			x, _ = strconv.Atoi(pa[i])
		}
		if i < len(pb) {
			y, _ = strconv.Atoi(pb[i])
		}
		if x != y {
			return x > y
		}
	}
	return false
}

// pickUpdate: the newest published release with the tag prefix that is newer than current and carries both
// the named asset and its checksum.
func pickUpdate(releases []release, prefix, current string, assetName func(version string) string) *update {
	var best *update
	for _, r := range releases {
		v, ok := strings.CutPrefix(r.Tag, prefix)
		if !ok || r.Draft || r.Prerelease || !newer(v, current) || (best != nil && !newer(v, best.Version)) {
			continue
		}
		u := &update{Version: v, Page: r.Page}
		for _, a := range r.Assets {
			switch a.Name {
			case assetName(v):
				u.asset = a.URL
			case assetName(v) + ".sha256":
				u.checksum = a.URL
			}
		}
		if u.asset != "" && u.checksum != "" {
			best = u
		}
	}
	return best
}

func checkForUpdate(prefix, current string, assetName func(string) string) (*update, error) {
	data, res, err := request("GET", releasesAPI, nil, map[string]string{"Accept": "application/vnd.github+json", "User-Agent": "TV-Remote/" + version_}, 10*time.Second)
	if err != nil {
		return nil, fmt.Errorf("couldn't reach GitHub: %w", err)
	}
	if res.StatusCode != 200 {
		return nil, fmt.Errorf("GitHub answered HTTP %d", res.StatusCode)
	}
	var releases []release
	if err := json.Unmarshal(data, &releases); err != nil {
		return nil, err
	}
	return pickUpdate(releases, prefix, current, assetName), nil
}

func download(url, file string) error {
	req, _ := http.NewRequest("GET", url, nil)
	req.Header.Set("User-Agent", "TV-Remote/"+version_)
	res, err := (&http.Client{Timeout: 5 * time.Minute}).Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return fmt.Errorf("download answered HTTP %d", res.StatusCode)
	}
	f, err := os.Create(file)
	if err != nil {
		return err
	}
	_, err = io.Copy(f, io.LimitReader(res.Body, 200<<20))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

// verifySHA256 compares file with the first field of a `shasum -a 256` line.
func verifySHA256(file string, sumLine []byte) error {
	fields := strings.Fields(string(sumLine))
	if len(fields) == 0 {
		return errors.New("empty checksum file")
	}
	data, err := os.ReadFile(file)
	if err != nil {
		return err
	}
	sum := sha256.Sum256(data)
	if !strings.EqualFold(hex.EncodeToString(sum[:]), fields[0]) {
		return errors.New("the download doesn't match its published checksum")
	}
	return nil
}

// fetchUpdate downloads the asset into dir and checks it; returns the verified file.
func fetchUpdate(u *update, dir, name string) (string, error) {
	sums, res, err := request("GET", u.checksum, nil, map[string]string{"User-Agent": "TV-Remote/" + version_}, 30*time.Second)
	if err != nil || res.StatusCode != 200 {
		return "", errors.New("couldn't download the checksum")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	file := dir + string(os.PathSeparator) + name
	if err := download(u.asset, file); err != nil {
		return "", err
	}
	if err := verifySHA256(file, sums); err != nil {
		os.Remove(file)
		return "", err
	}
	return file, nil
}
