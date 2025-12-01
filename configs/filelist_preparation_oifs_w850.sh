#!/bin/bash
#========================================================================================
# Generate transfer_config.yaml from OIFS file patterns - Customizable version
# Usage: ./generate_transfer_config_custom.sh [start_year] [end_year] [output_file]
#========================================================================================

# Parse command line arguments
START_YEAR=${1:-2080}
END_YEAR=${2:-2092}
OUTPUT_FILE=${3:-"transfer_config_TCo1279-DART-2080C_w850_AG.yaml"}

# Configuration ===========================================================================

# Case names (edit these for your case)
ICASE_NAME="TCo1279-DART-2080C"
CASE_NAME="TCo1279-DART-2080C"
FREQ="3h"

# Paths on Levante (source) and Aleph (destination)
REMOTE_BASE="/work/ab0995/ICCP_AWI_hackthon_2025/${CASE_NAME}/outdata/oifs"
LOCAL_BASE="/proj/shared_data/awicm3/${CASE_NAME}/outdata/oifs/3h/reduced_pl_w_850"

# Variables to process (edit this list as needed)
#    "2t" "10u" "10v" "lsp" "cp" "hcc" "mcc" "lcc" "tcc"
VARIABLES=(
    "w_850"
)

# Option: Specify only certain variables
# Uncomment and edit to transfer only specific variables:
# VARIABLES=("10u" "10v" "2t" "msl")

# Option: Specify specific months (default: all 12 months)
MONTHS=("01" "02" "03" "04" "05" "06" "07" "08" "09" "10" "11" "12")
# Or select specific months:
# MONTHS=("01" "06" "12")  # Only Jan, Jun, Dec

#========================================================================================
# Print usage
#========================================================================================

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    cat << EOF
Usage: $0 [start_year] [end_year] [output_file]

Generate transfer_config.yaml for OIFS atmospheric data files.
Files are checked for existence - only existing files are added to the config.

Arguments:
  start_year   Starting year (default: 2089)
  end_year     Ending year (default: 2089)
  output_file  Output YAML file (default: transfer_config_custom.yaml)

Examples:
  $0                        # Use defaults (2089-2089)
  $0 2089 2091              # Years 2089-2091
  $0 2089 2091 my_list.yaml # Custom output file

Edit the script to customize:
  - ICASE_NAME, CASE_NAME: Model case names
  - REMOTE_BASE, LOCAL_BASE: Source and destination paths
  - VARIABLES: List of variables to transfer
  - MONTHS: Months to include (default: all 12)
  - FREQ: Frequency (1m, 1d, etc.)

EOF
    exit 0
fi

#========================================================================================
# Generate YAML file
#========================================================================================

echo "=========================================="
echo "OIFS Transfer Config Generator"
echo "=========================================="
echo "Case:        ${CASE_NAME}"
echo "Frequency:   ${FREQ}"
echo "Years:       ${START_YEAR} to ${END_YEAR}"
echo "Variables:   ${#VARIABLES[@]}"
echo "Months:      ${#MONTHS[@]} per year"
echo "Output:      ${OUTPUT_FILE}"
echo ""

TOTAL_FILES=$((${#VARIABLES[@]} * (${END_YEAR} - ${START_YEAR} + 1) * ${#MONTHS[@]}))
echo "Expected files: ${TOTAL_FILES}"
echo ""
echo "Generating ${OUTPUT_FILE}..."
echo "Checking file existence..."
echo ""

# Write header
cat > "${OUTPUT_FILE}" << EOF
# UFTP Transfer Configuration
# Auto-generated for OIFS atmospheric data
#
# Case: ${CASE_NAME}
# Frequency: ${FREQ}
# Years: ${START_YEAR}-${END_YEAR}
# Generated: $(date)

transfers:
EOF

# Initialize file counters
TOTAL_FILES_CHECKED=0
TOTAL_FILES_FOUND=0
TOTAL_FILES_MISSING=0

# Loop through each variable
VAR_COUNT=0
for VAR in "${VARIABLES[@]}"; do

    ((VAR_COUNT++))
    echo "  [$VAR_COUNT/${#VARIABLES[@]}] Processing variable: ${VAR}"
    
    # Write transfer block header
    cat >> "${OUTPUT_FILE}" << EOF
  
  # Variable ${VAR_COUNT}/${#VARIABLES[@]}: ${VAR}
  - name: "OIFS ${FREQ} - ${VAR} (${START_YEAR}-${END_YEAR})"
    remote_base: "${REMOTE_BASE}"
    local_dir: "${LOCAL_BASE}/"
    files:
EOF
    
    VAR_FILES_FOUND=0
    VAR_FILES_MISSING=0
    
    # Loop through years and months to generate file list
    for ((YEAR=${START_YEAR}; YEAR<=${END_YEAR}; YEAR++)); do
        for MONTH in 01 02 03 04 05 06 07 08 09 10 11 12; do
            
            # Construct filename
            FILE="atm_reduced_${FREQ}_pl_${VAR}_${FREQ}_pl_${YEAR}${MONTH}-${YEAR}${MONTH}.nc"
            FULL_PATH="${LOCAL_BASE}/${FILE}"
            
            ((TOTAL_FILES_CHECKED++))
            
            # Check if file exists
            if [ -f "${FULL_PATH}" ]; then
                # Add to YAML only if file exists
                echo "      - \"${FILE}\"" >> "${OUTPUT_FILE}"
                ((VAR_FILES_FOUND++))
                ((TOTAL_FILES_FOUND++))
            else
                ((VAR_FILES_MISSING++))
                ((TOTAL_FILES_MISSING++))
                echo "  WARNING: Missing file: ${FULL_PATH}" >&2
            fi
            
        done
    done
    
    echo "  → Found: ${VAR_FILES_FOUND}, Missing: ${VAR_FILES_MISSING}"
    
done

# Write footer with summary
cat >> "${OUTPUT_FILE}" << EOF

# ============================================================================
# Transfer Summary
# ============================================================================
# Case:         ${CASE_NAME}
# Frequency:    ${FREQ}
# Years:        ${START_YEAR} to ${END_YEAR} ($((${END_YEAR} - ${START_YEAR} + 1)) years)
# Variables:    ${#VARIABLES[@]}
# Months/year:  ${#MONTHS[@]}
# Files checked: ${TOTAL_FILES_CHECKED}
# Files found:   ${TOTAL_FILES_FOUND} (included in config)
# Files missing: ${TOTAL_FILES_MISSING} (skipped)
#
# Source:       ${REMOTE_BASE}
# Destination:  ${LOCAL_BASE}
#
# ============================================================================
# To transfer these files:
# ============================================================================
# 1. Review this file
# 2. Edit uftp_transfer_with_verify.sh:
#    - Set CONFIG_FILE="${OUTPUT_FILE}"
#    - Set UFTP_USER and UFTP_KEY
# 3. Run: ./uftp_transfer_with_verify.sh
#
# Or manually specify config file:
#    sed -i 's/CONFIG_FILE=.*/CONFIG_FILE="${OUTPUT_FILE}"/' uftp_transfer_with_verify.sh
# ============================================================================
EOF

echo ""
echo "=========================================="
if [ ${TOTAL_FILES_MISSING} -eq 0 ]; then
    echo "✓ Configuration generated successfully!"
else
    echo "⚠ Configuration generated with warnings!"
fi
echo "=========================================="
echo ""
echo "Output file:    ${OUTPUT_FILE}"
echo "Files checked:  ${TOTAL_FILES_CHECKED}"
echo "Files found:    ${TOTAL_FILES_FOUND} (added to config)"
echo "Files missing:  ${TOTAL_FILES_MISSING} (skipped)"
echo ""
if [ ${TOTAL_FILES_MISSING} -gt 0 ]; then
    echo "⚠ WARNING: ${TOTAL_FILES_MISSING} files were not found and were skipped."
    echo "  Check the warnings above for details."
    echo ""
fi
echo "File size: $(wc -l < "${OUTPUT_FILE}") lines, $(du -h "${OUTPUT_FILE}" | cut -f1)"
echo ""
echo "Next steps:"
echo "  1. Review: cat ${OUTPUT_FILE}"
echo "  2. Edit uftp_transfer_with_verify.sh:"
echo "     CONFIG_FILE=\"${OUTPUT_FILE}\""
echo "  3. Transfer: ./uftp_transfer_with_verify.sh"
echo ""

