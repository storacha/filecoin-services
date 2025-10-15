package contract

import (
	"context"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/storacha/filecoin-services/go/bindings"
)

const (
	// ERC20DecimalsSelector is the method selector for ERC20.decimals()
	// This is the first 4 bytes of Keccak256("decimals()") = 0x313ce567...
	ERC20DecimalsSelector = "0x313ce567"
)

// ServicePricing contains pricing information from the FilecoinWarmStorageService contract
type ServicePricing struct {
	PricePerTiBPerMonthNoCDN   *big.Int
	PricePerTiBPerMonthWithCDN *big.Int
	TokenAddress               common.Address
	EpochsPerMonth             *big.Int
}

// QueryServicePrice queries the FilecoinWarmStorageService contract for pricing information
// This includes the price per TiB per month, token address, and epochs per month
func QueryServicePrice(ctx context.Context, rpcURL string, serviceContractAddress common.Address) (*ServicePricing, error) {
	client, err := ethclient.DialContext(ctx, rpcURL)
	if err != nil {
		return nil, fmt.Errorf("connecting to RPC: %w", err)
	}
	defer client.Close()

	// Create contract instance
	contract, err := bindings.NewFilecoinWarmStorageServiceCaller(serviceContractAddress, client)
	if err != nil {
		return nil, fmt.Errorf("creating contract caller: %w", err)
	}

	// Call getServicePrice
	pricing, err := contract.GetServicePrice(&bind.CallOpts{Context: ctx})
	if err != nil {
		return nil, fmt.Errorf("calling getServicePrice: %w", err)
	}

	return &ServicePricing{
		PricePerTiBPerMonthNoCDN:   pricing.PricePerTiBPerMonthNoCDN,
		PricePerTiBPerMonthWithCDN: pricing.PricePerTiBPerMonthWithCDN,
		TokenAddress:               pricing.TokenAddress,
		EpochsPerMonth:             pricing.EpochsPerMonth,
	}, nil
}

// QueryTokenDecimals queries an ERC20 token contract for its decimals value
func QueryTokenDecimals(ctx context.Context, rpcURL string, tokenAddress common.Address) (uint8, error) {
	client, err := ethclient.DialContext(ctx, rpcURL)
	if err != nil {
		return 0, fmt.Errorf("connecting to RPC: %w", err)
	}
	defer client.Close()

	// Call the decimals() method using a simple contract call
	data := common.FromHex(ERC20DecimalsSelector)

	msg := ethereum.CallMsg{
		To:   &tokenAddress,
		Data: data,
	}

	result, err := client.CallContract(ctx, msg, nil)
	if err != nil {
		return 0, fmt.Errorf("calling decimals(): %w", err)
	}

	if len(result) != 32 {
		return 0, fmt.Errorf("unexpected result length: got %d, expected 32", len(result))
	}

	// The result is a uint8 encoded as bytes32 (right-padded)
	// We need to extract the last byte
	decimals := result[31]

	return decimals, nil
}
