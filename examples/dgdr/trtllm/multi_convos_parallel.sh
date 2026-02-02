#!/usr/bin/env bash
set -euo pipefail

API_URL="${API_URL:-http://localhost:8000/v1/chat/completions}"
MODEL="${MODEL:-Qwen/Qwen3-0.6B}"
TEMPERATURE="${TEMPERATURE:-0.7}"
MAX_TOKENS="${MAX_TOKENS:-200}"

# Total conversations and max parallel workers
NUM_CONVOS="${NUM_CONVOS:-10}"
CONCURRENCY="${CONCURRENCY:-5}"

# Ensure dependencies exist
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required."; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required."; exit 1; }

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

# ---- API call: takes messages JSON array on stdin, prints assistant content ----
chat_once() {
  local messages_json
  messages_json="$(cat)"

  local payload
  payload="$(jq -n \
    --arg model "$MODEL" \
    --argjson messages "$messages_json" \
    --argjson temperature "$TEMPERATURE" \
    --argjson max_tokens "$MAX_TOKENS" \
    '{
      model: $model,
      messages: $messages,
      temperature: $temperature,
      max_tokens: $max_tokens
    }'
  )"

  local resp
  resp="$(curl -sS "$API_URL" -H "Content-Type: application/json" -d "$payload")"

  # If your server returns errors differently, adjust this check:
  if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
    echo "API error: $(echo "$resp" | jq -r '.error.message // .error')" >&2
    return 1
  fi

  echo "$resp" | jq -r '.choices[0].message.content'
}

append_user() {
  local file="$1"
  local content="$2"
  jq --arg c "$content" '. + [{"role":"user","content":$c}]' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

append_assistant() {
  local file="$1"
  local content="$2"
  jq --arg c "$content" '. + [{"role":"assistant","content":$c}]' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

init_convo() {
  local cid="$1"
  local file="$tmpdir/conv_${cid}.json"

  # Customize the initial prompt per conversation if you want
  local user_prompt="Conversation $cid: Give me a short fun fact about Denmark."

  jq -n --arg up "$user_prompt" '
    [
      {"role":"system","content":"You are a helpful assistant."},
      {"role":"user","content":$up}
    ]
  ' > "$file"

  echo "$file"
}

run_convo() {
  local cid="$1"
  local file="$2"
  local out="$tmpdir/conv_${cid}.txt"

  {
    # Turn 1
    a1="$(cat "$file" | chat_once)"
    append_assistant "$file" "$a1"

    # Turn 2
    append_user "$file" "Now explain that fun fact in 2 sentences."
    a2="$(cat "$file" | chat_once)"
    append_assistant "$file" "$a2"

    # Turn 3
    append_user "$file" "Thanks! End with a one-line summary."
    a3="$(cat "$file" | chat_once)"
    append_assistant "$file" "$a3"

    # Write transcript to a text file (one per conversation)
    echo "=============================="
    echo " Transcript: Conversation $cid"
    echo "=============================="
    jq -r '.[] | "\(.role | ascii_upcase): \(.content)\n"' "$file"
  } > "$out" 2>&1
}

# ---- Semaphore (token bucket) using FIFO ----
sem_init() {
  local n="$1"
  SEM_FIFO="$(mktemp -u)"
  mkfifo "$SEM_FIFO"
  # open FIFO for read/write on fd 9 and remove name (fd persists)
  exec 9<>"$SEM_FIFO"
  rm -f "$SEM_FIFO"

  # seed tokens
  for _ in $(seq 1 "$n"); do
    printf '.' >&9
  done
}

sem_acquire() { read -r -n 1 _ <&9; }
sem_release() { printf '.' >&9; }

echo "API_URL=$API_URL"
echo "MODEL=$MODEL"
echo "NUM_CONVOS=$NUM_CONVOS"
echo "CONCURRENCY=$CONCURRENCY"
echo "Temp dir: $tmpdir"
echo

# Initialize semaphore and conversations
sem_init "$CONCURRENCY"

declare -a convo_files
for cid in $(seq 1 "$NUM_CONVOS"); do
  convo_files[$cid]="$(init_convo "$cid")"
done

# Launch conversations in parallel (bounded by semaphore)
pids=()
for cid in $(seq 1 "$NUM_CONVOS"); do
  sem_acquire
  (
    set +e
    run_convo "$cid" "${convo_files[$cid]}"
    status=$?
    sem_release
    exit "$status"
  ) &
  pids+=("$!")
done

# Wait for all, track failures
fail=0
for pid in "${pids[@]}"; do
  if ! wait "$pid"; then
    fail=1
  fi
done

# Print transcripts in order
for cid in $(seq 1 "$NUM_CONVOS"); do
  echo
  cat "$tmpdir/conv_${cid}.txt" || true
done

echo
if [[ "$fail" -ne 0 ]]; then
  echo "Done (with some failures). See logs above."
  exit 1
else
  echo "Done."
fi
