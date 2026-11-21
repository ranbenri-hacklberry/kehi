# Kehi local agent: guards and eval

- `agent-pipeline.js` – deterministic guards around the model and the keyword engine: full Hebrew day names in hours, forced removal of sensitive details (health, children's names, IDs/codes), variant limited to the scenario's own list, schema-text filtering and neutral (plural) address in replies, varied refusals. Loaded by the apps as `js/agent-pipeline.js`.
- `prompts.v2.json` – prompt additions for the intent classifier and the answer prompt.
- `eval/` – the step-1 eval set (fictional places, no real people) and scripts. Runs against a local Ollama only.

- Generation cap: call the model with `num_predict: 512`. E2B sometimes runs to ~2,200 tokens without it.
- `eval/postproc.js` applies these guards to raw model outputs before scoring.

## Two-stage intent (for small models such as E2B)

- Stage 1: classify only, with the intent constrained to an enum (`format` schema). Stage 2: extract slots with that scenario's own schema (its fields, its variant list).
- `eval/build_twostage.js scenarios.json` builds `twostage.json`; `eval/run_twostage.py <model> <out.jsonl>` runs it against local Ollama.
- `postprocessIntent` also applies deterministic overrides: emergency wording always becomes `emergency_redirect`, and prompt-injection wording gets no intent, whatever the model said.
