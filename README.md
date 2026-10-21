# Build a Handoff Document for Cursor Chat History

## How to use it with a self-hosted/open-weight LLM models

Configure LiteLLM `~/.config/litellm/config.yaml` for accessing the models
without exposing API tokens in the logs

```yaml
model_list:
  - model_name: rits/zai-org/glm-5-3
    litellm_params:
      custom_llm_provider: openai
      model: rits/zai-org/glm-5-3
      api_key: os.environ/MYAPIKEY
      base_url: https://api.myllm.example.net/v1
```

Start LiteLLM
```bash
litellm --port 4000 --config ~/.config/litellm/config.yaml
```

Tweak Cursor chat summarizer script args for summarization and deduplication models access
```bash
export MYAPIKEY=<your-api-key>
export MODEL=ibm-granite/granite-4.2-3b
export MODELURL=<your-granite-model-endpoint>
export MODEL2=rits/zai-org/glm-5-3
export MODELURL2=http://localhost:4000
export BEHAVIOR=granite-4.2-3b:glm-5-3:60k:30k
export MAXINPUTTOKENS=60000
export MAXOUTTOKENS=30000
```

Install and run the summarizer script for your Cursor session chat history id (jsonl file path)

```bash
pip install count-tokens
git clone https://github.com/bogdando/cursor-chat-handoff.git
cd cursor-chat-handoff
id=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
chat="$HOME/.cursor/projects/myproject/agent-transcripts/${id}/$id.jsonl"
bash cursor_chat_handoff.sh $chat
```

## How it works

It parses the session transcript for a user queries and agent messages only.
Then it aggregates those by chunks based on the max input tokens that you provided

```bash
Processing message #1166/1167: /tmp/3d24f185-06b6-4a04-ab47-ce362a4aa066.jsonl.messages.01166
Processing message #1167/1167: /tmp/3d24f185-06b6-4a04-ab47-ce362a4aa066.jsonl.messages.01167
Starting new chunk #1: context filled
Starting new chunk #2: context filled
```

Then it starts building chunks summarizations and the rolling handoff document
```bash
Generate handoff for chunk /tmp/3d24f185-06b6-4a04-ab47-ce362a4aa066.jsonl.chunk.0
Chunk #0: 59893 actual input tokens of 535746 total, 30000 output tokens budget
Summarize as bullets with model ibm-granite/granite-4.2-3b
...
Chunk #5: 60250 actual input tokens of 535746 total, 28350 output tokens budget
Summarize as bullets with model ibm-granite/granite-4.2-3b
  % Total    % Received % Xferd  Average Speed  Time    Time    Time   Current
                                 Dload  Upload  Total   Spent   Left   Speed
100 209.4k 100    395 100 209.0k    616 326.1k                              0
curl: (22) The requested URL returned error: 400
Chunk #5: 60250 actual input tokens of 535746 total, 28250 output tokens budget
...
```

## How it breaks

The output tokens budgets are evaluated dynamically via retry loops.

When deduplicated output of the handoff documents cannot fit into completion tokens because of extended thinking
process consuming all budget, the script attempts to extract the summarization bullet points from the thinking steps.
That is best effort and produces too much noise that confuses the model during next iterations.

The mitigation is using a larger context window (defined by the sum of MAXOUTTOKENS and MAXINPUTTOKENS).
The script tries to reduce the model thinking efforts, but those hacks are specific to a model - what works well
for GLM 5.3, does not work with IBM Granite 4.2, or it may work differently with Qwen.

To resume from a failed chunk with adjusted output (completion) tokens parameter
```bash
MAXOUTTOKENS=33333 START_CHUNK=42 bash cursor_chat_handoff.sh $chat
```
If you changed `MAXINPUTTOKENS`, you must use `RECHUNK=yes`.

While the chunks being processed, you can inspect how the handoff documents rolled over accumulating changes
```bash
for i in `seq 3 42`; do \
  diff -Nuar /tmp/$id.jsonl.chunk.$i.handoffs.bullets \
    /tmp/$id.jsonl.chunk.$(( $i - 1)).handoffs.bullets; \
    read f; \
done
```
I recommend using https://github.com/wilfred/difftastic tool instead of diff.

These inter-chunk handoff deltas help to manually estimate the quality of
summarizaation and deduplication work done by the models.

