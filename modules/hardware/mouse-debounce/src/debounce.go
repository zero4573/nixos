package main

type debouncer struct {
	pending map[uint16]bool
}

func newDebouncer() *debouncer {
	return &debouncer{pending: map[uint16]bool{}}
}

func (d *debouncer) OnPress(code uint16) (forward bool) {
	if d.pending[code] {
		delete(d.pending, code)
		return false
	}
	return true
}

func (d *debouncer) OnRelease(code uint16) {
	d.pending[code] = true
}

func (d *debouncer) Expire(code uint16) (shouldForward bool) {
	if d.pending[code] {
		delete(d.pending, code)
		return true
	}
	return false
}
