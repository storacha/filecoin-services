package contract

import (
	"crypto/ecdsa"
	"fmt"

	"github.com/storacha/filecoin-services/service-operator/internal/config"
)

// SignerManager manages multiple signers for different roles
type SignerManager struct {
	config *config.Config
	// Cache loaded signers to avoid re-loading
	signers map[string]*ecdsa.PrivateKey
}

// NewSignerManager creates a new SignerManager instance
func NewSignerManager(cfg *config.Config) *SignerManager {
	return &SignerManager{
		config:  cfg,
		signers: make(map[string]*ecdsa.PrivateKey),
	}
}

// LoadSigner loads a private key for the specified role
func (sm *SignerManager) LoadSigner(role string) (*ecdsa.PrivateKey, error) {
	// Check cache first
	if key, exists := sm.signers[role]; exists {
		return key, nil
	}

	// Get signer config for the role
	signerConfig, exists := sm.config.Signers[role]
	if !exists {
		return nil, fmt.Errorf("signer for role '%s' not configured", role)
	}

	// Load the private key based on the configuration
	var privateKey *ecdsa.PrivateKey
	var err error

	if signerConfig.PrivateKeyPath != "" {
		privateKey, err = LoadPrivateKey(signerConfig.PrivateKeyPath)
		if err != nil {
			return nil, fmt.Errorf("loading private key for role '%s': %w", role, err)
		}
	} else if signerConfig.KeystorePath != "" {
		privateKey, err = LoadPrivateKeyFromKeystore(signerConfig.KeystorePath, signerConfig.KeystorePassword)
		if err != nil {
			return nil, fmt.Errorf("loading keystore for role '%s': %w", role, err)
		}
	} else {
		return nil, fmt.Errorf("no authentication method configured for role '%s'", role)
	}

	// Cache the loaded key
	sm.signers[role] = privateKey

	return privateKey, nil
}

// LoadOwnerSigner loads the private key for the owner role
func (sm *SignerManager) LoadOwnerSigner() (*ecdsa.PrivateKey, error) {
	return sm.LoadSigner("owner")
}

// LoadPayerSigner loads the private key for the payer role
func (sm *SignerManager) LoadPayerSigner() (*ecdsa.PrivateKey, error) {
	return sm.LoadSigner("payer")
}