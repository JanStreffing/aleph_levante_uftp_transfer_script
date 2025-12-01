#!/bin/bash
#========================================================================================
# Check Transfer Status
# 
# Verify which files from a transfer config have been successfully uploaded to Levante.
# Run this script ON LEVANTE (the target/destination system).
#========================================================================================

# Parse command line arguments
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    cat << 'EOF'
Usage: ./check_transfer.sh [config_file.yaml]

Check which files from a transfer configuration exist on the target system.
This script should be run ON LEVANTE (the destination).

Arguments:
  config_file.yaml   Path to YAML config file (default: configs/transfer_config_custom.yaml)

Examples:
  ./check_transfer.sh                                    # Use default config
  ./check_transfer.sh configs/transfer_config_custom.yaml # Specify config
  
Output:
  - Summary of found/missing files per transfer block
  - List of missing files
  - Overall completion percentage

Options:
  -v, --verbose    Show all files (found and missing)
  -m, --missing    Show only missing files (default)
  -f, --found      Show only found files

EOF
    exit 0
fi

CONFIG_FILE="${1:-configs/transfer_config_custom.yaml}"

# Check if config file exists
if [ ! -f "${CONFIG_FILE}" ]; then
    echo "Error: Config file '${CONFIG_FILE}' not found"
    exit 1
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Transfer Status Checker ===${NC}"
echo "Config file: ${CONFIG_FILE}"
echo "Checking files on Levante..."
echo ""

# Export config file for Python
export CONFIG_FILE

# Parse YAML and check files with Python
python3 << 'PYTHON_SCRIPT'
import yaml
import sys
import os

# Read config
config_file = os.environ.get('CONFIG_FILE', 'configs/transfer_config_custom.yaml')

try:
    with open(config_file, 'r') as f:
        config = yaml.safe_load(f)
except Exception as e:
    print(f"\033[0;31mError reading config file: {e}\033[0m")
    sys.exit(1)

if 'transfers' not in config:
    print("\033[0;31mError: 'transfers' key not found in config file\033[0m")
    sys.exit(1)

# Global statistics
total_files = 0
total_found = 0
total_missing = 0
missing_files_list = []

# Process each transfer block
for idx, transfer in enumerate(config['transfers'], 1):
    name = transfer.get('name', f'Transfer {idx}')
    
    # Support both naming conventions
    remote_base = transfer.get('remote_dir', transfer.get('remote_base', ''))
    files = transfer.get('files', [])
    
    print(f"\n\033[0;34m=== {name} ===\033[0m")
    print(f"Target directory: {remote_base}")
    print(f"Files to check: {len(files)}")
    
    # Check each file
    found = 0
    missing = 0
    block_missing_files = []
    
    for file in files:
        total_files += 1
        
        # Construct full path
        full_path = os.path.join(remote_base, file)
        
        # Check if file exists
        if os.path.exists(full_path):
            found += 1
            total_found += 1
        else:
            missing += 1
            total_missing += 1
            block_missing_files.append(file)
            missing_files_list.append(full_path)
    
    # Print block summary
    completion = (found / len(files) * 100) if files else 0
    print(f"  Found:   {found}/{len(files)} ({completion:.1f}%)")
    print(f"  Missing: {missing}/{len(files)}")
    
    # Show missing files for this block
    if missing > 0 and missing <= 20:
        print(f"\n  \033[1;33mMissing files:\033[0m")
        for mf in block_missing_files:
            print(f"    - {mf}")
    elif missing > 20:
        print(f"\n  \033[1;33m{missing} files missing (too many to list)\033[0m")
        print(f"    First 10:")
        for mf in block_missing_files[:10]:
            print(f"    - {mf}")
        print(f"    ... and {missing - 10} more")

# Final summary
print(f"\n\033[0;32m=== Overall Summary ===\033[0m")
print(f"Total files checked: {total_files}")
print(f"Files found:         {total_found} ({total_found/total_files*100:.1f}%)" if total_files > 0 else "Files found: 0")
print(f"Files missing:       {total_missing} ({total_missing/total_files*100:.1f}%)" if total_files > 0 else "Files missing: 0")

if total_missing == 0:
    print(f"\n\033[0;32m✓ All files transferred successfully!\033[0m")
    sys.exit(0)
else:
    print(f"\n\033[1;33m⚠ {total_missing} files still need to be transferred.\033[0m")
    
    # Write missing files to a file
    missing_file_list = "missing_files.txt"
    with open(missing_file_list, 'w') as f:
        for mf in missing_files_list:
            f.write(f"{mf}\n")
    
    print(f"\nMissing files list saved to: {missing_file_list}")
    print(f"You can use this to retry the transfer or investigate further.")
    sys.exit(1)

PYTHON_SCRIPT

exit_code=$?

if [ $exit_code -eq 0 ]; then
    echo -e "${GREEN}Done!${NC}"
else
    echo -e "${YELLOW}Transfer incomplete - see details above${NC}"
fi

exit $exit_code
