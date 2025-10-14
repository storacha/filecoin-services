# Contract ABI Integration

## Overview

This package now uses contract ABIs directly from generated bindings, eliminating hardcoded ABI strings and preventing contract interface mismatches.

## How It Works

1. **ABI Initialization**: The contract ABI is parsed from `bindings.FilecoinWarmStorageServiceABI` at package initialization (`init()` function).

2. **Compile-Time Safety**: The package depends on the generated bindings, so if contracts change and bindings are regenerated, any breaking changes will be caught at compile time.

3. **Runtime Validation**: The `init()` function validates that required callback methods exist in the contract ABI. If they don't, the program panics at startup rather than failing at runtime.

4. **Direct ABI Usage**: Instead of hardcoded JSON strings, we use pre-parsed `abi.Arguments` with properly typed ABI types to encode data.

## Benefits

- **Zero Hardcoding**: No manual ABI strings to maintain
- **Automatic Updates**: When contracts change, bindings regenerate automatically
- **Early Failure**: Issues are caught at compile/test time, not runtime
- **Type Safety**: Using strongly-typed ABI arguments prevents encoding errors

## Testing

Run tests to verify ABI compatibility:
```bash
# Run all eip712 tests
go test ./eip712 -v

# Run specific ABI compatibility tests
make test-abi
```

## CI/CD Integration

The GitHub Actions workflow (`test-go.yml`) now includes an ABI compatibility check:
- Contracts are built
- Bindings are generated
- ABI compatibility is tested before other tests run
- Any mismatch will fail the build

## Preventing Future Issues

When contracts change:
1. The bindings will be regenerated (via `make generate`)
2. The `init()` function will validate the new ABI at startup
3. Tests will verify encoding/decoding compatibility
4. CI will catch any issues before merging

## Example Error That's Now Prevented

The original bug was caused by a missing `clientDataSetId` parameter in the `EncodeCreateDataSetExtraData` function. With this new approach:
- The contract expected: `(address, uint256, string[], string[], bytes)`
- Our old code sent: `(address, string[], string[], bytes)`

This type of mismatch is now impossible because:
1. The encoding structure comes directly from the contract ABI
2. Tests verify the encoding matches what the contract expects
3. Any parameter changes in the contract will immediately break compilation or tests