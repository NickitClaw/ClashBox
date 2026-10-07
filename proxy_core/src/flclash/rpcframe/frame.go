// Package rpcframe implements the shared ArkTS/Go IPC wire format.
package rpcframe

import (
	"encoding/binary"
	"errors"
	"io"
)

const MaxSize = 4 * 1024 * 1024

func Read(r io.Reader) ([]byte, error) {
	var header [4]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return nil, err
	}
	size := binary.BigEndian.Uint32(header[:])
	if size == 0 || size > MaxSize {
		return nil, errors.New("invalid RPC frame size")
	}
	payload := make([]byte, int(size))
	_, err := io.ReadFull(r, payload)
	return payload, err
}

func Write(w io.Writer, payload []byte) error {
	if len(payload) == 0 || len(payload) > MaxSize {
		return errors.New("invalid RPC frame size")
	}
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], uint32(len(payload)))
	for _, data := range [][]byte{header[:], payload} {
		for len(data) > 0 {
			n, err := w.Write(data)
			if err != nil {
				return err
			}
			if n <= 0 {
				return io.ErrShortWrite
			}
			data = data[n:]
		}
	}
	return nil
}
