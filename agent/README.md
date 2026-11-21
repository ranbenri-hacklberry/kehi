# Kehi local agent: guards and eval

- `agent-pipeline.js` – deterministic guards around the model and the keyword engine: full Hebrew day names in hours, forced removal of sensitive details (health, children's names, IDs/codes), variant limited to the scenario's own list, schema-text filtering and neutral (plural) address in replies, varied refusals. Loaded by the apps as `js/agent-pipeline.js`.
- `prompts.v2.json` – prompt additions for the intent classifier and the answer prompt.
- `eval/` – the step-1 eval set (fictional places, no real people) and scripts. Runs against a local Ollama only.
