package main

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"sync"
)

const (
	frameStdin    = 'i'
	frameStdinEOF = 'e'
	frameStdout   = 'o'
	frameStderr   = 'r'
	frameExit     = 'x'
)

const maxFrame = 1 << 20

type request struct {
	User        string `json:"user"`
	Host        string `json:"host"`
	Port        int    `json:"port,omitempty"`
	Command     string `json:"command"`
	GitProtocol string `json:"gitProtocol,omitempty"`
	GitDir      string `json:"gitDir,omitempty"`
}

func readRequest(r *bufio.Reader) (request, error) {
	var req request
	line, err := r.ReadBytes('\n')
	if err != nil {
		return req, fmt.Errorf("reading the request: %w", err)
	}
	if len(line) > maxFrame {
		return req, fmt.Errorf("request too long")
	}
	if err := json.Unmarshal(line, &req); err != nil {
		return req, fmt.Errorf("bad request: %w", err)
	}
	return req, nil
}

func writeRequest(w io.Writer, req request) error {
	b, err := json.Marshal(req)
	if err != nil {
		return err
	}
	_, err = w.Write(append(b, '\n'))
	return err
}

type frameWriter struct {
	mu sync.Mutex
	w  io.Writer
}

func (f *frameWriter) frame(typ byte, data []byte) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	var hdr [5]byte
	hdr[0] = typ
	binary.BigEndian.PutUint32(hdr[1:], uint32(len(data)))
	if _, err := f.w.Write(hdr[:]); err != nil {
		return err
	}
	_, err := f.w.Write(data)
	return err
}

func (f *frameWriter) exit(code int) error {
	var b [4]byte
	binary.BigEndian.PutUint32(b[:], uint32(code))
	return f.frame(frameExit, b[:])
}

func (f *frameWriter) copyFrames(typ byte, r io.Reader) error {
	buf := make([]byte, 32*1024)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			if werr := f.frame(typ, buf[:n]); werr != nil {
				return werr
			}
		}
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
	}
}

func readFrame(r io.Reader) (byte, []byte, error) {
	var hdr [5]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return 0, nil, err
	}
	n := binary.BigEndian.Uint32(hdr[1:])
	if n > maxFrame {
		return 0, nil, fmt.Errorf("frame too long (%d bytes)", n)
	}
	data := make([]byte, n)
	if _, err := io.ReadFull(r, data); err != nil {
		return 0, nil, err
	}
	return hdr[0], data, nil
}
