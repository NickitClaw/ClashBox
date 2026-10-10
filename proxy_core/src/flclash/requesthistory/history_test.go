package requesthistory

import (
	"encoding/json"
	"reflect"
	"sync"
	"testing"
)

func TestOrderingRetentionAndIndependentSnapshots(t *testing.T) {
	h := New[int](3)
	for i := 0; i < 5; i++ {
		h.Append(i)
	}
	snapshot := h.Snapshot()
	if !reflect.DeepEqual(snapshot, []int{2, 3, 4}) {
		t.Fatal(snapshot)
	}
	h.Append(5)
	h.Clear()
	if !reflect.DeepEqual(snapshot, []int{2, 3, 4}) {
		t.Fatal("snapshot shares live storage")
	}
	data, _ := json.Marshal(h.Snapshot())
	if string(data) != "[]" {
		t.Fatal(string(data))
	}
	h.Append(6)
	if !reflect.DeepEqual(h.Snapshot(), []int{6}) {
		t.Fatal("clear did not reset ring")
	}
}

func TestConcurrentAppendQueryAndClear(t *testing.T) {
	h := New[int](1000)
	var wg sync.WaitGroup
	for g := 0; g < 12; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 1000; i++ {
				h.Append(i)
				if i%17 == 0 {
					_, _ = json.Marshal(h.Snapshot())
				}
				if i%29 == 0 {
					h.Clear()
				}
			}
		}()
	}
	wg.Wait()
	if len(h.Snapshot()) > 1000 {
		t.Fatal("history exceeded its bound")
	}
}
