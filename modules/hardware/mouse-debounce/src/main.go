package main

import (
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	debounceWindow = 50 * time.Millisecond

	rescanInterval = 2 * time.Second

	inputDir    = "/dev/input"
	virtualName = "mouse-debounce-virtual"
)

func main() {
	log.SetFlags(0)
	log.Printf("mouse-debounce: starting, debounce window %s", debounceWindow)

	managed := map[string]device{}
	var mu sync.Mutex

	for {
		paths, err := listEventDevices(inputDir)
		if err != nil {
			log.Printf("mouse-debounce: listing %s: %v", inputDir, err)
			time.Sleep(rescanInterval)
			continue
		}

		mu.Lock()
		seen := map[string]bool{}
		for _, path := range paths {
			seen[path] = true
			if _, ok := managed[path]; ok {
				continue
			}

			name, isMouse, err := classifyDevice(path)
			if err != nil {
				continue
			}
			if name == virtualName {
				continue
			}
			if !isMouse {
				continue
			}

			d, err := newDevice(path, name)
			if err != nil {
				log.Printf("mouse-debounce: %s (%s): %v", path, name, err)
				continue
			}
			managed[path] = d
			log.Printf("mouse-debounce: debouncing %s (%s)", path, name)
			go d.run(&mu, managed, path, debounceWindow)
		}

		for path := range managed {
			if !seen[path] {
				delete(managed, path)
			}
		}
		mu.Unlock()

		time.Sleep(rescanInterval)
	}
}

func listEventDevices(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var out []string
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), "event") {
			out = append(out, filepath.Join(dir, e.Name()))
		}
	}
	return out, nil
}
