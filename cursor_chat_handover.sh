#!/bin/bash
# Summarize Cursor chat transcripts per a message
#
# Prequire: pip install count-tokens
#
# Example:
# Model for summarization of chat history chunks
# MODEL="ibm-granite/granite-4.2-3b"
# MODELURL=http://10.0.0.15:8000
# Model for deduplication of handover document bullet points
# APIKEY2=foo
# MODEL2="rits/zai-org/glm-5-3"
# MODELURL2=http://10.0.0.15:8000
# BEHAVIOR="granite-4.2-3b:glm-5-3:60k:30k"
# MAXINPUTTOKENS=60000 MAXOUTTOKENS=30000 bash ~/cursor_chat_handover.sh \
#   ~/.cursor/projects/foo/agent-transcripts/<uuid>/<uuid>.jsonl
#
# Analyse how inter-chunks handover docs accumulate items and deduplicate them (starts from chunk #3):
# diff /tmp/<uuid>.jsonl.chunk.<N>.handovers.bullets /tmp/<uuid>.jsonl.chunk.<N-1>.handovers.bullets
#
set -ue
set -o pipefail

transcript="$1"
f="$(basename ${transcript})"
dir="$(dirname ${transcript})"

# A model specific behavior marker for the summary file name
BEHAVIOR=${BEHAVIOR:-unknown}

# Execution control
REPARSE=${REPARSE:-no}
RECHUNK=${RECHUNK:-no}
# Max input can be given to the either model (in tokens), and to split long chunks by.
# Defaults work best for granite-4.2-3b with max context size 90000 tokens.
MAXINPUTTOKENS=${MAXINPUTTOKENS:-40000}
# Max output summarization tokens for chunks. 
# We cannot estimate that for the whole chat transcript handover summary.
# The sum of both input and output tokens can't exceed the model max context size.
MAXOUTTOKENS=${MAXOUTTOKENS:-${MAXINPUTTOKENS:-40000}}
# LLM to use for handover chunks summarizations as bullets
APIKEY=${APIKEY:-x}
MODEL=${MODEL:-ibm-granite/granite-4.2-3b}
MODELURL=${MODELURL:-http://10.0.0.15:8000}
# Optional LLM to use for deduplication of accumulated bullets during consequent chunks handovers
APIKEY2=${APIKEY2:-x}
MODEL2=${MODEL2:-${MODEL:-ibm-granite/granite-4.2-3b}}
MODELURL2=${MODELURL2:-${MODELURL:-http://10.0.0.15:8000}}
# Either to provide previous chunks summary for assistant role as handover document for a next chunk
# W/o handover docs each chunk is summarized independently with zero previous context handed to LLM
HANDOVER=${HANDOVER:-yes}
# Custom chunk number to resume processing from / stop after (if >0)
START_CHUNK=${START_CHUNK:-0}
STOP_CHUNK=${STOP_CHUNK:-0}

PSUM="Extract detailed summary for key facts, findings, changes made and results achieved, as dashed bullets ONLY"
PDEDUP="Dedup repeated bullets. Always retain original uniq items. Never prefer ones over others. Compact neighbors to reduce high bullets count."

# Query LLM endpoint for JSON payload from file name input arg
function query(){
  local f="$1"
  local key="${2:-$APIKEY}"
  local url="${3:-$MODELURL}"
  if [ "$key" != "x" ]; then
    curl --fail-with-body -X POST -d @"$1" "${url}/v1/chat/completions" -H "Content-Type: application/json" -H "Authorization: Bearer $key"
  else
    curl --fail-with-body -X POST -d @"$1" "${url}/v1/chat/completions" -H "Content-Type: application/json"
  fi
}

# Count actual tokens of the given files
function tokencount() {
  local out t total=0
  [ $# -ge 1 ] || { echo 0; return; }
  for t in "$@"; do
    out=$(count-tokens --format json "$t" 2>/dev/null || true)
    if [ "${out:-x}" = "x" ]; then
      # Fallback to a rough 4 chars per token estimate w/o count-tokens working
      out=$(( $(cat "$t" 2>/dev/null | wc -c) / 4 ))
    fi
    total=$(( $total + $out ))
  done
  echo "$total"
}

# Dedup handover document after added chunk c summary into it
function dedup(){
  local rc=1
  local f="$1"
  local c="$2"
  local ind="$3"
  local summary="$4"
  local sumtok=0
  tok=null
  tok=$(jq -r ".usage.completion_tokens" "/tmp/${f}.chunk.${ind}.handovers_" || echo 0)
  if [ "$tok" = "null" ]; then
    tok=0
  fi
  sumtok=$(tokencount "$summary")
  handovertok=$(( $sumtok * 2 + $tok ))
  if [ $handovertok -gt $MAXOUTTOKENS ]; then
    handovertok=$MAXOUTTOKENS
  fi
  if [ $handovertok -lt 8000 ]; then
    handovertok=8000
  fi
  echo "Deduplicate bullets with model $MODEL2"
  escape "/tmp/${f}.handovers" /dev/null "$MAXOUTTOKENS" "$PDEDUP" "$MODEL2" > /tmp/dedup_query
  set +e
  query /tmp/dedup_query "$APIKEY2" "$MODELURL2" > "${c}.handovers_"
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    echo "Deduplicate bullets with model $MODEL2 and max completion tokens $handovertok"
    escape "/tmp/${f}.handovers" /dev/null "$handovertok" "$PDEDUP" "$MODEL2" > /tmp/dedup_query
    query /tmp/dedup_query "$APIKEY2" "$MODELURL2" > "${c}.handovers_"
  fi
  jq -r '.choices[].message.content' "${c}.handovers_" > "${c}.handovers"
  extract "${c}.handovers" > "/tmp/${f}.handovers"
}

# Template the prompt as JSON escaped payload:
# escape file file2(or /dev/null) maxtokens 
function escape() {
    local d1="$1"
    local d2="$2"
    local mt="$3"
    local p1="${4:-$PSUM}"
    local p2="Previous sessions summary"
    local m="${5:-$MODEL}"
    local tpl
    tpl='{"messages": [{"role": "user", "content": "{{ (p1 + ": " + d1) | tojson }}"}'
    if  [ -s "$d2" ]; then
      tpl+=',{"role": "assistant", "content": "{{ (p2 + ": " + d2) | tojson }}"}'
    fi
    tpl+='], "temperature": 0, "max_tokens": {{ mt }}, "model": "{{ m }}"}'

    cat "$d1" | \
    grep -Eo "[a-zA-Z0-9_='+-/.,\| ►<>•\(\)]*" | \
    sed -r 's/[\(\)]//g;s/(--)+/-/g;s/(==)+/=/g;s/"//g;s/  / /g' > "${d1}_"
    d1="${d1}_"
    
    if [ -s "$d2" ]; then
      cat "$d2" | \
      grep -Eo "[a-zA-Z0-9_='+-/.,\| ►<>•\(\)]*" | \
      sed -r 's/[\(\)]//g;s/(--)+/-/g;s/(==)+/=/g;s/"//g;s/  / /g' > "${d2}_"
      d2="${d2}_"
    fi

    python3 -c "import sys,jinja2,re; m=r'([^a-zA-Z0-9\s\"\'_=\'\+\-\/\.,\| ►─├<>•])'; t1=re.sub(m,'',open('$d1').read()); t2=re.sub(m,'',open('$d2').read()); print(jinja2.Template('$tpl').render(d1=t1,d2=t2,mt=$mt,p1='$p1',p2='$p2',m='$m'))" |\
    tr -s '\n' ' ' |\
    sed -r 's/\\n/ /g;s/\\"//g;s/""/"/g;s/\\\u[0-9]+\w?/ /g'
}

# Skip thinking steps, extract "bullet points" as best effort
function extract(){
  local bullets="^\s*(•|\*|-|([0-9]|[a-z])*[\.\)]) "
  if [ ! -s "$1" ]; then
    echo 
    return
  fi
  cat "$1" | perl -ne 'print unless 1 .. /^<\/think>/' > "${1}.bullets"
  if [ -s "${1}.bullets" ]; then
    cat "${1}.bullets" | grep -E "$bullets" > "${1}.bullets_"
    mv -f "${1}.bullets_" "${1}.bullets"
  else
    cat "$1" | grep -E "$bullets" > "${1}.bullets"
  fi
  cat "${1}.bullets"
}

function reparse() {
  # Only get messages and ignore everything else (tools, actions)
  rm -f /tmp/${f}.messages*
  jq -r '.message.content[]|select(.text != null)|"\"MSG:\(.text)/MSG\""' ${transcript} 2>/dev/null > "/tmp/${f}.messages" || true

  # Extrqact messages into individual files
  FILE_PREFIX="/tmp/${f}.messages" perl -0777 -ne '
  $i = 1;
  $prefix = $ENV{"FILE_PREFIX"} || "block"; # Fallback to "block" if empty
  while (/MSG(.*?)\/MSG/gs) {
      $pad_i = sprintf("%05d", $i);
      open my $fh, ">", "${prefix}.${pad_i}" or die $!;
      print $fh $1;
      close $fh;
      $i++;
  }' "/tmp/${f}.messages"

  # Rebuild messages list based on context window size limit
  i=1  # message split index
  total=$(ls -1 /tmp/${f}.messages.* | grep -Ev '_|__' | wc -l)
  IFS=$'\n'
  for m in $(ls -1 /tmp/${f}.messages.* | grep -Ev '_|__'); do
    if [ $i -gt $total ]; then
      break
    fi
    echo "Processing message #${i}/${total}: $m"
    escape "$m" /dev/null 0 STARTMARK > "${m}__"
    jq -r '.messages[].content' "${m}__" | awk -F'STARTMARK: ' '{print $NF}' > "$m"
    ind=$(echo "$m" | awk -F'.' '{print $NF}' | sort -n | head -1)
    split -xb $(($MAXINPUTTOKENS * 4 - 100)) "$m" "/tmp/${f}.messages.${ind}"
    rm -f "/tmp/${f}.messages.${ind}"
    last=$(ls -1 /tmp/${f}.messages.${ind}* | awk -F'.' '{print $NF}' | sort -n | tail -1 | cut -c 6-)
    if [ "${last:-x}" != "x" ] && [ $last -gt 0 ]; then
      echo "Produced split messages #${ind}00-${last}"
      total=$(( $total + $last ))
    fi
    i=$(( $i + 1 )) 
  done
}

function rechunk() {
  # Combine messages into chunks fitting the context window
  rm -f /tmp/${f}.chunk*
  c=0  # aggregating chunk index
  IFS=$'\n'
  for m in $(ls -1 /tmp/${f}.messages.* | grep -Ev '_|__'); do
    touch "/tmp/${f}.chunk.${c}"
    size=$(cat /tmp/${f}.chunk.${c}* "$m" | wc -c)
    size=$(( $size / 4 + 100 ))
    if [ $size -ge $MAXINPUTTOKENS ]; then
      c=$(( $c + 1 ))
      echo "Starting new chunk #${c}: context filled"
    fi
    cat "$m" >> "/tmp/${f}.chunk.${c}"
  done
}

if [ "$REPARSE" = "yes" ] || [ ! -f /tmp/${f}.messages.0000100 ] ; then
  reparse
fi
# Total actual tokens of all chat history messages for the proportional
# distribution of the output tokens budget across chunks
totaltok=$(tokencount "/tmp/${f}.messages")
[ "$totaltok" -gt 0 ] || totaltok=1

if [ "$RECHUNK" = "yes" ] || [ ! -f /tmp/${f}.chunk.0 ] ; then
  rechunk
fi

if [ $START_CHUNK -eq 0 ]; then
  rm -f /tmp/${f}.chunk.*.summary*
  rm -f /tmp/${f}.chunk.*.handovers*
  rm -f /tmp/${f}.handovers*
  touch /tmp/${f}.handovers
fi

# Generate inter-chunks handover facts or treat each as independent
prev_ind=0
for c in $(ls -tr1 /tmp/${f}.chunk.* | grep -Ev 'query|large|bullets|summary|handover|_'); do
  ind=$(echo ${c} | awk -F'.' '{print $NF}')
  ind=$(( $ind + 0 ))
  if [ $START_CHUNK -gt $ind ]; then continue; fi
  if [ $STOP_CHUNK -gt 0 ] && [ $STOP_CHUNK -le $ind ]; then
    echo "Stopping at chunk #$STOP_CHUNK"
    break
  fi
  echo "Generate handover for chunk $c"
  prev_summary="/dev/null"
  if [ "$HANDOVER" = "yes" ]; then
    if [ $ind -gt 0 ]; then
      prev_ind=$(( $ind - 1 ))
    fi
    prev_summary="/tmp/${f}.chunk.${prev_ind}.summary"
    touch "$prev_summary"
    cat "/tmp/${f}.chunk.${prev_ind}.handovers.bullets" > "/tmp/${f}.handovers"
    # Accumulate dedupped inter-chunk handovers
    extract $prev_summary >> "/tmp/${f}.handovers"

    if [ $prev_ind -gt 1 ] && [ ! -s "${c}.handovers" ]; then
      # create $c.handovers.bullets for next iteration
      dedup "$f" "$c" "$prev_ind" "$prev_summary"
    fi
  fi

  # Dynamically calculate the output tokens (mt) for the chunk from the actual
  # tokens consumed by the input query chunk plus handovers: the proportional
  # distribution of the MAXOUTTOKENS budget vs the total chat history messages
  # tokens, scaled by 50, and capped by the model context window remaining
  intok=$(tokencount "$c" "/tmp/${f}.handovers")
  maxtok=$(( $MAXOUTTOKENS * $intok / $totaltok * 50 ))
  remtok=$(( $MAXINPUTTOKENS + $MAXOUTTOKENS - $intok ))
  rc=1
  while [ $rc -ne 0 ]; do
    if [ $remtok -lt 500 ]; then
      echo "Output tokens budged exhausted!"
      echo "Try another layout for MAXINPUTTOKENS vs MAXOUTTOKENS?"
      echo "Use START_CHUNK=$ind for altered MAXOUTTOKENS to resume on chunk $ind"
      echo "Or RECHUNK=yes, if changing MAXINPUTTOKENS (will start from scratch)"
      exit 1
    fi
    if [ $maxtok -gt $remtok ]; then
      maxtok=$remtok
    fi
    if [ $maxtok -gt $MAXOUTTOKENS ]; then
      maxtok=$MAXOUTTOKENS
    fi
    if [ $maxtok -lt 500 ]; then
      maxtok=500
    fi
    echo "Chunk #$ind: ${intok} actual input tokens of ${totaltok} total, ${maxtok} output tokens budget"

    if [ "$HANDOVER" = "yes" ] && [ $ind -gt 0 ]; then
      escape "$c" "/tmp/${f}.handovers" "$maxtok" > "${c}.query" 
    else
      escape "$c" /dev/null "$maxtok" > "${c}.query" 
    fi
    echo "Summarize as bullets with model $MODEL"
    set +e
    query "${c}.query" > "${c}.summary_"
    rc=$?
    set -e

    if [ $rc -ne 0 ]; then
      result=$(jq -r ".error.message" "${c}.summary_" )
      if grep -q 'reduce the length'<<<$result ; then
        remtok=$(( $maxtok - 100 ))
      else
        echo "Unexpected error"
        exit 1
      fi
    fi
  done
  jq -r '.choices[].message.content' "${c}.summary_" > "${c}.summary"
done

# Aggregate to produce the final handover document
if [ -f "/tmp/${f}.${BEHAVIOR}.summary" ] ; then
  mv -f "/tmp/${f}.${BEHAVIOR}.summary" "/tmp/${f}.${BEHAVIOR}.summary.$(date +%Y-%m-%d-%H:%M)~"
fi
# Non-deduplicated concatenation of all chunks summaries
if [ -f "/tmp/${f}.${BEHAVIOR}.summary.large" ] ; then
  mv -f "/tmp/${f}.${BEHAVIOR}.summary.large" "/tmp/${f}.${BEHAVIOR}.summary.large.$(date +%Y-%m-%d-%H:%M)~"
fi

if [ "$HANDOVER" = "yes" ]; then
  # pick the last handover
  cat "/tmp/${f}.chunk.${prev_ind}.handovers.bullets" > "/tmp/${f}.handovers"
  extract "${c}.summary" >> "/tmp/${f}.handovers"
  if [ $prev_ind -gt 1 ]; then
    # create final $c.handovers.bullets
    dedup "$f" "$c" "$ind" "${c}.summary"
  fi
  mv -f "/tmp/${f}.handovers" "/tmp/${f}.${BEHAVIOR}.summary"
  for s in $(ls -tr1 /tmp/${f}.chunk.*.summary.bullets); do
   cat "$s" >> "/tmp/${f}.${BEHAVIOR}.summary.large"
  done
  cp "/tmp/${f}.${BEHAVIOR}.summary.large" "${dir}/${f}.${BEHAVIOR}.summary.large.md"
else
  for s in $(ls -tr1 /tmp/${f}.chunk.*.summary); do
    extract "$s" >> "/tmp/${f}.${BEHAVIOR}.summary"
  done
fi

cp "/tmp/${f}.${BEHAVIOR}.summary" "${dir}/${f}.${BEHAVIOR}.summary.md"
