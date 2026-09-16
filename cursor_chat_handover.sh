#!/bin/bash
# Summarize Cursor chat transcripts per a message
#
# Example:
# MODELURL=http://10.0.0.15:8000
# bash ~/cursor_chat_handover.sh ~/.cursor/projects/foo/agent-transcripts/36920837-4258-4ba4-9464-2fb5eb07cb75/36920837-4258-4ba4-9464-2fb5eb07cb75.jsonl
#
set -uex
set -o pipefail

transcript="$1"
f="$(basename ${transcript})"
dir="$(dirname ${transcript})"

# Max input can be given to the model (tokens), and to split long chunks by
MAXINPUTTOKENS=${MAXINPUTTOKENS:-10000}
# Max output summarization tokens for the chat transcript.
# Also provides max input tokens of the final chat handover document
# The sum of both input and output tokens can't exceed the model max context size.
MAXOUTTOKENS=${MAXOUTTOKENS:-10000}
# LLM to use for handover summarizations
MODELURL=${RAG_MCP_SUMMARIZER_URL:-${MODELURL:-http://10.0.0.15:8000}}

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

# Generate handover facts
fsize=$(cat /tmp/${f}.messages | wc -c)
for c in $(ls -1 /tmp/${f}.chunk.* | sort -n); do
  echo "Generate handover for chunk $c"
  csize=$(cat $c | wc -c)
  maxtok=$(( $MAXOUTTOKENS * $csize / $fsize ))
  if [ $maxtok -gt $MAXOUTTOKENS ]; then
    maxtok=$MAXOUTTOKENS
  fi
  if [ $maxtok -lt 100 ]; then
    maxtok=100
  fi

  printf "Always summarize all <user_query>../<user_query> blocks in 50 words max as 'user wants'. " > /tmp/query
  printf "For everything else restate the agent thinking, plans, procedures, results, facts and findings " >> /tmp/query
  printf "in 2-10 bullets with detailed summaries: " >> /tmp/query

  # as json escaped payload
  cat "$c" | \
    grep -Eo "[a-zA-Z0-9_='+-/.,\| ►<>•\(\)]*" | \
    sed -r 's/[\(\)]//g;s/(--)+/-/g;s/(==)+/=/g;s/  / /g' | \
    python3 -c "import sys, jinja2, re; clean_text = re.sub(r'([^a-zA-Z0-9\s\"\'_=\'\+\-\/\.,\| ►─├<>•])', '', sys.stdin.read().strip()); print(jinja2.Template('{{ data | tojson }}').render(data=clean_text))" | \
    tr -s '\n' ' ' | \
    sed -r 's/\\n/ /g;s/"//g' >> /tmp/query

  curl ${MODELURL}/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d "{\"messages\": [{ \"role\": \"user\",
  \"content\": \"$(cat /tmp/query)\"}],
    \"temperature\": 0,
    \"max_tokens\": $maxtok}" > "${c}.summary"
done

if [ -f "/tmp/${f}.summary"] ; then
  mv -f "/tmp/${f}.summary" "/tmp/${f}.summary.$(date +%Y-%m-%d-%H:%M)~"
fi

for s in $(ls -1 /tmp/${f}.chunk.*.summary); do
  jq -r '.choices[].message.content' "$s" >> /tmp/${f}.summary
done

cp /tmp/${f}.summary "${dir}/${f}.summary.md"
