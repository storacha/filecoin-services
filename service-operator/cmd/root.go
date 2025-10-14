package cmd

import (
	"context"
	"errors"
	"os"
	"strings"

	"github.com/spf13/cobra"
	"github.com/spf13/viper"

	"github.com/storacha/filecoin-services/service-operator/cmd/payments"
	"github.com/storacha/filecoin-services/service-operator/cmd/provider"
)

var cfgFile string

var rootCmd = &cobra.Command{
	Use:   "service-operator",
	Short: "Service operator CLI for managing FilecoinWarmStorageService contracts",
	Long: `service-operator is a CLI tool for managing FilecoinWarmStorageService smart contracts.
It provides commands to approve/remove providers, configure service settings, and more.`,
}

func init() {
	cobra.OnInitialize(initConfig)

	rootCmd.PersistentFlags().StringVar(&cfgFile, "config", "", "config file (default is ./service-operator.yaml)")

	rootCmd.PersistentFlags().String("rpc-url", "", "Ethereum RPC endpoint URL (required)")
	rootCmd.PersistentFlags().String("service-contract-address", "", "FilecoinWarmStorageService contract address (required)")
	rootCmd.PersistentFlags().String("verifier-contract-address", "", "PDPVerifier contract address (required)")
	rootCmd.PersistentFlags().String("service-registry-contract-address", "", "ServiceProviderRegistry contract address (required)")
	rootCmd.PersistentFlags().String("payments-contract-address", "", "Payments contract address (required)")
	rootCmd.PersistentFlags().String("token-contract-address", "", "USDFC token contract address (required)")

	// Note: Authentication is now configured per-role in the config file (signers.owner and signers.payer)
	// Optional flag to select which signer to use (for debugging/override purposes)
	rootCmd.PersistentFlags().String("signer", "", "Override signer to use: 'owner' or 'payer' (optional)")

	cobra.CheckErr(viper.BindPFlag("rpc_url", rootCmd.PersistentFlags().Lookup("rpc-url")))
	cobra.CheckErr(viper.BindPFlag("service_contract_address", rootCmd.PersistentFlags().Lookup("service-contract-address")))
	cobra.CheckErr(viper.BindPFlag("verifier_contract_address", rootCmd.PersistentFlags().Lookup("verifier-contract-address")))
	cobra.CheckErr(viper.BindPFlag("service_registry_contract_address", rootCmd.PersistentFlags().Lookup("service-registry-contract-address")))
	cobra.CheckErr(viper.BindPFlag("payments_contract_address", rootCmd.PersistentFlags().Lookup("payments-contract-address")))
	cobra.CheckErr(viper.BindPFlag("token_contract_address", rootCmd.PersistentFlags().Lookup("token-contract-address")))
	cobra.CheckErr(viper.BindPFlag("signer_override", rootCmd.PersistentFlags().Lookup("signer")))

	rootCmd.AddCommand(provider.Cmd)
	rootCmd.AddCommand(payments.Cmd)
}

func initConfig() {
	if cfgFile != "" {
		viper.SetConfigFile(cfgFile)
	} else {
		viper.SetConfigName("service-operator")
		viper.SetConfigType("yaml")
		viper.AddConfigPath(".")
	}

	viper.SetEnvPrefix("SERVICE_OPERATOR")
	viper.SetEnvKeyReplacer(strings.NewReplacer("-", "_"))
	viper.AutomaticEnv()

	// Don't error if config file is not found
	if err := viper.ReadInConfig(); err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			cobra.CheckErr(err)
		}
	}
}

func Execute(ctx context.Context) error {
	return rootCmd.ExecuteContext(ctx)
}
