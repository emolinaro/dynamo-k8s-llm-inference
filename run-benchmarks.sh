#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage: run-benchmarks.sh -u <api-url> -m <model> -o <output-dir> -b <benchmark-name>
  -u  API endpoint URL
  -m  Model name
  -o  Output directory (relative to ./dynamo or absolute)
  -b  Benchmark name
  -p  Generate plots after benchmark run
EOF
}

API_URL=""
MODEL=""
OUTPUT_DIR=""
BENCHMARK_NAME=""
GENERATE_PLOTS="false"

while getopts ":u:m:o:b:ph" opt; do
  case "${opt}" in
    u) API_URL="${OPTARG}" ;;
    m) MODEL="${OPTARG}" ;;
    o) OUTPUT_DIR="${OPTARG}" ;;
    b) BENCHMARK_NAME="${OPTARG}" ;;
    p) GENERATE_PLOTS="true" ;;
    h) usage; exit 0 ;;
    \?) echo "Unknown option: -${OPTARG}" >&2; usage; exit 1 ;;
    :) echo "Missing value for -${OPTARG}" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "${API_URL}" || -z "${MODEL}" || -z "${OUTPUT_DIR}" || -z "${BENCHMARK_NAME}" ]]; then
  echo "Missing required options." >&2
  usage
  exit 1
fi

if [[ ! -d .venv ]]; then
  echo "Expected ./.venv to exist. Run ./setup-benchmark-env.sh first." >&2
  exit 1
fi

# shellcheck disable=SC1091
source .venv/bin/activate

if [[ ! -d dynamo ]]; then
  echo "Expected ./dynamo directory to exist. Run ./setup-benchmark-env.sh first." >&2
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"
pushd dynamo >/dev/null

run_benchmark() {
  local name="$1"
  local endpoint="$2"
  local model="$3"
  local output_dir="$4"
  python3 -m benchmarks.utils.benchmark \
    --benchmark-name "${name}" \
    --endpoint-url "${endpoint}" \
    --model "${model}" \
    --output-dir "${output_dir}"
}

run_benchmark "${BENCHMARK_NAME}" "${API_URL}" "${MODEL}" "${OUTPUT_DIR}"

if [[ "${GENERATE_PLOTS}" == "true" ]]; then
  python3 -m benchmarks.utils.plot --data-dir "${OUTPUT_DIR}"
fi

popd >/dev/null
