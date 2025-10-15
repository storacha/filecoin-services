package payments

import (
	"context"
	"fmt"
	"math/big"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/spf13/cobra"
	"github.com/storacha/filecoin-services/service-operator/internal/config"
	"github.com/storacha/filecoin-services/service-operator/internal/contract"
	"github.com/storacha/filecoin-services/service-operator/internal/payments"
)

var (
	convertAmount        string
	convertOutputFormat  string
	convertTokenDecimals int
)

var convertCmd = &cobra.Command{
	Use:   "convert",
	Short: "Convert dollar amounts to base token units for deposit",
	Long: `Convert a dollar amount to the base token units required for the deposit command.

This command queries the token contract for its decimals (or uses a manual override)
and converts the dollar amount to base units that can be passed to the deposit command.

For tokens with 18 decimals (standard ERC20):
  $1.00 = 1,000,000,000,000,000,000 base units

For tokens with 6 decimals (like USDC):
  $1.00 = 1,000,000 base units

Examples:
  # Convert $10 to base units
  service-operator payments convert --amount 10

  # Convert $10.50 using explicit decimals
  service-operator payments convert --amount 10.50 --token-decimals 18

  # Output in shell format for scripting
  service-operator payments convert --amount 10 --format shell

  # Get just the number for direct copy-paste
  service-operator payments convert --amount 10 --format direct`,
	RunE: runConvert,
}

func init() {
	convertCmd.Flags().StringVar(&convertAmount, "amount", "", "Dollar amount to convert (e.g., 10, $10, 10.50) (required)")
	convertCmd.Flags().StringVar(&convertOutputFormat, "format", "human", "Output format: human, shell, or direct")
	convertCmd.Flags().IntVar(&convertTokenDecimals, "token-decimals", -1, "Token decimals (optional, overrides contract query)")

	cobra.MarkFlagRequired(convertCmd.Flags(), "amount")
}

func runConvert(cobraCmd *cobra.Command, args []string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Parse dollar amount
	dollars, err := payments.ParseDollarAmount(convertAmount)
	if err != nil {
		return err
	}

	// Load configuration
	cfg, err := config.Load()
	if err != nil {
		return err
	}

	// Determine token decimals
	var tokenDecimals uint8
	var decimalsSource string

	if convertTokenDecimals >= 0 {
		// Manual override
		tokenDecimals = uint8(convertTokenDecimals)
		decimalsSource = "manual override"
	} else {
		// Query from contract
		if cfg.RPCUrl == "" {
			return fmt.Errorf("--rpc-url is required (or provide --token-decimals)")
		}

		// Determine token address
		var tokenAddr common.Address
		if cfg.TokenContractAddress != "" {
			tokenAddr = common.HexToAddress(cfg.TokenContractAddress)
			decimalsSource = fmt.Sprintf("queried from token at %s", tokenAddr.Hex())
		} else if cfg.ServiceContractAddress != "" {
			// Query service contract for token address
			fmt.Printf("Querying service contract for token address...\n")
			pricing, err := contract.QueryServicePrice(ctx, cfg.RPCUrl, common.HexToAddress(cfg.ServiceContractAddress))
			if err != nil {
				return fmt.Errorf("querying service price: %w", err)
			}
			tokenAddr = pricing.TokenAddress
			decimalsSource = fmt.Sprintf("queried from token at %s (via service contract)", tokenAddr.Hex())
		} else {
			return fmt.Errorf("either --token-contract-address or --service-contract-address is required (or provide --token-decimals)")
		}

		// Query token decimals
		decimals, err := contract.QueryTokenDecimals(ctx, cfg.RPCUrl, tokenAddr)
		if err != nil {
			return fmt.Errorf("querying token decimals: %w", err)
		}
		tokenDecimals = decimals
	}

	// Convert dollars to base units
	baseUnits, err := payments.DollarToBaseUnits(dollars, tokenDecimals)
	if err != nil {
		return fmt.Errorf("converting to base units: %w", err)
	}

	// Output based on format
	switch convertOutputFormat {
	case "human":
		printHumanConvertFormat(dollars, baseUnits, tokenDecimals, decimalsSource)
	case "shell":
		printShellConvertFormat(baseUnits)
	case "direct":
		printDirectConvertFormat(baseUnits)
	default:
		return fmt.Errorf("unknown format: %s (supported: human, shell, direct)", convertOutputFormat)
	}

	return nil
}

func printHumanConvertFormat(dollars float64, baseUnits *big.Int, decimals uint8, source string) {
	fmt.Println("Dollar to Base Units Conversion")
	fmt.Println("================================")
	fmt.Println()
	fmt.Printf("Input:              $%.2f\n", dollars)
	fmt.Printf("Token decimals:     %d (%s)\n", decimals, source)
	fmt.Printf("Base units:         %s\n", baseUnits.String())
	fmt.Println()
	fmt.Println("Usage with deposit:")
	fmt.Println("  Copy this exact value to the deposit command:")
	fmt.Println()
	fmt.Printf("  service-operator payments deposit --amount %s\n", baseUnits.String())
	fmt.Println()
	fmt.Println("Verification:")
	fmt.Printf("  %s base units = %s\n", baseUnits.String(), payments.FormatTokenAmount(baseUnits, decimals))
}

func printShellConvertFormat(baseUnits *big.Int) {
	fmt.Printf("BASE_UNITS=%s\n", baseUnits.String())
}

func printDirectConvertFormat(baseUnits *big.Int) {
	fmt.Println(baseUnits.String())
}