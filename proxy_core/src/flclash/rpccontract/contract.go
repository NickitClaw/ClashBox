// Package rpccontract validates the shared wire contract without native/core dependencies.
package rpccontract

import (
	"encoding/json"
	"fmt"
	"math"
	"regexp"
	"strconv"
)

type Shape struct {
	Type      string   `json:"type"`
	Nullable  bool     `json:"nullable"`
	MinLength int      `json:"minLength"`
	Min       *float64 `json:"min"`
	Max       *float64 `json:"max"`
	Enum      []string `json:"enum"`
	Fields    []Field  `json:"fields"`
	Items     *Shape   `json:"items"`
	Content   *Shape   `json:"content"`
}
type Field struct {
	Name     string `json:"name"`
	Shape    Shape  `json:"shape"`
	Optional bool   `json:"optional"`
}
type Method struct {
	ID        int     `json:"id"`
	ArkName   string  `json:"arkName"`
	Endpoint  string  `json:"endpoint"`
	Supported bool    `json:"supported"`
	Stream    bool    `json:"stream"`
	Params    []Field `json:"params"`
	Result    Shape   `json:"result"`
}
type manifest struct {
	Methods      []Method `json:"methods"`
	Capabilities []string `json:"capabilities"`
}

var definition manifest
var methods = map[int]Method{}

func init() {
	if err := json.Unmarshal([]byte(schemaJSON), &definition); err != nil {
		panic(err)
	}
	for _, m := range definition.Methods {
		methods[m.ID] = m
	}
}
func Lookup(id int) (Method, bool) { m, ok := methods[id]; return m, ok }

type Request struct {
	ProtocolVersion int   `json:"protocolVersion"`
	Key             int   `json:"key,omitempty"`
	Method          int   `json:"method"`
	Params          []any `json:"params"`
}
type Response struct {
	ProtocolVersion int    `json:"protocolVersion"`
	Key             int    `json:"key,omitempty"`
	Method          int    `json:"method"`
	Result          any    `json:"result,omitempty"`
	Error           string `json:"error,omitempty"`
	ErrorCode       string `json:"errorCode,omitempty"`
	StreamReady     bool   `json:"streamReady,omitempty"`
}
type Fault struct {
	Code    string
	Message string
}

func (e *Fault) Error() string { return e.Code + ": " + e.Message }
func Failure(method int, fault *Fault) Response {
	return Response{ProtocolVersion: ProtocolVersion, Method: method, Error: fault.Message, ErrorCode: fault.Code}
}
func DecodeRequest(data []byte, endpoint string) (Request, *Fault) {
	request := Request{Method: -1}
	var raw map[string]any
	if json.Unmarshal(data, &raw) != nil || raw == nil {
		return request, &Fault{INVALID_REQUEST, "request must be a JSON object"}
	}
	if method, ok := raw["method"].(float64); ok && safeInteger(method) {
		request.Method = int(method)
	} else {
		return request, &Fault{INVALID_REQUEST, "method must be an integer"}
	}
	version, ok := raw["protocolVersion"].(float64)
	if !ok || version != ProtocolVersion {
		return request, &Fault{INCOMPATIBLE_VERSION, "RPC protocol version mismatch; update application and native library together"}
	}
	request.ProtocolVersion = int(version)
	spec, ok := Lookup(request.Method)
	if !ok {
		return request, &Fault{UNKNOWN_METHOD, "unknown RPC method"}
	}
	if !spec.Supported || (endpoint != "" && endpoint != spec.Endpoint) {
		return request, &Fault{UNSUPPORTED_METHOD, "RPC method is not supported on this endpoint"}
	}
	params, ok := raw["params"].([]any)
	if !ok {
		return request, &Fault{INVALID_PARAMS, "params must be an array"}
	}
	request.Params = params
	if len(params) > len(spec.Params) {
		return request, &Fault{INVALID_PARAMS, spec.ArkName + ": too many parameters"}
	}
	for i, field := range spec.Params {
		if i >= len(params) {
			if field.Optional {
				continue
			}
			return request, &Fault{INVALID_PARAMS, spec.ArkName + ": missing " + field.Name}
		}
		if !matches(params[i], field.Shape) {
			return request, &Fault{INVALID_PARAMS, spec.ArkName + ": invalid " + field.Name}
		}
	}
	return request, nil
}
func ValidateResult(method int, result any, ready bool) *Fault {
	spec, ok := Lookup(method)
	if !ok || !spec.Supported {
		return &Fault{INVALID_RESPONSE, "response for unsupported method"}
	}
	if ready {
		if spec.Stream && result == "" {
			return nil
		}
	} else if matches(result, spec.Result) {
		return nil
	}
	return &Fault{INVALID_RESPONSE, spec.ArkName + ": response does not match contract"}
}

var digits = regexp.MustCompile(`^[0-9]+$`)

func safeInteger(n float64) bool {
	return !math.IsNaN(n) && !math.IsInf(n, 0) && math.Trunc(n) == n && math.Abs(n) <= 9007199254740991
}
func matches(value any, shape Shape) bool {
	if value == nil {
		return shape.Nullable
	}
	switch shape.Type {
	case "boolean":
		_, ok := value.(bool)
		return ok
	case "number", "integer":
		n, ok := value.(float64)
		if !ok || math.IsNaN(n) || math.IsInf(n, 0) || (shape.Type == "integer" && !safeInteger(n)) {
			return false
		}
		return (shape.Min == nil || n >= *shape.Min) && (shape.Max == nil || n <= *shape.Max)
	case "string", "decimalString":
		s, ok := value.(string)
		if !ok || len([]rune(s)) < shape.MinLength {
			return false
		}
		if shape.Type == "decimalString" {
			n, err := strconv.ParseFloat(s, 64)
			return digits.MatchString(s) && err == nil && safeInteger(n)
		}
		if len(shape.Enum) > 0 {
			for _, choice := range shape.Enum {
				if s == choice {
					return true
				}
			}
			return false
		}
		return true
	case "json":
		s, ok := value.(string)
		if !ok || shape.Content == nil {
			return false
		}
		var decoded any
		return json.Unmarshal([]byte(s), &decoded) == nil && matches(decoded, *shape.Content)
	case "array":
		list, ok := value.([]any)
		if !ok || shape.Items == nil {
			return false
		}
		for _, item := range list {
			if !matches(item, *shape.Items) {
				return false
			}
		}
		return true
	case "object":
		object, ok := value.(map[string]any)
		if !ok {
			return false
		}
		for _, field := range shape.Fields {
			item, exists := object[field.Name]
			if !exists && field.Optional {
				continue
			}
			if !exists || !matches(item, field.Shape) {
				return false
			}
		}
		return true
	}
	return false
}

type Compatibility struct {
	ProtocolVersion  int      `json:"protocolVersion"`
	NativeABIVersion int      `json:"nativeAbiVersion"`
	ContractHash     string   `json:"contractHash"`
	CoreVersion      string   `json:"coreVersion"`
	Capabilities     []string `json:"capabilities"`
}

func CompatibilityJSON(coreVersion string) string {
	if coreVersion == "" {
		coreVersion = "unknown"
	}
	data, err := json.Marshal(Compatibility{ProtocolVersion, NativeABIVersion, ContractHash, coreVersion, definition.Capabilities})
	if err != nil {
		panic(fmt.Sprintf("marshal compatibility: %v", err))
	}
	return string(data)
}
