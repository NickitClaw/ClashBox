package requesthistory

import "sync"

// History stores a bounded, chronological snapshot shared by traffic and IPC goroutines.
type History[T any] struct {
	mu          sync.Mutex
	items       []T
	next, limit int
}

func New[T any](limit int) *History[T] {
	if limit <= 0 {
		panic("history limit must be positive")
	}
	return &History[T]{limit: limit}
}

func (h *History[T]) Append(value T) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.items) < h.limit {
		h.items = append(h.items, value)
		return
	}
	h.items[h.next] = value
	h.next = (h.next + 1) % h.limit
}

func (h *History[T]) Clear() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.items = nil
	h.next = 0
}

func (h *History[T]) Snapshot() []T {
	h.mu.Lock()
	defer h.mu.Unlock()
	result := make([]T, 0, len(h.items))
	result = append(result, h.items[h.next:]...)
	return append(result, h.items[:h.next]...)
}
