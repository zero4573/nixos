package main

import (
	"encoding/binary"
	"fmt"
	"os"
	"strings"
	"syscall"
	"unsafe"
)

// ioctl number encoding from include/uapi/asm-generic/ioctl.h

const (
	iocNRBits   = 8
	iocTypeBits = 8
	iocSizeBits = 14

	iocNRShift   = 0
	iocTypeShift = iocNRShift + iocNRBits
	iocSizeShift = iocTypeShift + iocTypeBits
	iocDirShift  = iocSizeShift + iocSizeBits

	iocNone  = uintptr(0)
	iocWrite = uintptr(1)
	iocRead  = uintptr(2)
)

func ioc(dir, typ, nr, size uintptr) uintptr {
	return (dir << iocDirShift) | (typ << iocTypeShift) | (nr << iocNRShift) | (size << iocSizeShift)
}

func iow(typ, nr, size uintptr) uintptr { return ioc(iocWrite, typ, nr, size) }
func ior(typ, nr, size uintptr) uintptr { return ioc(iocRead, typ, nr, size) }
func io0(typ, nr uintptr) uintptr       { return ioc(iocNone, typ, nr, 0) }

const (
	typeE = uintptr('E') // evdev ioctls, linux/input.h
	typeU = uintptr('U') // uinput ioctls, linux/uinput.h
)

// linux/input-event-codes.h
const (
	evSyn = 0x00
	evKey = 0x01
	evRel = 0x02
	evAbs = 0x03

	synReport = 0x00 // SYN_REPORT

	relX = 0x00

	btnLeft = 0x110 // BTN_LEFT
	btnTask = 0x117 // BTN_TASK

	inputPropButtonpad = 0x02 // INPUT_PROP_BUTTONPAD
)

// sizeof(struct input_event) on 64-bit Linux: struct timeval (two 8-byte
// longs), u16 type, u16 code, s32 value, no trailing padding
const sizeofInputEvent = 24

// sizeof(struct uinput_setup): struct input_id (4x u16), name[UINPUT_MAX_NAME_SIZE], u32 ff_effects_max
const sizeofUinputSetup = 8 + 80 + 4
const uinputMaxNameSize = 80

var (
	eviocgrab = iow(typeE, 0x90, 4) // EVIOCGRAB(int)

	uiSetEvbit   = iow(typeU, 100, 4) // UI_SET_EVBIT(int)
	uiSetKeybit  = iow(typeU, 101, 4) // UI_SET_KEYBIT(int)
	uiSetRelbit  = iow(typeU, 102, 4) // UI_SET_RELBIT(int)
	uiDevSetup   = iow(typeU, 3, sizeofUinputSetup)
	uiDevCreate  = io0(typeU, 1)
	uiDevDestroy = io0(typeU, 2)
)

func eviocgname(length uintptr) uintptr    { return ior(typeE, 0x06, length) }    // EVIOCGNAME(len)
func eviocgbit(ev, length uintptr) uintptr { return ior(typeE, 0x20+ev, length) } // EVIOCGBIT(ev,len)
func eviocgprop(length uintptr) uintptr    { return ior(typeE, 0x09, length) }    // EVIOCGPROP(len)

func ioctl(fd int, req uintptr, arg uintptr) error {
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), req, arg)
	if errno != 0 {
		return errno
	}
	return nil
}

func testBit(mask []byte, n uintptr) bool {
	byteIdx := n / 8
	if int(byteIdx) >= len(mask) {
		return false
	}
	return mask[byteIdx]&(1<<(n%8)) != 0
}

func makeEvent(evType, code uint16, value int32) []byte {
	buf := make([]byte, sizeofInputEvent)
	binary.LittleEndian.PutUint16(buf[16:18], evType)
	binary.LittleEndian.PutUint16(buf[18:20], code)
	binary.LittleEndian.PutUint32(buf[20:24], uint32(value))
	return buf
}

func decodeEvent(buf []byte) (evType, code uint16, value int32) {
	return binary.LittleEndian.Uint16(buf[16:18]),
		binary.LittleEndian.Uint16(buf[18:20]),
		int32(binary.LittleEndian.Uint32(buf[20:24]))
}

func classifyDevice(path string) (name string, isMouse bool, err error) {
	f, err := os.Open(path)
	if err != nil {
		return "", false, err
	}
	defer f.Close()
	fd := int(f.Fd())

	nameBuf := make([]byte, 256)
	if err := ioctl(fd, eviocgname(uintptr(len(nameBuf))), uintptr(unsafe.Pointer(&nameBuf[0]))); err != nil {
		return "", false, fmt.Errorf("EVIOCGNAME: %w", err)
	}
	name = string(nameBuf[:cIndex(nameBuf)])

	propBuf := make([]byte, 8)
	// older kernels lack EVIOCGPROP: an error means no properties reported
	_ = ioctl(fd, eviocgprop(uintptr(len(propBuf))), uintptr(unsafe.Pointer(&propBuf[0])))
	if testBit(propBuf, inputPropButtonpad) {
		return name, false, nil
	}

	keyBuf := make([]byte, (btnTask/8)+1)
	if err := ioctl(fd, eviocgbit(evKey, uintptr(len(keyBuf))), uintptr(unsafe.Pointer(&keyBuf[0]))); err != nil {
		return name, false, nil
	}
	if !testBit(keyBuf, btnLeft) {
		return name, false, nil
	}

	relBuf := make([]byte, 1)
	if err := ioctl(fd, eviocgbit(evRel, uintptr(len(relBuf))), uintptr(unsafe.Pointer(&relBuf[0]))); err != nil {
		return name, false, nil
	}
	if !testBit(relBuf, relX) {
		return name, false, nil
	}

	absBuf := make([]byte, 1)
	if err := ioctl(fd, eviocgbit(evAbs, uintptr(len(absBuf))), uintptr(unsafe.Pointer(&absBuf[0]))); err == nil {
		if absBuf[0] != 0 {
			return name, false, nil
		}
	}

	lower := strings.ToLower(name)
	if strings.Contains(lower, "touchpad") || strings.Contains(lower, "trackpad") {
		return name, false, nil
	}

	return name, true, nil
}

func cIndex(b []byte) int {
	for i, c := range b {
		if c == 0 {
			return i
		}
	}
	return len(b)
}
