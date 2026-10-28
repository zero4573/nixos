package main

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"sync"
)

// The client and the broker talk over the git socket: first the client's
// request as one JSON line, then frames both ways, each a type byte, a
// big-endian uint32 length and the data.
const (
	frameStdin    = 'i' // client -> broker: git's output, for the remote
	frameStdinEOF = 'e' // client -> broker: git closed its end
	frameStdout   = 'o' // broker -> client: the remote's output, for git
	frameStderr   = 'r' // broker -> client: messages for the user
	frameExit     = 'x' // broker -> client: exit status, uint32
)

// maxFrame bounds a frame's length, so a bad peer can't make us allocate
// without limit
const maxFrame = 1 << 20

// request is what the client asks for: one git transport command on a
// remote, as git handed it to the ssh command
type request struct {
	User    string `json:"user"`
	Host    string `json:"host"`
	Port    int    `json:"port,omitempty"`
	Command string `json:"command"`
	// GIT_PROTOCOL from git's environment (protocol v2 for fetches)
	GitProtocol string `json:"gitProtocol,omitempty"`
	// The repository's absolute common git dir, for the fast-forward check
	// of a push (empty outside a repository)
	GitDir string `json:"gitDir,omitempty"`
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

// frameWriter serializes frames from several goroutines onto one stream
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

// copyFrames sends everything read from r as frames of type typ
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
