package main

import (
	"os"
	"sync"
	"testing"
	"time"
)

type capturedEvent struct {
	evType, code uint16
	value        int32
}

// pipeDevice builds a device backed by OS pipes instead of a real evdev
// node / uinput device, so run()'s event loop, timer-driven release flush,
// and SYN_REPORT synthesis can be exercised end-to-end without any
// hardware or root privileges. run()'s cleanup path still issues EVIOCGRAB
// release / UI_DEV_DESTROY ioctls against these fds; those simply fail
// (ENOTTY) and are ignored, exactly as they would for any non-evdev fd.
//
// A single background goroutine drains everything run() writes into a
// channel, so tests never issue more than one concurrent Read against the
// capture pipe -- two racing readers on the same fd would make readEvent
// and expectNothingForwarded unreliable.
func pipeDevice(t *testing.T) (d device, feed *os.File, events <-chan capturedEvent) {
	t.Helper()
	srcRead, srcWrite, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	dstRead, dstWrite, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	t.Cleanup(func() {
		srcWrite.Close()
		dstRead.Close()
	})

	ch := make(chan capturedEvent, 64)
	go func() {
		buf := make([]byte, sizeofInputEvent)
		for {
			n, err := readFull(dstRead, buf)
			if err != nil || n != sizeofInputEvent {
				close(ch)
				return
			}
			evType, code, value := decodeEvent(buf)
			ch <- capturedEvent{evType: evType, code: code, value: value}
		}
	}()

	return device{src: srcRead, dst: dstWrite}, srcWrite, ch
}

func writeEvent(t *testing.T, f *os.File, evType, code uint16, value int32) {
	t.Helper()
	if _, err := f.Write(makeEvent(evType, code, value)); err != nil {
		t.Fatalf("write event: %v", err)
	}
}

// expectEvent reads the next forwarded event or fails the test if none
// arrives within timeout.
func expectEvent(t *testing.T, events <-chan capturedEvent, timeout time.Duration) capturedEvent {
	t.Helper()
	select {
	case ev, ok := <-events:
		if !ok {
			t.Fatalf("capture channel closed before an event arrived")
		}
		return ev
	case <-time.After(timeout):
		t.Fatalf("timed out waiting for a forwarded event")
		return capturedEvent{}
	}
}

// expectNothingForwarded fails the test if any event arrives within
// window -- used to confirm a bounce/spurious pair was fully swallowed
// rather than merely delayed.
func expectNothingForwarded(t *testing.T, events <-chan capturedEvent, window time.Duration) {
	t.Helper()
	select {
	case ev, ok := <-events:
		if ok {
			t.Fatalf("expected no forwarded event, but got %+v", ev)
		}
	case <-time.After(window):
	}
}

// stopDevice closes feed and drains events until the background reader in
// pipeDevice sees run() close its end of the pipe and exits. Every test
// must defer this right after starting its device, so run()'s goroutine
// (and any timers it has scheduled) is fully wound down before the test
// returns.
func stopDevice(feed *os.File, events <-chan capturedEvent) {
	feed.Close()
	for range events {
	}
}

// startRun starts d's event loop with the given debounce window, passed
// directly rather than via any shared/global state -- each test gets its
// own independent window value with nothing for concurrently-running
// tests to race on.
func startRun(d device, window time.Duration) {
	mu := &sync.Mutex{}
	managed := map[string]device{"test": d}
	go d.run(mu, managed, "test", window)
}

// TestDeviceMotionPassesThroughImmediately: relative-motion events are
// never debounced and must appear on the virtual device right away.
func TestDeviceMotionPassesThroughImmediately(t *testing.T) {
	d, feed, events := pipeDevice(t)
	startRun(d, 30*time.Millisecond)
	defer stopDevice(feed, events)

	writeEvent(t, feed, evRel, relX, 5)
	ev := expectEvent(t, events, time.Second)
	if ev.evType != evRel || ev.code != relX || ev.value != 5 {
		t.Fatalf("got %+v, want (EV_REL,REL_X,5)", ev)
	}
}

// TestDeviceCleanClickForwardsBoth: a press then a real release (nothing
// cancels it) must both reach the virtual device, release delayed by
// roughly debounceWindow, followed by a synthesized SYN_REPORT.
func TestDeviceCleanClickForwardsBoth(t *testing.T) {
	d, feed, events := pipeDevice(t)
	startRun(d, 30*time.Millisecond)
	defer stopDevice(feed, events)

	writeEvent(t, feed, evKey, btnLeft, 1)
	ev := expectEvent(t, events, time.Second)
	if ev.evType != evKey || ev.code != btnLeft || ev.value != 1 {
		t.Fatalf("press: got %+v", ev)
	}

	writeEvent(t, feed, evKey, btnLeft, 0)
	ev = expectEvent(t, events, time.Second)
	if ev.evType != evKey || ev.code != btnLeft || ev.value != 0 {
		t.Fatalf("release: got %+v", ev)
	}
	ev = expectEvent(t, events, time.Second)
	if ev.evType != evSyn {
		t.Fatalf("expected a synthesized SYN_REPORT after the delayed release, got %+v", ev)
	}
}

// TestDeviceDoubleClickBounceCollapses: press, bounce (release+press
// within the window), real release -- exactly the worn-switch
// double-click failure. Only one press and one (delayed) release should
// ever reach the virtual device.
func TestDeviceDoubleClickBounceCollapses(t *testing.T) {
	d, feed, events := pipeDevice(t)
	startRun(d, 40*time.Millisecond)
	defer stopDevice(feed, events)

	writeEvent(t, feed, evKey, btnLeft, 1)
	expectEvent(t, events, time.Second) // the one real press

	// Bounce, well inside the window.
	writeEvent(t, feed, evKey, btnLeft, 0)
	time.Sleep(5 * time.Millisecond)
	writeEvent(t, feed, evKey, btnLeft, 1)

	// Must NOT see anything forwarded for the bounce itself.
	expectNothingForwarded(t, events, 20*time.Millisecond)

	// Real release, well after the bounce settled.
	writeEvent(t, feed, evKey, btnLeft, 0)
	ev := expectEvent(t, events, time.Second)
	if ev.evType != evKey || ev.code != btnLeft || ev.value != 0 {
		t.Fatalf("expected the real release to eventually forward, got %+v", ev)
	}
}

// TestDeviceSpuriousMidHoldDropCollapses: a long, otherwise ordinary hold
// where the switch spuriously drops contact partway through -- the "mouse
// randomly lets go" symptom. Same expected outcome as the bounce case: the
// drop is invisible downstream, and the click is only released for real
// once the human actually lets go.
func TestDeviceSpuriousMidHoldDropCollapses(t *testing.T) {
	d, feed, events := pipeDevice(t)
	startRun(d, 30*time.Millisecond)
	defer stopDevice(feed, events)

	writeEvent(t, feed, evKey, btnLeft, 1)
	expectEvent(t, events, time.Second)

	// Hold for a while -- much longer than debounceWindow -- before the
	// spurious drop, to prove this isn't just edge-bounce protection.
	time.Sleep(100 * time.Millisecond)
	writeEvent(t, feed, evKey, btnLeft, 0)
	time.Sleep(5 * time.Millisecond)
	writeEvent(t, feed, evKey, btnLeft, 1)

	expectNothingForwarded(t, events, 20*time.Millisecond)

	writeEvent(t, feed, evKey, btnLeft, 0)
	ev := expectEvent(t, events, time.Second)
	if ev.evType != evKey || ev.code != btnLeft || ev.value != 0 {
		t.Fatalf("expected the real release to eventually forward, got %+v", ev)
	}
}

// TestDeviceUnrelatedButtonsIndependent: debouncing one button must not
// stall or swallow events for another.
func TestDeviceUnrelatedButtonsIndependent(t *testing.T) {
	d, feed, events := pipeDevice(t)
	startRun(d, 30*time.Millisecond)
	defer stopDevice(feed, events)

	writeEvent(t, feed, evKey, btnLeft, 1)
	expectEvent(t, events, time.Second)

	const btnRight = btnLeft + 1
	writeEvent(t, feed, evKey, btnRight, 1)
	ev := expectEvent(t, events, time.Second)
	if ev.evType != evKey || ev.code != btnRight || ev.value != 1 {
		t.Fatalf("right button press should forward independently of left's held state, got %+v", ev)
	}
}
