#!/bin/bash
# Generate UFTP transfer config for dunkelflaute solar radiation files
# Usage: ./generate_dunkelflaute_transfer.sh <scenario> <start_year> <end_year> <source> [variable]
# Example: ./generate_dunkelflaute_transfer.sh 1950C 1950 1969 aleph tsr
# Example: ./generate_dunkelflaute_transfer.sh 2080C 2080 2090 olaf ssrd
# Example: ./generate_dunkelflaute_transfer.sh 2080C 2091 2092 aleph tsr

SCENARIO=${1:-1950C}
START_YEAR=${2:-1950}
END_YEAR=${3:-1969}
SOURCE=${4:-aleph}  # aleph or olaf
VAR=${5:-tsr}       # tsr or ssrd

# Set paths based on source
if [ "$SOURCE" == "aleph" ]; then
    LOCAL_BASE="/scratch/awicm3/TCo1279-DART-${SCENARIO}/outdata/oifs"
elif [ "$SOURCE" == "olaf" ]; then
    # OLAF archive path - adjust as needed
    LOCAL_BASE="/arch/bm1344/awicm3/TCo1279-DART-${SCENARIO}/outdata/oifs"
else
    echo "Unknown source: $SOURCE (use 'aleph' or 'olaf')"
    exit 1
fi

REMOTE_DIR="/work/ab0995/ICCP_AWI_hackthon_2025/TCo1279-DART-${SCENARIO}/outdata/oifs"
OUTPUT_FILE="transfer_dunkelflaute_${VAR}_${SCENARIO}_${START_YEAR}_${END_YEAR}_${SOURCE}.yaml"

cat > "$OUTPUT_FILE" << EOF
# UFTP Transfer Configuration for Dunkelflaute Analysis
# Transfer ${VAR} (solar radiation) files for TCo1279-DART-${SCENARIO}
# Source: ${SOURCE^} ${LOCAL_BASE}
# Destination: Levante ${REMOTE_DIR}
# Years: ${START_YEAR}-${END_YEAR}
# Variable: ${VAR}
# Generated: $(date)

transfers:
  - name: "TCo1279-DART-${SCENARIO} ${VAR} ${START_YEAR}-${END_YEAR} from ${SOURCE}"
    local_base: "${LOCAL_BASE}"
    remote_dir: "${REMOTE_DIR}"
    files:
EOF

# Generate file list
for year in $(seq $START_YEAR $END_YEAR); do
    echo "      # ${year}" >> "$OUTPUT_FILE"
    for month in $(seq -w 1 12); do
        echo "      - \"atm_reduced_3h_${VAR}_3h_${year}${month}-${year}${month}.nc\"" >> "$OUTPUT_FILE"
    done
done

echo "Generated: $OUTPUT_FILE"
echo "Variable: ${VAR}"
echo "Files: $((($END_YEAR - $START_YEAR + 1) * 12)) monthly files"
echo ""
echo "To transfer, run on ${SOURCE^}:"
if [ "$SOURCE" == "aleph" ]; then
    echo "  ./transfer.sh configs/$OUTPUT_FILE"
else
    echo "  ./transfer_olaf.sh configs/$OUTPUT_FILE"
fi
