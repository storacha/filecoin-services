package config

import (
	"fmt"

	"github.com/spf13/viper"
)

// Load reads configuration from viper and returns a validated Config struct.
// It reads from configuration file, environment variables, and command-line flags
// in that order of precedence (flags override env vars which override config file).
func Load() (*Config, error) {
	var cfg Config

	// Use viper's Unmarshal to populate the Config struct with proper mapstructure tags
	if err := viper.Unmarshal(&cfg); err != nil {
		return nil, fmt.Errorf("failed to unmarshal configuration: %w", err)
	}

	// Validate the configuration
	if err := cfg.Validate(); err != nil {
		return nil, fmt.Errorf("configuration validation failed: %w", err)
	}

	return &cfg, nil
}
