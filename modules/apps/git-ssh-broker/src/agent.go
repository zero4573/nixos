package main

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
)

// ssh-agent protocol (draft-miller-ssh-agent) message types we handle
const (
	agentFailure          = 5
	agentRequestIdentites = 11
	agentIdentitiesAnswer = 12
	agentSignRequest      = 13
)

// signingAgent is a filtering ssh-agent in front of the host's: it lists
// only the signing keys and signs only SSHSIG blobs of the "git" namespace
// (what `ssh-keygen -Y sign -n git` sends for a commit or tag signature).
// An SSH login's signature request starts with a session id, never the
// SSHSIG magic, so it is refused, as is every other request.
type signingAgent struct {
	upstream string
	keys     map[string]bool // allowed public key blobs
	logf     func(format string, args ...any)
}

// loadSigningKeys reads OpenSSH public key files ("<type> <base64> [comment]")
func loadSigningKeys(paths []string) (map[string]bool, error) {
	keys := map[string]bool{}
	for _, p := range paths {
		data, err := os.ReadFile(p)
		if err != nil {
			return nil, err
		}
		f := strings.Fields(string(data))
		if len(f) < 2 {
			return nil, fmt.Errorf("%s: not an OpenSSH public key", p)
		}
		blob, err := base64.StdEncoding.DecodeString(f[1])
		if err != nil {
			return nil, fmt.Errorf("%s: %v", p, err)
		}
		keys[string(blob)] = true
	}
	return keys, nil
}

func (a *signingAgent) serve(l net.Listener) error {
	for {
		c, err := l.Accept()
		if err != nil {
			return err
		}
		go a.handle(c)
	}
}

func (a *signingAgent) handle(c net.Conn) {
	defer c.Close()
	for {
		msg, err := readAgentMsg(c)
		if err != nil {
			return
		}
		reply := a.answer(msg)
		if err := writeAgentMsg(c, reply); err != nil {
			return
		}
	}
}

func (a *signingAgent) answer(msg []byte) []byte {
	failure := []byte{agentFailure}
	if len(msg) == 0 {
		return failure
	}
	switch msg[0] {
	case agentRequestIdentites:
		reply, err := a.upstreamCall(msg)
		if err != nil {
			a.logf("agent: listing keys: %v", err)
			return failure
		}
		filtered, err := a.filterIdentities(reply)
		if err != nil {
			a.logf("agent: %v", err)
			return failure
		}
		return filtered
	case agentSignRequest:
		if err := a.allowSign(msg[1:]); err != nil {
			a.logf("agent: refused a signature: %v", err)
			return failure
		}
		reply, err := a.upstreamCall(msg)
		if err != nil {
			a.logf("agent: signing: %v", err)
			return failure
		}
		a.logf("agent: signed a git signature")
		return reply
	default:
		return failure
	}
}

// allowSign checks a sign request's payload: string key, string data,
// uint32 flags
func (a *signingAgent) allowSign(p []byte) error {
	key, rest, err := readString(p)
	if err != nil {
		return err
	}
	if !a.keys[string(key)] {
		return errors.New("not a signing key")
	}
	data, _, err := readString(rest)
	if err != nil {
		return err
	}
	// SSHSIG: the 6-byte magic, then string namespace, string reserved,
	// string hash algorithm, string hash
	magic := []byte("SSHSIG")
	if !bytes.HasPrefix(data, magic) {
		return errors.New("not an SSHSIG signature (an SSH login?)")
	}
	ns, _, err := readString(data[len(magic):])
	if err != nil {
		return err
	}
	if string(ns) != "git" {
		return fmt.Errorf("namespace %q, only git signatures are allowed", ns)
	}
	return nil
}

// filterIdentities keeps only the signing keys of an identities answer:
// uint32 count, then (string key, string comment) each
func (a *signingAgent) filterIdentities(reply []byte) ([]byte, error) {
	if len(reply) < 5 || reply[0] != agentIdentitiesAnswer {
		return nil, errors.New("unexpected identities answer from the upstream agent")
	}
	n := binary.BigEndian.Uint32(reply[1:5])
	rest := reply[5:]
	var out bytes.Buffer
	kept := uint32(0)
	for i := uint32(0); i < n; i++ {
		key, r, err := readString(rest)
		if err != nil {
			return nil, err
		}
		comment, r, err := readString(r)
		if err != nil {
			return nil, err
		}
		rest = r
		if a.keys[string(key)] {
			writeString(&out, key)
			writeString(&out, comment)
			kept++
		}
	}
	res := []byte{agentIdentitiesAnswer, 0, 0, 0, 0}
	binary.BigEndian.PutUint32(res[1:], kept)
	return append(res, out.Bytes()...), nil
}

func (a *signingAgent) upstreamCall(msg []byte) ([]byte, error) {
	c, err := net.Dial("unix", a.upstream)
	if err != nil {
		return nil, err
	}
	defer c.Close()
	if err := writeAgentMsg(c, msg); err != nil {
		return nil, err
	}
	return readAgentMsg(c)
}

func readAgentMsg(r io.Reader) ([]byte, error) {
	var l [4]byte
	if _, err := io.ReadFull(r, l[:]); err != nil {
		return nil, err
	}
	n := binary.BigEndian.Uint32(l[:])
	if n > 256*1024 {
		return nil, fmt.Errorf("agent message too long (%d bytes)", n)
	}
	msg := make([]byte, n)
	_, err := io.ReadFull(r, msg)
	return msg, err
}

func writeAgentMsg(w io.Writer, msg []byte) error {
	var l [4]byte
	binary.BigEndian.PutUint32(l[:], uint32(len(msg)))
	_, err := w.Write(append(l[:], msg...))
	return err
}

func readString(p []byte) (s, rest []byte, err error) {
	if len(p) < 4 {
		return nil, nil, errors.New("truncated message")
	}
	n := binary.BigEndian.Uint32(p)
	if uint64(len(p)-4) < uint64(n) {
		return nil, nil, errors.New("truncated message")
	}
	return p[4 : 4+n], p[4+n:], nil
}

func writeString(b *bytes.Buffer, s []byte) {
	var l [4]byte
	binary.BigEndian.PutUint32(l[:], uint32(len(s)))
	b.Write(l[:])
	b.Write(s)
}
