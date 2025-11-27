#!/bin/bash
set -e

# Parse command line arguments
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    cat << 'EOF'
Usage: ./uftp_upload_with_verify.sh [config_file.yaml]

Upload files TO DKRZ Levante with automatic MD5 verification and remote directory creation.
Failed uploads and checksum mismatches are automatically retried up to 3 times.

Arguments:
  config_file.yaml   Path to YAML config file (default: transfer_config.yaml)

Examples:
  ./uftp_upload_with_verify.sh                           # Use default config
  ./uftp_upload_with_verify.sh my_uploads.yaml           # Use custom config
  ./uftp_upload_with_verify.sh configs/upload_001.yaml   # Use config in subdir

Config file format: See upload_config.yaml

Features:
  - Automatic retry (3 attempts) on upload failure or checksum mismatch
  - MD5 verification after each upload
  - Automatic remote directory creation
  - Progress display with transfer speed

EOF
    exit 0
fi

CONFIG_FILE="${1:-upload_config.yaml}"  # YAML config file (default or from argument)

# Configuration
UFTP_AUTH_SERVER="https://uftp.dkrz.de:9000/rest/auth/HPCDATA:"

# UFTP performance options
THREADS=4          # Number of parallel FTP connections (-t)
STREAMS=8          # Number of TCP streams per connection (-n)
MAX_RETRIES=3      # Number of retry attempts for failed uploads/verifications

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== UFTP Upload Script with Verification ===${NC}"
echo "Config file: ${CONFIG_FILE}"
echo "FTP Connections: ${THREADS}, TCP Streams: ${STREAMS}, Max Retries: ${MAX_RETRIES}"
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
UFTP_USER=b382608
UFTP_KEY=$HOME/.uftp/levante_transfer
export PATH=/home/daewon/uftp-client-1.5.0/bin/:$PATH

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
which uftp
# Parse YAML and execute transfers with Python
python3 << 'PYTHON_SCRIPT'
import yaml
import subprocess
import sys
import os
import hashlib
from pathlib import Path

def compute_md5(filepath):
    """Compute MD5 checksum of a file"""
    md5 = hashlib.md5()
    with open(filepath, 'rb') as f:
        for chunk in iter(lambda: f.read(8192), b''):
            md5.update(chunk)
    return md5.hexdigest()

def get_remote_checksum(uftp_url, user, key):
    """Get checksum from remote server using UFTP"""
    cmd = [
        'uftp', 'checksum',
        '-u', user,
        '-i', key,
        '-a', 'MD5',
        uftp_url
    ]
    try:
        result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, check=True)
        # Parse output: "MD5 checksum: <hash>"
        for line in result.stdout.strip().split('\n'):
            if 'MD5' in line or len(line) == 32:
                # Extract just the hash
                parts = line.split()
                for part in parts:
                    if len(part) == 32 and all(c in '0123456789abcdef' for c in part.lower()):
                        return part.lower()
        return None
    except subprocess.CalledProcessError:
        return None

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
verified = 0
verification_failed = 0

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
        
        # Get local checksum before upload
        print(f"    Computing local checksum...")
        local_md5 = compute_md5(local_full)
        print(f"    Local MD5:  {local_md5}")
        
        # Try upload with retries
        upload_success = False
        verify_success = False
        
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
            
            # Verify checksum after upload
            print(f"    Verifying upload...")
            remote_md5 = get_remote_checksum(remote_url, uftp_user, uftp_key)
            
            if not remote_md5:
                print(f"    \033[1;33m⚠ Could not get remote checksum (skipping verification)\033[0m")
                upload_success = True
                successful += 1
                break
            
            print(f"    Remote MD5: {remote_md5}")
            
            if local_md5 == remote_md5:
                print(f"    \033[0;32m✓ Checksum verified\033[0m")
                upload_success = True
                verify_success = True
                successful += 1
                verified += 1
                break
            else:
                print(f"    \033[0;31m✗ Checksum mismatch! (attempt {attempt}/{max_retries})\033[0m")
                if attempt < max_retries:
                    print(f"    Re-uploading file...")
                else:
                    verification_failed += 1
                    successful += 1  # File was uploaded, just verification failed

# Final summary
print(f"\n\033[0;32m=== Upload Summary ===\033[0m")
print(f"Total files:         {total_files}")
print(f"Successfully uploaded: {successful}")
print(f"Failed uploads:      {failed}")
print(f"Verified checksums:  {verified}")
print(f"Verification failed: {verification_failed}")

if failed > 0 or verification_failed > 0:
    print(f"\n\033[0;31mSome uploads or verifications failed!\033[0m")
    sys.exit(1)
else:
    print(f"\n\033[0;32m✓ All uploads completed and verified successfully!\033[0m")

PYTHON_SCRIPT

exit_code=$?

if [ $exit_code -eq 0 ]; then
    echo -e "${GREEN}Done!${NC}"
else
    echo -e "${RED}Transfer script failed with errors${NC}"
    exit $exit_code
fi

