package main

// debouncer implements a general fix for two distinct failure modes of a
// worn mechanical mouse switch, using a single mechanism:
//
//  1. Contact bounce at a transition edge: pressing (or releasing) the
//     button produces a rapid down-up-down (or up-down-up) chatter train
//     before the contact settles, instead of one clean transition. This is
//     what causes an intended single click to register as a double-click.
//  2. A spurious mid-hold dropout: while the button is held continuously
//     pressed, a worn contact can intermittently lose contact for an
//     instant, reporting a release immediately followed by a re-press,
//     even though the human never let go. This is the "mouse randomly
//     lets go of the click" symptom -- dropped drags, clicks that don't
//     register as held.
//
// Both look identical from the driver's perspective: a release quickly
// followed by a press of the same button. So every release is held back
// (not forwarded) for `window`; if a press for that same button arrives
// before the window elapses, both are discarded -- from the app's point of
// view, the button was never actually released. If the window elapses with
// no such press, the held-back release is let through, delayed by at most
// `window`.
//
// The actual `window` duration lives in device.go, which owns the timer
// that eventually calls Expire -- this type only tracks which buttons
// currently have a release held back.
//
// Not safe for concurrent use; the caller (device.go) serializes access.
type debouncer struct {
	pending map[uint16]bool
}

func newDebouncer() *debouncer {
	return &debouncer{pending: map[uint16]bool{}}
}

// OnPress reports whether a press event for code should be forwarded. It
// never is when it's really just the tail end of a held-back
// release/press bounce, or the mouse re-asserting a click it never truly
// let go of -- that pair is silently discarded instead.
func (d *debouncer) OnPress(code uint16) (forward bool) {
	if d.pending[code] {
		delete(d.pending, code)
		return false
	}
	return true
}

// OnRelease marks code's release as held back pending `window`, unless
// cancelled first by a matching OnPress. The caller is responsible for
// actually forwarding the release after `window` elapses, via Expire.
func (d *debouncer) OnRelease(code uint16) {
	d.pending[code] = true
}

// Expire reports whether the release deferred by an earlier OnRelease(code)
// is still due to be forwarded now that `window` has elapsed -- i.e.
// whether it was never cancelled by an intervening press. The caller must
// invoke this at most once per OnRelease call, when its timer fires.
func (d *debouncer) Expire(code uint16) (shouldForward bool) {
	if d.pending[code] {
		delete(d.pending, code)
		return true
	}
	return false
}
