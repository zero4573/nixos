package main

import "testing"

const testCode uint16 = btnLeft

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

func TestPressBounce(t *testing.T) {
	d := newDebouncer()
	if !d.OnPress(testCode) {
		t.Fatal("initial press should forward")
	}
	d.OnRelease(testCode)
	if d.OnPress(testCode) {
		t.Fatal("bounce re-press should be swallowed, not forwarded as a second click")
	}
	if d.Expire(testCode) {
		t.Fatal("cancelled release must not expire as a real release")
	}
	d.OnRelease(testCode)
	if !d.Expire(testCode) {
		t.Fatal("the real, uncancelled release should eventually forward")
	}
}

func TestSpuriousMidHoldDrop(t *testing.T) {
	d := newDebouncer()
	if !d.OnPress(testCode) {
		t.Fatal("initial press should forward")
	}
	d.OnRelease(testCode)
	if d.OnPress(testCode) {
		t.Fatal("spurious mid-hold re-press should be swallowed, not forwarded")
	}
	if d.Expire(testCode) {
		t.Fatal("cancelled mid-hold release must not expire as a real release")
	}
}

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

func TestExpireWithoutPendingIsNoop(t *testing.T) {
	d := newDebouncer()
	if d.Expire(testCode) {
		t.Fatal("Expire with nothing pending must not report forward")
	}
}

func TestIndependentButtons(t *testing.T) {
	d := newDebouncer()
	const left, right uint16 = btnLeft, btnLeft + 1

	d.OnPress(left)
	d.OnRelease(left)

	if !d.OnPress(right) {
		t.Fatal("an unrelated button's press must not be affected by another button's pending release")
	}
	if _, ok := d.pending[right]; ok {
		t.Fatal("right should have no pending release recorded")
	}

	if d.OnPress(left) {
		t.Fatal("left's bounce re-press should still be swallowed")
	}
}
