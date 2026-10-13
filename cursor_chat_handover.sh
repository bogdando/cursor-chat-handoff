#!/bin/bash
# Summarize Cursor chat transcripts per a message
#
# Example:
# MODELURL=http://10.0.0.15:8000
# BEHAVIOR="granite-4.2-3b:30k"
# bash ~/cursor_chat_handover.sh ~/.cursor/projects/foo/agent-transcripts/36920837-4258-4ba4-9464-2fb5eb07cb75/36920837-4258-4ba4-9464-2fb5eb07cb75.jsonl
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
# Max input can be given to the model (tokens), and to split long chunks by.
# Defaults work best for granite-4.2-3b with max context size 90000 tokens.
MAXINPUTTOKENS=${MAXINPUTTOKENS:-30000}
# Max output summarization tokens for the chat transcript.
# Also provides max input tokens of the final chat handover document
# The sum of both input and output tokens can't exceed the model max context size.
MAXOUTTOKENS=${MAXOUTTOKENS:-${MAXINPUTTOKENS:-40000}}
# LLM to use for handover summarizations
MODELURL=${RAG_MCP_SUMMARIZER_URL:-${MODELURL:-http://10.0.0.15:8000}}
# Either to provide previous chunks summary for assistant role as handover document for a next chunk
# W/o handover docs each chunk summarized independently with zero previous context
HANDOVER=${HANDOVER:-no}
# Custom chunk number to resume processing from / stop after (if >0)
START_CHUNK=${START_CHUNK:-0}
STOP_CHUNK=${STOP_CHUNK:-0}

PSUM="Summarize changes, facts, findings, results as max 50 bullets ONLY"
PDEDUP="Dedup repeated bullets. Always retain original uniq items. Never prefer ones over others."

# Template the prompt as JSON escaped payload:
# escape file1 file2(or /dev/null) maxtokens
function escape() {
    local d1="${1}_"
    local d2="$2"
    local mt="$3"
    local p1="${4:-$PSUM}"
    local p2="Previous sessions summary"
    local tpl='{"messages": [{"role": "user", "content": "{{ (p1 + ": " + d1) | tojson }}"}, '
    tpl+='{"role": "assistant", "content": "{{ (p2 + ": " + d2) | tojson }}"}], "temperature": 0, "max_tokens": {{ mt }}}'

    cat "$1" | \
    grep -Eo "[a-zA-Z0-9_='+-/.,\| ►<>•\(\)]*" | \
    sed -r 's/[\(\)]//g;s/(--)+/-/g;s/(==)+/=/g;s/"//g;s/  / /g' > "${d1}"
    
    if [ -s "$d2" ]; then
      cat "$d2" | \
      grep -Eo "[a-zA-Z0-9_='+-/.,\| ►<>•\(\)]*" | \
      sed -r 's/[\(\)]//g;s/(--)+/-/g;s/(==)+/=/g;s/"//g;s/  / /g' > "${d2}_"
      d2="${d2}_"
    fi

    python3 -c "import sys,jinja2,re; m=r'([^a-zA-Z0-9\s\"\'_=\'\+\-\/\.,\| ►─├<>•])'; t1=re.sub(m,'',open('$d1').read()); t2=re.sub(m,'',open('$d2').read()); print(jinja2.Template('$tpl').render(d1=t1,d2=t2,mt=$mt,p1='$p1',p2='$p2'))" |\
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
  rm -f /tmp/${f}.messages.*
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
  total=$(ls -1 /tmp/${f}.messages.* | wc -l)
  IFS=$'\n'
  for m in $(ls -1 /tmp/${f}.messages.*); do
    if [ $i -gt $total ]; then
      break
    fi
    echo "Processing message #${i}/${total}: $m"
    ind=$(echo "${m}" | awk -F'.' '{print $NF}' | sort -n | head -1)
    split -xb $(($MAXINPUTTOKENS * 4 - 100)) "$m" "/tmp/${f}.messages.${ind}"
    rm -f "/tmp/${f}.messages.${ind}"
    last=$(ls -1 /tmp/${f}.messages.${ind}* | awk -F'.' '{print $NF}' | sort -n | tail -1 | cut -c 6-)
    if [ "x$last" != "x" ] && [ $last -gt 0 ]; then
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
  for m in $(ls -1 /tmp/${f}.messages.*); do
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
if [ "$RECHUNK" = "yes" ] || [ ! -f /tmp/${f}.chunk.0 ] ; then
  rechunk
fi

if [ $START_CHUNK -eq 0 ]; then
  rm -f /tmp/${f}.chunk.*.summary*
  rm -f /tmp/${f}.chunk.*.handovers*
  rm -f /tmp/${f}.handovers*
  touch /tmp/${f}.handovers
fi
fsize=$(cat /tmp/${f}.messages | wc -c)
# Generate inter-chunks handover facts or treat each as independent
for c in $(ls -tr1 /tmp/${f}.chunk.* | grep -Ev 'large|bullets|summary|handover|_'); do
  prev_ind=$(echo ${c} | awk -F'.' '{print $NF}')
  if [ $START_CHUNK -gt $prev_ind ]; then continue; fi
  if [ $STOP_CHUNK -gt 0 ] && [ $STOP_CHUNK -le $prev_ind ]; then
    echo "Stopping at chunk #$STOP_CHUNK"
    break
  fi
  echo "Generate handover for chunk $c"
  csize=$(cat "$c" | wc -c)
  prev_handover="/dev/null"
  if [ "$HANDOVER" = "yes" ]; then
    if [ $prev_ind -gt 0 ]; then
      prev_ind=$(( $prev_ind - 1 ))
    fi
    prev_handover="/tmp/${f}.chunk.${prev_ind}.summary"
    touch "$prev_handover"

    # Accumulate dedupped inter-chunk handovers
    extract $prev_handover >> "/tmp/${f}.handovers"

    if [ $prev_ind -gt 1 ]; then
      escape "/tmp/${f}.handovers" /dev/null "$MAXOUTTOKENS" "$PDEDUP" > /tmp/dedup_query
      curl -X POST -d @/tmp/dedup_query "${MODELURL}/v1/chat/completions" -H "Content-Type: application/json" > "${c}.handovers_"
      jq -r '.choices[].message.content' "${c}.handovers_" > "${c}.handovers"
      extract "${c}.handovers" > "/tmp/${f}.handovers"
    fi
  fi

  csize=$(cat "$c" "/tmp/${f}.handovers" | wc -c)
  maxtok=$(( $MAXOUTTOKENS * $csize / $fsize ))
  if [ $maxtok -gt $MAXOUTTOKENS ]; then
    maxtok=$MAXOUTTOKENS
  fi
  if [ $maxtok -lt 100 ]; then
    maxtok=100
  fi

  escape "$c" "/tmp/${f}.handovers" "$maxtok" > "${c}.query" 
  curl -X POST -d @"${c}.query" "${MODELURL}/v1/chat/completions" -H "Content-Type: application/json" > "${c}.summary_"
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
  extract "${c}.summary" >> "/tmp/${f}.handovers"
  if [ $prev_ind -gt 1 ]; then
    escape "/tmp/${f}.handovers" /dev/null "$MAXOUTTOKENS" "$PDEDUP" > /tmp/dedup_query
    curl -X POST -d @/tmp/dedup_query "${MODELURL}/v1/chat/completions" -H "Content-Type: application/json" > "${c}.handovers_"
    jq -r '.choices[].message.content' "${c}.handovers_" > "${c}.handovers"
    extract "${c}.handovers" > "/tmp/${f}.handovers"
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
