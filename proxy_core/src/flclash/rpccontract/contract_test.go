package rpccontract

import (
	"encoding/json"
	"os"
	"testing"
)

// Both language implementations consume these independently specified wire examples.
func TestSharedWireExamples(t *testing.T) {
	data, err := os.ReadFile("../../../../tests/fixtures/rpc-wire.json")
	if err != nil {
		t.Fatal(err)
	}
	var examples struct {
		Requests []struct{ Name, Wire, Endpoint, ErrorCode string }
		Results  []struct {
			Name        string
			Method      int
			Result      any
			StreamReady bool
			Valid       bool
		}
	}
	if err := json.Unmarshal(data, &examples); err != nil {
		t.Fatal(err)
	}
	for _, example := range examples.Requests {
		t.Run(example.Name, func(t *testing.T) {
			_, fault := DecodeRequest([]byte(example.Wire), example.Endpoint)
			code := ""
			if fault != nil {
				code = fault.Code
			}
			if code != example.ErrorCode {
				t.Fatalf("got %q (%v), want %q", code, fault, example.ErrorCode)
			}
		})
	}
	for _, example := range examples.Results {
		t.Run(example.Name, func(t *testing.T) {
			fault := ValidateResult(example.Method, example.Result, example.StreamReady)
			if (fault == nil) != example.Valid {
				t.Fatalf("valid=%v, fault=%v", example.Valid, fault)
			}
		})
	}
}

func TestCompatibilityAndResponseEncoding(t *testing.T) {
	info := CompatibilityJSON("test-core")
	if fault := ValidateResult(GetCapabilities, info, false); fault != nil {
		t.Fatal(fault)
	}
	var decoded Compatibility
	if err := json.Unmarshal([]byte(info), &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.ContractHash != ContractHash || decoded.ProtocolVersion != ProtocolVersion || decoded.NativeABIVersion != NativeABIVersion || decoded.CoreVersion != "test-core" {
		t.Fatalf("unexpected metadata: %+v", decoded)
	}
	// Empty success and false are actual values, whereas failures must omit result.
	for _, value := range []any{"", false} {
		data, err := json.Marshal(Response{ProtocolVersion: ProtocolVersion, Method: StopClash, Result: value})
		if err != nil {
			t.Fatal(err)
		}
		var raw map[string]any
		if err := json.Unmarshal(data, &raw); err != nil {
			t.Fatal(err)
		}
		if result, exists := raw["result"]; !exists || result != value {
			t.Fatalf("lost result: %s", data)
		}
	}
	failure := Failure(HealthCheck, &Fault{INVALID_PARAMS, "invalid timeout"})
	data, err := json.Marshal(failure)
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatal(err)
	}
	if _, exists := raw["result"]; exists {
		t.Fatalf("error contains result: %s", data)
	}
	if raw["errorCode"] != INVALID_PARAMS || raw["method"] != float64(HealthCheck) {
		t.Fatalf("lost error details: %s", data)
	}
}
