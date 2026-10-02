package main

import "testing"

// These expected values are the well-known constants produced by the C
// macros in linux/input.h and linux/uinput.h on a 64-bit system, verified
// against a real compiled C program using the kernel's own headers before
// this code was wired into the NixOS module. This test guards our
// from-scratch _IOC reimplementation against arithmetic regressions.
func TestIoctlConstants(t *testing.T) {
	cases := []struct {
		name string
		got  uintptr
		want uintptr
	}{
		{"EVIOCGRAB", eviocgrab, 0x40044590},
		{"UI_SET_EVBIT", uiSetEvbit, 0x40045564},
		{"UI_SET_KEYBIT", uiSetKeybit, 0x40045565},
		{"UI_SET_RELBIT", uiSetRelbit, 0x40045566},
		{"UI_DEV_CREATE", uiDevCreate, 0x5501},
		{"UI_DEV_DESTROY", uiDevDestroy, 0x5502},
		{"UI_DEV_SETUP", uiDevSetup, 0x405c5503},
		{"EVIOCGNAME(256)", eviocgname(256), 0x81004506},
		{"EVIOCGPROP(8)", eviocgprop(8), 0x80084509},
		{"EVIOCGBIT(EV_KEY=1,96)", eviocgbit(evKey, 96), 0x80604521},
		{"EVIOCGBIT(EV_REL=2,2)", eviocgbit(evRel, 2), 0x80024522},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Errorf("%s = 0x%x, want 0x%x", c.name, c.got, c.want)
		}
	}
}

func TestSizeofUinputSetup(t *testing.T) {
	// struct uinput_setup on 64-bit Linux is 92 bytes: struct input_id (8
	// bytes) + name[80] + __u32 ff_effects_max (4 bytes), with no padding
	// since it's already 4-byte aligned throughout.
	if sizeofUinputSetup != 92 {
		t.Errorf("sizeofUinputSetup = %d, want 92", sizeofUinputSetup)
	}
}

func TestTestBit(t *testing.T) {
	mask := []byte{0b00000100, 0b00000001} // bit 2 and bit 8 set
	if !testBit(mask, 2) {
		t.Error("expected bit 2 set")
	}
	if testBit(mask, 3) {
		t.Error("expected bit 3 clear")
	}
	if !testBit(mask, 8) {
		t.Error("expected bit 8 set")
	}
	if testBit(mask, 100) {
		t.Error("expected out-of-range bit to read as clear, not panic")
	}
}

func TestMakeEvent(t *testing.T) {
	buf := makeEvent(evKey, btnLeft, 1)
	if len(buf) != sizeofInputEvent {
		t.Fatalf("len = %d, want %d", len(buf), sizeofInputEvent)
	}
	evType, code, value := decodeEvent(buf)
	if evType != evKey || code != btnLeft || value != 1 {
		t.Errorf("got (%d,%d,%d), want (%d,%d,1)", evType, code, value, evKey, btnLeft)
	}
}
