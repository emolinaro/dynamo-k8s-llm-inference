#!/usr/bin/env bash
set -euo pipefail
API_URL="${API_URL:-http://127.0.0.1:8000/v1/chat/completions}"
MODEL="Qwen/Qwen3-0.6B"

# Usage: ./chat.sh [API_URL]
#
#  - This script starts an interactive chat with a vLLM/OpenAI-compatible chat/completions endpoint.
#  - By default, it connects to http://127.0.0.1:8000/v1/chat/completions.
#  - You can override the API endpoint in two ways:
#      1) Pass the API URL as the first argument:
#           ./chat.sh http://nodeip:port/v1/chat/completions
#      2) Or set the API_URL environment variable:
#           API_URL="http://otherhost:port/v1/chat/completions" ./chat.sh
#
#  - Press Ctrl+C to exit at any time.

if [[ $# -ge 1 ]]; then
  API_URL="$1"
fi

# Conversation history for normal chatting
MESSAGES='[]'

echo "Interactive chat (final answers only)"
echo "Press Ctrl+C to exit"
echo

extract_final() {
  # Input: raw model content on stdin
  # Output: best-effort "final answer" (single line or multi-line)
  #
  # Strategy:
  #  1) If there's a FINAL: line, use it (and anything after it)
  #  2) Else, if there's </think>, return everything after the last </think>
  #  3) Else, return empty (caller may trigger auto-repair)
  local raw
  raw="$(cat)"

  # 1) FINAL: marker (preferred)
  if printf "%s\n" "$raw" | grep -q '^FINAL:'; then
    # Print everything after FINAL: (first occurrence)
    printf "%s\n" "$raw" | awk '
      found==1 {print}
      /^FINAL:/ {
        sub(/^FINAL:[[:space:]]*/, "", $0)
        print
        found=1
      }
    ' | sed 's/^[[:space:]]*//'
    return 0
  fi

  # 2) Anything after the last </think>
  if printf "%s\n" "$raw" | grep -q '</think>'; then
    # Print everything after the last closing think tag
    printf "%s\n" "$raw" | awk '
      {lines[NR]=$0}
      END{
        last=0
        for(i=1;i<=NR;i++){
          if(lines[i] ~ /<\/think>/){ last=i }
        }
        for(i=last+1;i<=NR;i++){
          print lines[i]
        }
      }
    ' | sed 's/^[[:space:]]*//'
    return 0
  fi

  # 3) Nothing usable
  return 1
}

call_chat() {
  # $1 = messages json array
  local msgs="$1"
  curl -sS "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer dummy" \
    -d "$(jq -n \
      --arg model "$MODEL" \
      --argjson messages "$msgs" \
      '{
        model: $model,
        messages: $messages,
        temperature: 0,
        max_tokens: 512
      }')"
}

while true; do
  read -rp "You: " USER_INPUT

  # Append user message to conversation
  MESSAGES="$(jq -c --arg msg "$USER_INPUT" \
    '. + [{"role":"user","content":$msg}]' <<<"$MESSAGES")"

  # First call: normal response (may include <think>, may include final text)
  RESPONSE="$(call_chat "$MESSAGES")"
  RAW="$(jq -r '.choices[0].message.content // empty' <<<"$RESPONSE")"

  # Try to extract final answer without showing <think>
  FINAL="$(printf "%s\n" "$RAW" | extract_final || true)"
  FINAL="$(printf "%s\n" "$FINAL" | sed '/^[[:space:]]*$/d')"  # drop empty lines

  # If still empty, auto-repair: ask the model to produce a final answer only
  if [[ -z "$FINAL" ]]; then
    # Create a "repair" request that does NOT rely on the model obeying earlier instructions.
    # It uses the raw output (even if it's only thinking) and asks for a final answer only.
    REPAIR_MESSAGES="$(jq -c --arg raw "$RAW" --arg q "$USER_INPUT" '[
      {"role":"system","content":"Rewrite the answer as a final answer only. Do NOT include <think> or any reasoning. Output only the final answer text."},
      {"role":"user","content":("User question: " + $q + "\n\nModel output to rewrite:\n" + $raw)}
    ]' <<<"[]")"

    REPAIR_RESPONSE="$(call_chat "$REPAIR_MESSAGES")"
    REPAIR_RAW="$(jq -r '.choices[0].message.content // empty' <<<"$REPAIR_RESPONSE")"

    # As a last resort, just strip any think blocks from the repaired content
    FINAL="$(printf "%s\n" "$REPAIR_RAW" | awk '
      BEGIN { skip=0 }
      /<think>/ { skip=1; next }
      /<\/think>/ { skip=0; next }
      skip==0 { print }
    ' | sed 's/^[[:space:]]*//' | sed '/^[[:space:]]*$/d')"
  fi

  if [[ -z "$FINAL" ]]; then
    FINAL="(no final answer returned)"
  fi

  echo "Assistant: $FINAL"
  echo

  # Append assistant raw reply to history (keep reality of what server said)
  MESSAGES="$(jq -c --arg msg "$RAW" \
    '. + [{"role":"assistant","content":$msg}]' <<<"$MESSAGES")"
done
