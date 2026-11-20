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

func stopDevice(feed *os.File, events <-chan capturedEvent) {
	feed.Close()
	for range events {
	}
}

func startRun(d device, window time.Duration) {
	mu := &sync.Mutex{}
	managed := map[string]device{"test": d}
	go d.run(mu, managed, "test", window)
}

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

func TestDeviceDoubleClickBounceCollapses(t *testing.T) {
	d, feed, events := pipeDevice(t)
	startRun(d, 40*time.Millisecond)
	defer stopDevice(feed, events)

	writeEvent(t, feed, evKey, btnLeft, 1)
	expectEvent(t, events, time.Second)

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

func TestDeviceSpuriousMidHoldDropCollapses(t *testing.T) {
	d, feed, events := pipeDevice(t)
	startRun(d, 30*time.Millisecond)
	defer stopDevice(feed, events)

	writeEvent(t, feed, evKey, btnLeft, 1)
	expectEvent(t, events, time.Second)

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
