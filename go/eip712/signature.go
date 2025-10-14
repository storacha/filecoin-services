package eip712

import (
	"github.com/ethereum/go-ethereum/common"
)

type AuthSignature struct {
	Signature  []byte         `json:"signature"`
	V          uint8          `json:"v"`
	R          common.Hash    `json:"r"`
	S          common.Hash    `json:"s"`
	SignedData []byte         `json:"signedData"`
	Signer     common.Address `json:"signer"`
}

// Marshal returns the signature as bytes in the format expected by the smart contract
// The format is: R (32 bytes) + S (32 bytes) + V (1 byte)
func (a *AuthSignature) Marshal() ([]byte, error) {
	if len(a.Signature) == 65 {
		// If we already have the full signature, return it
		return a.Signature, nil
	}

	// Otherwise construct it from R, S, V
	sig := make([]byte, 65)
	copy(sig[0:32], a.R[:])
	copy(sig[32:64], a.S[:])
	sig[64] = a.V
	return sig, nil
}
