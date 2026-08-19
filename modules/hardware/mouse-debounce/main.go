// Command mouse-debounce fixes chatter from worn mechanical mouse switches:
// double-clicks that should have been single clicks, and drags/holds that
// spontaneously "let go" mid-click.
//
// It scans /dev/input for pointer devices (mice, not touchpads), grabs each
// one exclusively, and re-emits its events through a virtual uinput device.
// Every button release is held back briefly; if a press for that same
// button arrives before the hold elapses, both are discarded -- as far as
// anything downstream is concerned, the button was never actually
// released. This one mechanism covers both symptoms: a bounce right at the
// press/release edge, and a spurious mid-hold dropout further into a long
// press. Motion and wheel events are never touched and pass through
// immediately. See debounce.go for the debounce state machine and
// device.go for how it's wired into the event stream.
//
// Implemented with raw ioctls against the kernel's evdev/uinput ABI
// (linux/input.h, linux/uinput.h) instead of a library, so the binary has
// zero external dependencies -- only the Go standard library.
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
	// debounceWindow is how long a button release is held back waiting to
	// see whether a press for the same button follows -- i.e. how long a
	// "let go" is given to prove itself real before being forwarded.
	// Passed explicitly into run() rather than read as a global so tests
	// can use their own short window without any shared mutable state
	// between concurrently-running device goroutines.
	debounceWindow = 50 * time.Millisecond

	// rescanInterval is how often /dev/input is re-scanned for newly
	// plugged-in (or unplugged) devices.
	rescanInterval = 2 * time.Second

	inputDir    = "/dev/input"
	virtualName = "mouse-debounce-virtual"
)

func main() {
	log.SetFlags(0)
	log.Printf("mouse-debounce: starting, debounce window %s", debounceWindow)

	managed := map[string]device{} // event path -> running device
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
				continue // already being handled
			}

			name, isMouse, err := classifyDevice(path)
			if err != nil {
				// Device may have raced us on unplug, or we may lack
				// permission (shouldn't happen running as root). Either
				// way, just skip it this round; it'll be retried.
				continue
			}
			if name == virtualName {
				continue // never grab our own virtual output device
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

		// Drop bookkeeping for devices that disappeared from /dev/input;
		// their run() goroutines will already be exiting on read error.
		for path := range managed {
			if !seen[path] {
				delete(managed, path)
			}
		}
		mu.Unlock()

		time.Sleep(rescanInterval)
	}
}

// listEventDevices returns the full paths of every /dev/input/eventN node.
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
