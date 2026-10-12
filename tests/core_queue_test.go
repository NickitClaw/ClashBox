package integration_test

import (
	"sync"
	"testing"

	"github.com/metacubex/mihomo/common/queue"
)

func TestLatencyHistoryQueueConcurrentEmptyReadWriteAndPop(t *testing.T) {
	q := queue.New[int](10)
	var wg sync.WaitGroup
	for i := 0; i < 6; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			for j := 0; j < 500; j++ {
				switch n % 3 {
				case 0:
					q.Put(j)
				case 1:
					q.Pop()
				case 2:
					q.Last()
					q.Copy()
				}
			}
		}(i)
	}
	wg.Wait()
	for q.Len() > 0 {
		q.Pop()
	}
	if q.Last() != 0 || q.Pop() != 0 {
		t.Fatal("empty queue returned data")
	}
}
