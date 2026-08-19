package main

import (
	"encoding/binary"
	"fmt"
	"log"
	"os"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

const (
	keyMax = 0x2ff // KEY_MAX, linux/input-event-codes.h
	relMax = 0x0f  // REL_MAX

	busVirtual = 0x06 // BUS_VIRTUAL, linux/input.h
)

// device holds one grabbed real mouse and the virtual device that mirrors
// its (debounced) events.
type device struct {
	src *os.File
	dst *os.File
}

// newDevice grabs the real device at path exclusively and creates a
// matching virtual uinput device that will carry its debounced output.
func newDevice(path, name string) (device, error) {
	src, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return device{}, fmt.Errorf("open source: %w", err)
	}

	if err := ioctl(int(src.Fd()), eviocgrab, 1); err != nil {
		src.Close()
		return device{}, fmt.Errorf("EVIOCGRAB: %w", err)
	}

	keyBits := make([]byte, (keyMax/8)+1)
	if err := ioctl(int(src.Fd()), eviocgbit(evKey, uintptr(len(keyBits))), uintptr(unsafe.Pointer(&keyBits[0]))); err != nil {
		src.Close()
		return device{}, fmt.Errorf("EVIOCGBIT(EV_KEY): %w", err)
	}
	relBits := make([]byte, (relMax/8)+1)
	if err := ioctl(int(src.Fd()), eviocgbit(evRel, uintptr(len(relBits))), uintptr(unsafe.Pointer(&relBits[0]))); err != nil {
		src.Close()
		return device{}, fmt.Errorf("EVIOCGBIT(EV_REL): %w", err)
	}

	dst, err := os.OpenFile("/dev/uinput", os.O_WRONLY, 0)
	if err != nil {
		_ = ioctl(int(src.Fd()), eviocgrab, 0)
		src.Close()
		return device{}, fmt.Errorf("open /dev/uinput: %w", err)
	}
	dfd := int(dst.Fd())

	fail := func(stage string, err error) (device, error) {
		dst.Close()
		_ = ioctl(int(src.Fd()), eviocgrab, 0)
		src.Close()
		return device{}, fmt.Errorf("%s: %w", stage, err)
	}

	if err := ioctl(dfd, uiSetEvbit, evSyn); err != nil {
		return fail("UI_SET_EVBIT(EV_SYN)", err)
	}
	if err := ioctl(dfd, uiSetEvbit, evKey); err != nil {
		return fail("UI_SET_EVBIT(EV_KEY)", err)
	}
	if err := ioctl(dfd, uiSetEvbit, evRel); err != nil {
		return fail("UI_SET_EVBIT(EV_REL)", err)
	}
	for code := uintptr(0); code <= keyMax; code++ {
		if testBit(keyBits, code) {
			if err := ioctl(dfd, uiSetKeybit, code); err != nil {
				return fail(fmt.Sprintf("UI_SET_KEYBIT(%d)", code), err)
			}
		}
	}
	for code := uintptr(0); code <= relMax; code++ {
		if testBit(relBits, code) {
			if err := ioctl(dfd, uiSetRelbit, code); err != nil {
				return fail(fmt.Sprintf("UI_SET_RELBIT(%d)", code), err)
			}
		}
	}

	setup := make([]byte, sizeofUinputSetup)
	// struct input_id { u16 bustype, vendor, product, version }
	binary.LittleEndian.PutUint16(setup[0:2], busVirtual)
	binary.LittleEndian.PutUint16(setup[2:4], 1)
	binary.LittleEndian.PutUint16(setup[4:6], 1)
	binary.LittleEndian.PutUint16(setup[6:8], 1)
	// name[UINPUT_MAX_NAME_SIZE], NUL-terminated/padded
	copy(setup[8:8+uinputMaxNameSize-1], virtualName)
	// ff_effects_max stays 0

	if err := ioctl(dfd, uiDevSetup, uintptr(unsafe.Pointer(&setup[0]))); err != nil {
		return fail("UI_DEV_SETUP", err)
	}
	if err := ioctl(dfd, uiDevCreate, 0); err != nil {
		return fail("UI_DEV_CREATE", err)
	}

	// Conventional small delay to let udev/libinput register the new
	// device node before we might race a rescan against it.
	time.Sleep(100 * time.Millisecond)

	return device{src: src, dst: dst}, nil
}

// run reads events from the grabbed device, debounces button presses and
// releases (see debounce.go) using the given window, and writes the result
// to the virtual device, until the source device errors out (typically
// because it was unplugged).
func (c device) run(mu *sync.Mutex, managed map[string]device, path string, window time.Duration) {
	defer func() {
		mu.Lock()
		delete(managed, path)
		mu.Unlock()

		_ = ioctl(int(c.dst.Fd()), uiDevDestroy, 0)
		c.dst.Close()
		_ = ioctl(int(c.src.Fd()), eviocgrab, 0)
		c.src.Close()
		log.Printf("mouse-debounce: stopped debouncing %s", path)
	}()

	db := newDebouncer()

	// state guards db, dst writes, and stopped together so the read loop
	// and the timer callbacks scheduled by scheduleFlush never race on
	// any of them.
	var state sync.Mutex
	stopped := false

	// writeLocked must be called with state held.
	writeLocked := func(buf []byte) error {
		if stopped {
			return nil
		}
		_, err := c.dst.Write(buf)
		return err
	}

	// scheduleFlush arranges for code's held-back release to be forwarded
	// (preceded by a synthetic SYN_REPORT to close out its own report)
	// once window elapses, unless a press cancels it first via db.OnPress.
	scheduleFlush := func(code uint16) {
		time.AfterFunc(window, func() {
			state.Lock()
			defer state.Unlock()
			if stopped || !db.Expire(code) {
				return
			}
			if err := writeLocked(makeEvent(evKey, code, 0)); err == nil {
				_ = writeLocked(makeEvent(evSyn, synReport, 0))
			}
		})
	}

	buf := make([]byte, sizeofInputEvent)
	for {
		if _, err := readFull(c.src, buf); err != nil {
			state.Lock()
			stopped = true
			state.Unlock()
			return
		}

		evType, evCode, evValue := decodeEvent(buf)

		if evType == evKey && evValue == 1 {
			state.Lock()
			forward := db.OnPress(evCode)
			state.Unlock()
			if !forward {
				continue // swallow: bounce, or a mid-hold drop recovering
			}
		} else if evType == evKey && evValue == 0 {
			state.Lock()
			db.OnRelease(evCode)
			state.Unlock()
			scheduleFlush(evCode)
			continue // held back; forwarded later by scheduleFlush, or cancelled
		}

		state.Lock()
		err := writeLocked(buf)
		state.Unlock()
		if err != nil {
			state.Lock()
			stopped = true
			state.Unlock()
			return
		}
	}
}

func readFull(f *os.File, buf []byte) (int, error) {
	total := 0
	for total < len(buf) {
		n, err := f.Read(buf[total:])
		if n > 0 {
			total += n
		}
		if err != nil {
			return total, err
		}
		if n == 0 {
			return total, syscall.EIO
		}
	}
	return total, nil
}
