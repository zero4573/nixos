package main

import "testing"

const testCode uint16 = btnLeft

// TestCleanClick: press, then release with no intervening press and the
// window expiring -- both should forward.
func TestCleanClick(t *testing.T) {
	d := newDebouncer()
	if !d.OnPress(testCode) {
		t.Fatal("plain press should forward")
	}
	d.OnRelease(testCode)
	if !d.Expire(testCode) {
		t.Fatal("release with no cancelling press should forward once its window expires")
	}
}

// TestPressBounce: the classic double-click failure -- a press immediately
// followed by an extra release/press bounce pair before settling. Only the
// first press should ever forward; the bounce pair must be fully absorbed
// and never itself produce a second visible click.
func TestPressBounce(t *testing.T) {
	d := newDebouncer()
	if !d.OnPress(testCode) {
		t.Fatal("initial press should forward")
	}
	d.OnRelease(testCode) // bounce: contact briefly opens
	if d.OnPress(testCode) {
		t.Fatal("bounce re-press should be swallowed, not forwarded as a second click")
	}
	// The bounce's release must never fire once cancelled by the re-press.
	if d.Expire(testCode) {
		t.Fatal("cancelled release must not expire as a real release")
	}
	// Real release, later, with nothing to cancel it.
	d.OnRelease(testCode)
	if !d.Expire(testCode) {
		t.Fatal("the real, uncancelled release should eventually forward")
	}
}

// TestSpuriousMidHoldDrop: the "mouse randomly lets go" symptom -- a
// release/press pair arriving well into a long, otherwise-uneventful hold,
// with no relation to the original press's timing. Must be swallowed just
// like an edge bounce.
func TestSpuriousMidHoldDrop(t *testing.T) {
	d := newDebouncer()
	if !d.OnPress(testCode) {
		t.Fatal("initial press should forward")
	}
	// ... arbitrarily long hold happens here in the real caller, driven by
	// real time between OnPress and the spurious drop below; the
	// debouncer itself has no notion of elapsed time, only of whether a
	// release is currently pending, so nothing needs to be simulated here.
	d.OnRelease(testCode) // spurious: switch momentarily loses contact
	if d.OnPress(testCode) {
		t.Fatal("spurious mid-hold re-press should be swallowed, not forwarded")
	}
	if d.Expire(testCode) {
		t.Fatal("cancelled mid-hold release must not expire as a real release")
	}
}

// TestGenuineReleaseAfterDrop: after a real release actually goes through
// (window expired, nothing cancelled it), the button must be forwardable
// as a fresh press again -- state shouldn't get stuck.
func TestGenuineReleaseAfterDrop(t *testing.T) {
	d := newDebouncer()
	d.OnPress(testCode)
	d.OnRelease(testCode)
	if !d.Expire(testCode) {
		t.Fatal("release should expire and forward")
	}
	if !d.OnPress(testCode) {
		t.Fatal("a genuinely new press after a real release should forward")
	}
}

// TestExpireWithoutPendingIsNoop: Expire must be safe to call for a code
// that has no pending release (e.g. it was already consumed by a prior
// Expire, or a press cancelled it) -- the caller's timer firing late or
// twice must never panic or spuriously forward.
func TestExpireWithoutPendingIsNoop(t *testing.T) {
	d := newDebouncer()
	if d.Expire(testCode) {
		t.Fatal("Expire with nothing pending must not report forward")
	}
}

// TestIndependentButtons: state for one button code must never leak into
// another -- e.g. debouncing the left button must not affect the right.
func TestIndependentButtons(t *testing.T) {
	d := newDebouncer()
	const left, right uint16 = btnLeft, btnLeft + 1

	d.OnPress(left)
	d.OnRelease(left) // left bounce pending

	if !d.OnPress(right) {
		t.Fatal("an unrelated button's press must not be affected by another button's pending release")
	}
	if _, ok := d.pending[right]; ok {
		t.Fatal("right should have no pending release recorded")
	}

	// left's pending release should still be intact and cancellable.
	if d.OnPress(left) {
		t.Fatal("left's bounce re-press should still be swallowed")
	}
}
