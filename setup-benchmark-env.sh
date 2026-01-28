#!/usr/bin/env bash
set -euo pipefail

# Install base Python tooling (Ubuntu/Debian)
# Install timg for visualization in terminal
if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get install -y python3-venv python3-pip timg
else
  echo "apt-get not found; please install python3-venv and python3-pip manually." >&2
  exit 1
fi

# Create and activate virtual environment
python3 -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate

# Install benchmark dependencies
DYNAMO_REPO_URL="${DYNAMO_REPO_URL:-https://github.com/NVIDIA/ai-dynamo.git}"

if [[ ! -d dynamo ]]; then
  if ! command -v git >/dev/null 2>&1; then
    echo "git is required to clone the Dynamo repo. Please install git." >&2
    exit 1
  fi
  echo "Cloning Dynamo repo into ./dynamo from ${DYNAMO_REPO_URL}"
  git clone "${DYNAMO_REPO_URL}" dynamo
  if [[ -n "${DYNAMO_REPO_REF:-}" ]]; then
    pushd dynamo >/dev/null
    git checkout "${DYNAMO_REPO_REF}"
    popd >/dev/null
  fi
fi

pushd dynamo >/dev/null
pip install -r deploy/utils/requirements.txt
python3 -m pip install aiperf
popd >/dev/null

echo "Benchmark environment setup complete."
echo
echo "To activate the environment in your current shell, run:"
echo "  source .venv/bin/activate"
echo
echo "To deactivate later, run:"
echo "  deactivate"
