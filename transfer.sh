#!/usr/bin/bash
set -e

# Parse command line arguments
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    cat << 'EOF'
Usage: ./uftp_upload_with_verify.sh [config_file.yaml]

Upload files TO DKRZ Levante with automatic remote directory creation.
Failed uploads are automatically retried up to 3 times.

Arguments:
  config_file.yaml   Path to YAML config file (default: transfer_config.yaml)

Examples:
  ./uftp_upload_with_verify.sh                           # Use default config
  ./uftp_upload_with_verify.sh my_uploads.yaml           # Use custom config
  ./uftp_upload_with_verify.sh configs/upload_001.yaml   # Use config in subdir

Config file format: See upload_config.yaml

Features:
  - Automatic retry (3 attempts) on upload failure
  - Automatic remote directory creation
  - Progress display with transfer speed
  - Resume support: Successfully uploaded files are tracked and skipped on re-run

State File:
  Completed uploads are saved to .uftp_upload_state_<config>.json
  If interrupted, simply re-run the script - it will skip completed files.
  Delete the state file to force re-upload of all files.
  
Safety:
  If any upload fails, the last completed file is marked for re-upload
  (it may have been partially written and could be corrupted).

EOF
    exit 0
fi

CONFIG_FILE="${1:-upload_config.yaml}"  # YAML config file (default or from argument)

# Configuration
UFTP_AUTH_SERVER="https://uftp.dkrz.de:9000/rest/auth/HPCDATA:"

# UFTP performance options
THREADS=4          # Number of parallel FTP connections (-t)
STREAMS=8          # Number of TCP streams per connection (-n)
MAX_RETRIES=3      # Number of retry attempts for failed uploads

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== UFTP Upload Script ===${NC}"
echo "Config file: ${CONFIG_FILE}"
echo "FTP Connections: ${THREADS}, TCP Streams: ${STREAMS}, Max Retries: ${MAX_RETRIES}"
echo ""
echo -e "${BLUE}Resume support: Completed files are tracked and skipped on re-run${NC}"
echo ""

# Check if config file exists
if [ ! -f "${CONFIG_FILE}" ]; then
    echo -e "${RED}Error: Config file '${CONFIG_FILE}' not found${NC}"
    echo ""
    echo "Create a YAML config file with this format:"
    echo ""
    cat << 'EOF'
transfers:
  - name: "OIFS output"
    local_base: "/proj/shared_data/awicm3/TCo1279-DART-1950C/outdata/oifs"
    remote_dir: "/work/ab0246/from_aleph/TCo1279-DART-1950C/outdata/oifs"
    files:
      - "3h/2t/atm_reduced_3h_2t_3h_208901-208901.nc"
      - "3h/2t/atm_reduced_3h_2t_3h_208902-208902.nc"
EOF
    exit 1
fi

# Source environment
if [ -f "./loadmamba.sh" ]; then
    echo -e "${YELLOW}Loading micromamba environment${NC}"
    source loadmamba.sh
    micromamba activate uftp
else
    echo -e "${RED}Error: loadmamba.sh not found${NC}"
    exit 1
fi

# Set UFTP environment
UFTP_USER=a270092
UFTP_KEY=$HOME/.uftp/uftp_levante_2025-11
export PATH=/scratch/awiiccp2/uftp/uftp-client-1.5.0/bin/:$PATH

# Verify UFTP is available
if ! command -v uftp &> /dev/null; then
    echo -e "${RED}Error: uftp command not found${NC}"
    exit 1
fi

# Verify key file exists
if [ ! -f "${UFTP_KEY}" ]; then
    echo -e "${RED}Error: UFTP key file not found: ${UFTP_KEY}${NC}"
    exit 1
fi

echo -e "${YELLOW}Using key: ${UFTP_KEY}${NC}"
echo -e "${YELLOW}User: ${UFTP_USER}${NC}"
echo ""

# Export variables for Python script
export CONFIG_FILE
export UFTP_AUTH_SERVER
export UFTP_USER
export UFTP_KEY
export THREADS
export STREAMS
export MAX_RETRIES

# Parse YAML and execute transfers with Python
python3 << 'PYTHON_SCRIPT'
import yaml
import subprocess
import sys
import os
import json
from pathlib import Path
import datetime

def load_state_file(state_file):
    """Load completed uploads from state file"""
    if os.path.exists(state_file):
        try:
            with open(state_file, 'r') as f:
                return json.load(f)
        except:
            return {}
    return {}

def save_state_file(state_file, state):
    """Save completed uploads to state file"""
    with open(state_file, 'w') as f:
        json.dump(state, f, indent=2)

def mark_file_done(state, remote_path):
    """Mark a file as successfully uploaded"""
    state[remote_path] = {
        'completed_at': datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    }

def is_file_done(state, remote_path):
    """Check if file was already successfully uploaded"""
    return remote_path in state

def create_remote_dir(remote_path, uftp_auth_server, user, key):
    """Create remote directory and all parent directories using UFTP"""
    # Split path and create each level
    parts = remote_path.strip('/').split('/')
    current_path = ''
    
    for part in parts:
        current_path += '/' + part
        remote_url = f"{uftp_auth_server}{current_path}"
        
        cmd = [
            'uftp', 'mkdir',
            '-u', user,
            '-i', key,
            remote_url
        ]
        result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        # Ignore errors - directory might already exist
    
    # Verify directory exists using ls
    remote_url = f"{uftp_auth_server}{remote_path}"
    cmd = [
        'uftp', 'ls',
        '-u', user,
        '-i', key,
        remote_url
    ]
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    return result.returncode == 0

def transfer_file(local_path, remote_url, user, key, threads, streams):
    """Upload a single file using UFTP"""
    cmd = [
        'uftp', 'cp',
        '-u', user,
        '-i', key,
        '-t', str(threads),
        '-n', str(streams),
        '-v',
        local_path,
        remote_url
    ]
    
    # Suppress stderr (warnings) but show stdout (progress)
    result = subprocess.run(cmd, stderr=subprocess.DEVNULL)
    return result.returncode == 0, '', ''

# Read config
config_file = os.environ.get('CONFIG_FILE', 'upload_config.yaml')
uftp_auth_server = os.environ.get('UFTP_AUTH_SERVER')
uftp_user = os.environ.get('UFTP_USER')
uftp_key = os.environ.get('UFTP_KEY')
threads = int(os.environ.get('THREADS', '4'))
streams = int(os.environ.get('STREAMS', '8'))
max_retries = int(os.environ.get('MAX_RETRIES', '3'))

# State file for tracking completed uploads
config_basename = os.path.splitext(os.path.basename(config_file))[0]
state_file = f".uftp_upload_state_{config_basename}.json"
upload_state = load_state_file(state_file)

print(f"State file: {state_file}")
if os.path.exists(state_file):
    completed_count = len(upload_state)
    print(f"Found {completed_count} previously completed uploads")
print()

try:
    with open(config_file, 'r') as f:
        config = yaml.safe_load(f)
except Exception as e:
    print(f"\033[0;31mError reading config file: {e}\033[0m")
    sys.exit(1)

if 'transfers' not in config:
    print("\033[0;31mError: 'transfers' key not found in config file\033[0m")
    sys.exit(1)

# Statistics
total_files = 0
successful = 0
failed = 0
skipped = 0
last_completed_file = None

# Process each transfer block
for idx, transfer in enumerate(config['transfers'], 1):
    name = transfer.get('name', f'Transfer {idx}')
    
    # Support both naming conventions
    local_base = transfer.get('local_base', transfer.get('local_dir', ''))
    remote_base = transfer.get('remote_dir', transfer.get('remote_base', ''))
    files = transfer.get('files', [])
    
    print(f"\n\033[0;34m=== {name} ===\033[0m")
    print(f"Local source: {local_base}")
    print(f"Remote dest:  {remote_base}")
    print(f"Files to upload: {len(files)}")
    
    # Create remote base directory
    print(f"  Creating remote directory: {remote_base}")
    if create_remote_dir(remote_base, uftp_auth_server, uftp_user, uftp_key):
        print(f"  \033[0;32m✓\033[0m Remote directory ready")
    else:
        print(f"  \033[0;31m✗ Could not create/verify remote directory\033[0m")
        print(f"  Check permissions on: {remote_base}")
        continue  # Skip this transfer block
    
    # Track directories we've created to avoid redundant mkdir calls
    created_dirs = set()
    created_dirs.add(remote_base)
    
    # Transfer each file
    for file_path in files:
        total_files += 1
        local_full = os.path.join(local_base, file_path)
        remote_full = f"{remote_base}/{file_path}"
        remote_url = f"{uftp_auth_server}{remote_full}"
        
        print(f"\n  [{total_files}] {file_path}")
        
        # Check if local file exists
        if not os.path.exists(local_full):
            print(f"    \033[0;31m✗ Local file not found: {local_full}\033[0m")
            failed += 1
            continue
        
        # Create remote subdirectory if file is in a subdir
        remote_file_dir = os.path.dirname(remote_full)
        if remote_file_dir and remote_file_dir != remote_base and remote_file_dir not in created_dirs:
            if create_remote_dir(remote_file_dir, uftp_auth_server, uftp_user, uftp_key):
                created_dirs.add(remote_file_dir)
        
        # Check if already completed
        if is_file_done(upload_state, remote_full):
            print(f"    \033[0;36m⊙ Already uploaded (skipping)\033[0m")
            skipped += 1
            continue
        
        # Try upload with retries
        upload_success = False
        
        for attempt in range(1, max_retries + 1):
            if attempt > 1:
                print(f"    \033[1;33m↻ Retry attempt {attempt}/{max_retries}\033[0m")
            
            # Transfer (upload)
            success, stdout, stderr = transfer_file(
                local_full, remote_url, uftp_user, uftp_key, threads, streams
            )
            
            if not success:
                print(f"    \033[0;31m✗ Upload failed (attempt {attempt}/{max_retries})\033[0m")
                if attempt < max_retries:
                    print(f"    Retrying...")
                    continue
                else:
                    failed += 1
                    break
            
            print(f"    \033[0;32m✓\033[0m Uploaded")
            upload_success = True
            successful += 1
            # Mark as done in state
            mark_file_done(upload_state, remote_full)
            save_state_file(state_file, upload_state)
            last_completed_file = remote_full
            break

# Final summary
print(f"\n\033[0;32m=== Upload Summary ===\033[0m")
print(f"Total files:           {total_files}")
print(f"Skipped (already done): {skipped}")
print(f"Successfully uploaded:  {successful}")
print(f"Failed uploads:        {failed}")

if failed > 0:
    print(f"\n\033[0;31mSome uploads failed!\033[0m")
    
    # Remove last completed file from state - it may be corrupted
    if last_completed_file:
        print(f"\033[1;33m⚠ Removing last completed file from state (may be corrupted):\033[0m")
        print(f"  {os.path.basename(last_completed_file)}")
        if last_completed_file in upload_state:
            del upload_state[last_completed_file]
            save_state_file(state_file, upload_state)
    
    if successful > 0:
        print(f"\033[1;33mNote: {successful} files were successfully uploaded.\033[0m")
        print(f"\033[1;33mRe-run the script to retry failed uploads.\033[0m")
        print(f"\033[1;33mThe last completed file will be re-uploaded as a safety measure.\033[0m")
    sys.exit(1)
else:
    print(f"\n\033[0;32m✓ All uploads completed successfully!\033[0m")
    if skipped > 0:
        print(f"({skipped} files were already completed from previous runs)")

PYTHON_SCRIPT

exit_code=$?

if [ $exit_code -eq 0 ]; then
    echo -e "${GREEN}Done!${NC}"
else
    echo -e "${RED}Upload script failed with errors${NC}"
    exit $exit_code
fi

