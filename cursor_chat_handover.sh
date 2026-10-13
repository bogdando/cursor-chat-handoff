#!/bin/bash
# Summarize Cursor chat transcripts per a message
#
# Example:
# MODELURL=http://10.0.0.15:8000
# BEHAVIOR="granite-4.2-3b:30k"
# bash ~/cursor_chat_handover.sh ~/.cursor/projects/foo/agent-transcripts/36920837-4258-4ba4-9464-2fb5eb07cb75/36920837-4258-4ba4-9464-2fb5eb07cb75.jsonl
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
MAXINPUTTOKENS=${MAXINPUTTOKENS:-35000}
# Max output summarization tokens for the chat transcript.
# Also provides max input tokens of the final chat handover document
# The sum of both input and output tokens can't exceed the model max context size.
MAXOUTTOKENS=${MAXOUTTOKENS:-${MAXINPUTTOKENS:-35000}}
# LLM to use for handover summarizations
MODELURL=${RAG_MCP_SUMMARIZER_URL:-${MODELURL:-http://10.0.0.15:8000}}
# Either to provide previous chunks summary for assistant role as handover document for a next chunk
# W/o handover docs each chunk summarized independently with zero previous context
HANDOVER=${HANDOVER:-no}

# Template the prompt as JSON escaped payload:
# escape file1 file2(or /dev/null) maxtokens
function escape() {
  local p1="Extract <user_query> blocks, agent plan, facts, findings, results "
    p1+="as new uniq items only, then output summary as max 20 bullets, each max 200 words"
    local p2="Previous sessions summary (already processed, skip extracting bullets)"
    local tpl='{"messages": [{"role": "user", "content": "{{ (p1 + ": " + d1) | tojson }}"}, '
    tpl+='{"role": "assistant", "content": "{{ (p2 + ": " + d2) | tojson }}"}], "temperature": 0, "max_tokens": {{ mt }}}'
    cat "$1" | \
    grep -Eo "[a-zA-Z0-9_='+-/.,\| ►<>•\(\)]*" | \
    sed -r 's/[\(\)]//g;s/(--)+/-/g;s/(==)+/=/g;s/"//g;s/  / /g' > "${1}_"
    d1=${1}_
    
    if [ -s "$2" ]; then
      cat "$2" | \
      grep -Eo "[a-zA-Z0-9_='+-/.,\| ►<>•\(\)]*" | \
      sed -r 's/[\(\)]//g;s/(--)+/-/g;s/(==)+/=/g;s/"//g;s/  / /g' > "${2}_"
      d2="${2}_"
    else
      d2="$2"
    fi

    python3 -c "import sys,jinja2,re; m=r'([^a-zA-Z0-9\s\"\'_=\'\+\-\/\.,\| ►─├<>•])'; t1=re.sub(m,'',open('$d1').read()); t2=re.sub(m,'',open('$d2').read()); print(jinja2.Template('$tpl').render(d1=t1,d2=t2,mt=$3,p1='$p1',p2='$p2'))" |\
    tr -s '\n' ' ' |\
    sed -r 's/\\n/ /g;s/\\"//g;s/""/"/g;s/\\\u[0-9]+\w?/ /g'
}

# Skip thinking steps, extract "bullet points" as best effort
function extract(){
  if [ ! -s "$1" ]; then
    echo 
    return
  fi
  cat "$1" | perl -ne 'print unless 1 .. /^<\/think>/' > "${1}.bullets"
  if [ ! -s "${1}.bullets" ]; then
    cat "$1" | grep -E '^(\*|-|([0-9]|[a-z])*[\.\)]) ' > "${1}.bullets"
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

rm -f /tmp/${f}.chunk.*.summary
rm -f /tmp/${f}.handovers
touch /tmp/${f}.handovers
fsize=$(cat /tmp/${f}.messages | wc -c)
# Generate inter-chunks handover facts or treat each as independent
for c in $(ls -tr1 /tmp/${f}.chunk.* | grep -Ev 'bullets|summary|handover|_'); do
  echo "Generate handover for chunk $c"
  csize=$(cat "$c" | wc -c)
  prev_handover="/dev/null"
  if [ "$HANDOVER" = "yes" ]; then
    prev_ind=$(echo ${c} | awk -F'.' '{print $NF}')
    if [ $prev_ind -gt 0 ]; then
      prev_ind=$(( $prev_ind - 1 ))
    fi
    prev_handover="/tmp/${f}.chunk.${prev_ind}.summary"
    touch "$prev_handover"
    # Accumulate inter-chunk handovers
    extract $prev_handover >> "/tmp/${f}.handovers"
  fi

  csize=$(cat "$c" "/tmp/${f}.handovers" | wc -c)
  maxtok=$(( $MAXOUTTOKENS * $csize / $fsize ))
  if [ $maxtok -gt $MAXOUTTOKENS ]; then
    maxtok=$MAXOUTTOKENS
  fi
  if [ $maxtok -lt 100 ]; then
    maxtok=100
  fi

  escape "$c" "/tmp/${f}.handovers" $maxtok > "${c}.query"

  curl -X POST -d @"${c}.query" "${MODELURL}/v1/chat/completions" -H "Content-Type: application/json" > "${c}.summary_"
  jq -r '.choices[].message.content' "${c}.summary_" > "${c}.summary"
done

# Aggregate to produce the final handover document
if [ -f "/tmp/${f}.${BEHAVIOR}.summary" ] ; then
  mv -f "/tmp/${f}.${BEHAVIOR}.summary" "/tmp/${f}.${BEHAVIOR}.summary.$(date +%Y-%m-%d-%H:%M)~"
fi

rm -f /tmp/${f}.summary_*
if [ "$HANDOVER" = "yes" ]; then
  extract "${c}.summary" >> "/tmp/${f}.handovers"
  mv -f "/tmp/${f}.handovers" "/tmp/${f}.${BEHAVIOR}.summary"
else
  for s in $(ls -tr1 /tmp/${f}.chunk.*.summary); do
    extract "$s" >> "/tmp/${f}.${BEHAVIOR}.summary"
  done
fi

cp "/tmp/${f}.${BEHAVIOR}.summary" "${dir}/${f}.${BEHAVIOR}.summary.md"
