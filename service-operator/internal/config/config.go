package config

import (
	"fmt"
	"net/url"

	"github.com/ethereum/go-ethereum/common"
)

// SignerConfig represents the configuration for a single signer (either keystore or private key)
type SignerConfig struct {
	PrivateKeyPath   string `mapstructure:"private_key"`       // Path to private key file
	KeystorePath     string `mapstructure:"keystore"`          // Path to encrypted keystore
	KeystorePassword string `mapstructure:"keystore_password"` // Keystore password
}

// Config represents the complete configuration for the service-operator CLI
type Config struct {
	// Network configuration
	RPCUrl string `mapstructure:"rpc_url"`

	// Contract addresses
	ServiceContractAddress         string `mapstructure:"service_contract_address"`          // FilecoinWarmStorageService (Proxy)
	VerifierContractAddress        string `mapstructure:"verifier_contract_address"`         // PDPVerifier (Proxy)
	ServiceRegistryContractAddress string `mapstructure:"service_registry_contract_address"` // ServiceProviderRegistry (Proxy)
	PaymentsContractAddress        string `mapstructure:"payments_contract_address"`         // Payments Contract
	TokenContractAddress           string `mapstructure:"token_contract_address"`            // USDFC Token

	// Signers for different roles
	Signers map[string]SignerConfig `mapstructure:"signers"` // Map of role -> signer config
}

// Validate checks that all required configuration fields are set and valid
func (c *Config) Validate() error {
	// Validate RPC URL
	if c.RPCUrl == "" {
		return fmt.Errorf("rpc_url is required")
	}
	if _, err := url.Parse(c.RPCUrl); err != nil {
		return fmt.Errorf("invalid rpc_url: %w", err)
	}

	// Validate contract addresses
	if c.ServiceContractAddress == "" {
		return fmt.Errorf("service_contract_address is required")
	}
	if !common.IsHexAddress(c.ServiceContractAddress) {
		return fmt.Errorf("invalid service_contract_address: %s", c.ServiceContractAddress)
	}

	if c.VerifierContractAddress == "" {
		return fmt.Errorf("verifier_contract_address is required")
	}
	if !common.IsHexAddress(c.VerifierContractAddress) {
		return fmt.Errorf("invalid verifier_contract_address: %s", c.VerifierContractAddress)
	}

	if c.ServiceRegistryContractAddress == "" {
		return fmt.Errorf("service_registry_contract_address is required")
	}
	if !common.IsHexAddress(c.ServiceRegistryContractAddress) {
		return fmt.Errorf("invalid service_registry_contract_address: %s", c.ServiceRegistryContractAddress)
	}

	if c.PaymentsContractAddress == "" {
		return fmt.Errorf("payments_contract_address is required")
	}
	if !common.IsHexAddress(c.PaymentsContractAddress) {
		return fmt.Errorf("invalid payments_contract_address: %s", c.PaymentsContractAddress)
	}

	if c.TokenContractAddress == "" {
		return fmt.Errorf("token_contract_address is required")
	}
	if !common.IsHexAddress(c.TokenContractAddress) {
		return fmt.Errorf("invalid token_contract_address: %s", c.TokenContractAddress)
	}

	// Validate signers
	if c.Signers == nil || len(c.Signers) == 0 {
		return fmt.Errorf("signers configuration is required")
	}

	// Check for required signers
	requiredSigners := []string{"owner", "payer"}
	for _, role := range requiredSigners {
		signer, exists := c.Signers[role]
		if !exists {
			return fmt.Errorf("required signer '%s' not configured", role)
		}

		// Validate signer configuration
		if err := validateSignerConfig(role, signer); err != nil {
			return err
		}
	}

	return nil
}

// validateSignerConfig validates a single signer configuration
func validateSignerConfig(role string, signer SignerConfig) error {
	if signer.PrivateKeyPath == "" && signer.KeystorePath == "" {
		return fmt.Errorf("signer '%s': either private_key or keystore must be provided", role)
	}

	if signer.PrivateKeyPath != "" && signer.KeystorePath != "" {
		return fmt.Errorf("signer '%s': only one authentication method should be provided: either private_key or keystore, not both", role)
	}

	if signer.KeystorePath != "" && signer.KeystorePassword == "" {
		return fmt.Errorf("signer '%s': keystore_password is required when using keystore", role)
	}

	return nil
}

// ServiceAddr returns the service contract address as a common.Address
func (c *Config) ServiceAddr() common.Address {
	return common.HexToAddress(c.ServiceContractAddress)
}

// VerifierAddr returns the verifier contract address as a common.Address
func (c *Config) VerifierAddr() common.Address {
	return common.HexToAddress(c.VerifierContractAddress)
}

// ServiceRegistryAddr returns the service registry contract address as a common.Address
func (c *Config) ServiceRegistryAddr() common.Address {
	return common.HexToAddress(c.ServiceRegistryContractAddress)
}

// PaymentsAddr returns the payments contract address as a common.Address
func (c *Config) PaymentsAddr() common.Address {
	return common.HexToAddress(c.PaymentsContractAddress)
}

// TokenAddr returns the token contract address as a common.Address
func (c *Config) TokenAddr() common.Address {
	return common.HexToAddress(c.TokenContractAddress)
}
