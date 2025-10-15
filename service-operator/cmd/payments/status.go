package payments

import (
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/spf13/cobra"

	"github.com/storacha/filecoin-services/go/bindings"
	"github.com/storacha/filecoin-services/service-operator/internal/config"
	"github.com/storacha/filecoin-services/service-operator/internal/contract"
	"github.com/storacha/filecoin-services/service-operator/internal/payments"
)

var statusCmd = &cobra.Command{
	Use:   "status",
	Short: "Display account balance, operator approval, and active payment rails",
	Long: `Display your current account balance in the Payments contract, the
approval status of the FilecoinWarmStorageService contract as an operator,
and all active payment rails.

This shows:
- Your account balance (funds and lockup information)
- Operator approval status (allowances and usage)
- Available capacity for creating new payment rails
- Active payment rails with their IDs (needed for settlement)

Examples:
  # Check status on calibration network
  service-operator payments status --network calibration

  # Check status with explicit addresses
  service-operator payments status \
    --rpc-url https://api.calibration.node.glif.io/rpc/v1 \
    --payments-address 0x6dB198201F900c17e86D267d7Df82567FB03df5E \
    --token-address 0xb3042734b608a1B16e9e86B374A3f3e389B4cDf0 \
    --contract-address 0x8b7aa0a68f5717e400F1C4D37F7a28f84f76dF91 \
    --private-key ./wallet-key.hex`,
	RunE: runStatus,
}

func runStatus(cobraCmd *cobra.Command, args []string) error {
	ctx := cobraCmd.Context()

	cfg, err := config.Load()
	if err != nil {
		return err
	}

	client, err := ethclient.Dial(cfg.RPCUrl)
	if err != nil {
		return fmt.Errorf("connecting to RPC endpoint: %w", err)
	}
	defer client.Close()

	// Create signer manager and load payer's private key to get address
	signerManager := contract.NewSignerManager(cfg)
	privateKey, err := signerManager.LoadPayerSigner()
	if err != nil {
		return fmt.Errorf("loading payer signer: %w", err)
	}

	contractOwnerAddr := crypto.PubkeyToAddress(privateKey.PublicKey)

	// Query ServiceProviderRegistry to get all registered providers
	registry, err := bindings.NewServiceProviderRegistry(cfg.ServiceRegistryAddr(), client)
	if err != nil {
		return fmt.Errorf("creating registry binding: %w", err)
	}

	// Get all active providers with a large limit to get all of them
	providersResult, err := registry.GetAllActiveProviders(nil, big.NewInt(0), big.NewInt(1000))
	if err != nil {
		return fmt.Errorf("querying active providers: %w", err)
	}

	// Get full provider details
	type ProviderDetail struct {
		Name       string
		ProviderId *big.Int
	}
	var storageNodePayees []common.Address
	providerDetails := make(map[common.Address]*ProviderDetail)

	if len(providersResult.ProviderIds) > 0 {
		providersInfo, err := registry.GetProvidersByIds(nil, providersResult.ProviderIds)
		if err != nil {
			return fmt.Errorf("getting provider details: %w", err)
		}

		for i, providerView := range providersInfo.ProviderInfos {
			if !providersInfo.ValidIds[i] || !providerView.Info.IsActive {
				continue
			}
			payeeAddr := providerView.Info.Payee
			storageNodePayees = append(storageNodePayees, payeeAddr)
			providerDetails[payeeAddr] = &ProviderDetail{
				Name:       providerView.Info.Name,
				ProviderId: providerView.ProviderId,
			}
		}
	}

	// Query token decimals
	decimals, err := GetTokenDecimals(ctx, client, cfg.TokenAddr())
	if err != nil {
		return fmt.Errorf("querying token decimals: %w", err)
	}

	paymentsContract, err := bindings.NewPayments(cfg.PaymentsAddr(), client)
	if err != nil {
		return fmt.Errorf("creating payments contract binding: %w", err)
	}

	// Query account information
	accountInfo, err := paymentsContract.Accounts(nil, cfg.TokenAddr(), contractOwnerAddr)
	if err != nil {
		return fmt.Errorf("querying account information: %w", err)
	}

	// Query operator approval information
	operatorInfo, err := paymentsContract.OperatorApprovals(nil, cfg.TokenAddr(), contractOwnerAddr, cfg.ServiceAddr())
	if err != nil {
		return fmt.Errorf("querying operator approval: %w", err)
	}

	// Display results
	fmt.Println("Payments Account Status")
	fmt.Println("=======================")
	fmt.Println()
	fmt.Println("Configuration:")
	fmt.Printf("  Payments contract:      %s\n", cfg.PaymentsContractAddress)
	fmt.Printf("  Token contract:         %s\n", cfg.TokenContractAddress)
	fmt.Printf("  Service contract:       %s\n", cfg.ServiceContractAddress)
	fmt.Printf("  Contract owner:         %s\n", contractOwnerAddr.Hex())
	fmt.Printf("  Registered storage nodes: %d\n", len(storageNodePayees))
	fmt.Printf("  RPC URL:                %s\n", cfg.RPCUrl)
	fmt.Println()

	fmt.Println("Account Balance:")
	fmt.Printf("  Total funds:            %s (%s)\n",
		accountInfo.Funds.String(),
		payments.FormatTokenAmount(accountInfo.Funds, decimals))
	fmt.Printf("  Locked funds:           %s (%s)\n",
		accountInfo.LockupCurrent.String(),
		payments.FormatTokenAmount(accountInfo.LockupCurrent, decimals))

	// Calculate available funds
	availableFunds := new(big.Int).Sub(accountInfo.Funds, accountInfo.LockupCurrent)
	fmt.Printf("  Available funds:        %s (%s)\n",
		availableFunds.String(),
		payments.FormatTokenAmount(availableFunds, decimals))
	fmt.Println()

	fmt.Println("Operator Approval Status:")
	if !operatorInfo.IsApproved {
		fmt.Println("  Status:                 ❌ Not approved")
		fmt.Println()
		fmt.Println("Next steps:")
		fmt.Println("  1. Calculate allowances: service-operator payments calculate --size <dataset-size>")
		fmt.Println("  2. Approve operator: service-operator payments approve-service \\")
		fmt.Println("       --rate-allowance <value> \\")
		fmt.Println("       --lockup-allowance <value> \\")
		fmt.Println("       --max-lockup-period <value>")
	} else {
		fmt.Println("  Status:                 ✓ Approved")
		fmt.Println()
		fmt.Println("  Rate Allowance:")
		fmt.Printf("    Total allowance:      %s/epoch (%s/epoch)\n",
			operatorInfo.RateAllowance.String(),
			payments.FormatTokenAmount(operatorInfo.RateAllowance, decimals))
		fmt.Printf("    Currently used:       %s/epoch (%s/epoch)\n",
			operatorInfo.RateUsage.String(),
			payments.FormatTokenAmount(operatorInfo.RateUsage, decimals))
		rateAvailable := new(big.Int).Sub(operatorInfo.RateAllowance, operatorInfo.RateUsage)
		fmt.Printf("    Available:            %s/epoch (%s/epoch)\n",
			rateAvailable.String(),
			payments.FormatTokenAmount(rateAvailable, decimals))
		fmt.Println()

		fmt.Println("  Lockup Allowance:")
		fmt.Printf("    Total allowance:      %s (%s)\n",
			operatorInfo.LockupAllowance.String(),
			payments.FormatTokenAmount(operatorInfo.LockupAllowance, decimals))
		fmt.Printf("    Currently used:       %s (%s)\n",
			operatorInfo.LockupUsage.String(),
			payments.FormatTokenAmount(operatorInfo.LockupUsage, decimals))
		lockupAvailable := new(big.Int).Sub(operatorInfo.LockupAllowance, operatorInfo.LockupUsage)
		fmt.Printf("    Available:            %s (%s)\n",
			lockupAvailable.String(),
			payments.FormatTokenAmount(lockupAvailable, decimals))
		fmt.Println()

		fmt.Printf("  Max Lockup Period:      %s epochs (%d days)\n",
			operatorInfo.MaxLockupPeriod.String(),
			operatorInfo.MaxLockupPeriod.Int64()/2880)
	}

	// Query active payment rails across all storage nodes
	fmt.Println()
	fmt.Println("Active Payment Rails:")

	if len(storageNodePayees) == 0 {
		fmt.Println("  No storage nodes registered.")
		fmt.Println()
		fmt.Println("  Register storage providers using: service-operator provider register")
	} else {
		// Aggregate rails from all storage nodes
		type RailWithProvider struct {
			RailInfo *contract.RailInfo
			Provider *ProviderDetail
		}

		var allRails []RailWithProvider
		activeCount := 0
		terminatedCount := 0

		for _, payeeAddr := range storageNodePayees {
			railSummaries, err := contract.QueryRailsForPayee(ctx, cfg.RPCUrl, cfg.PaymentsAddr(), payeeAddr, cfg.TokenAddr())
			if err != nil {
				fmt.Printf("  Warning: Error querying rails for payee %s: %v\n", payeeAddr.Hex(), err)
				continue
			}

			for _, summary := range railSummaries {
				railInfo, err := contract.QueryRailInfo(ctx, cfg.RPCUrl, cfg.PaymentsAddr(), summary.RailId)
				if err != nil {
					fmt.Printf("  Warning: Error querying rail %s: %v\n", summary.RailId.String(), err)
					continue
				}

				allRails = append(allRails, RailWithProvider{
					RailInfo: railInfo,
					Provider: providerDetails[payeeAddr],
				})

				if railInfo.IsTerminated {
					terminatedCount++
				} else {
					activeCount++
				}
			}
		}

		if len(allRails) == 0 {
			fmt.Println("  No active payment rails found.")
			fmt.Println()
			fmt.Println("  Payment rails are created when clients start using your storage service.")
		} else {
			fmt.Printf("  Total rails: %d (Active: %d, Terminated: %d)\n", len(allRails), activeCount, terminatedCount)
			fmt.Println()

			for i, rail := range allRails {
				status := "Active"
				if rail.RailInfo.IsTerminated {
					status = "Terminated"
				}

				fmt.Printf("  Rail #%d:\n", i+1)
				fmt.Printf("    Rail ID:              %s\n", rail.RailInfo.RailID.String())
				fmt.Printf("    Status:               %s\n", status)
				fmt.Printf("    Storage node:         %s\n", rail.RailInfo.To.Hex())
				if rail.Provider != nil {
					fmt.Printf("    Provider name:        %s\n", rail.Provider.Name)
					fmt.Printf("    Provider ID:          %s\n", rail.Provider.ProviderId.String())
				}
				fmt.Printf("    Payer:                %s\n", rail.RailInfo.From.Hex())
				fmt.Printf("    Payment rate:         %s/epoch (%s/epoch)\n",
					rail.RailInfo.PaymentRate.String(),
					payments.FormatTokenAmount(rail.RailInfo.PaymentRate, decimals))
				fmt.Printf("    Settled up to:        epoch %s\n", rail.RailInfo.SettledUpTo.String())
				if rail.RailInfo.IsTerminated {
					fmt.Printf("    Terminated at:        epoch %s\n", rail.RailInfo.EndEpoch.String())
				}
				fmt.Println()
			}

			if activeCount > 0 {
				fmt.Println("  To settle a rail:")
				fmt.Println("    service-operator payments settle --rail-id <Rail ID>")
				fmt.Println("  To settle all active rails:")
				fmt.Println("    service-operator payments settle --all")
			}
		}
	}

	return nil
}
