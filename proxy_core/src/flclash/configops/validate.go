package configops

import (
	"fmt"

	"github.com/metacubex/mihomo/config"
)

// Validate uses the same semantic parser as activation, without applying the result
// or initializing providers/listeners/changing runtime options. Callers serialize
// it with config loads so geodata parsing observes consistent installed settings.
func Validate(data []byte) (err error) {
	defer func() {
		if value := recover(); value != nil {
			err = fmt.Errorf("invalid configuration: %v", value)
		}
	}()
	raw, err := config.UnmarshalRawConfig(data)
	if err != nil {
		return err
	}
	parsed, err := config.ParseRawConfigForValidation(raw)
	if err != nil {
		return err
	}
	defer config.CloseParsedConfig(parsed)
	return nil
}
