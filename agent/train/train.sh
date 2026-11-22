#!/bin/bash
# Runs after pipeline.sh: dataset -> LoRA (mlx) -> merge into HF ckpt -> ollama create klili-e2b-forms (int4) -> evals
cd ~/kehi-train; O=/Applications/Ollama.app/Contents/Resources/ollama
while ! grep -q PIPE_DONE label.log 2>/dev/null; do sleep 30; done
python3 build_ds.py > ds.log 2>&1 || exit 1
# Free RAM for MLX training (Ran OK): unload Ollama models; relay keeps running and reloads on demand.
for m in $($O ps | awk 'NR>1{print $1}'); do curl -s localhost:11434/api/generate -d "{\"model\":\"$m\",\"keep_alive\":0}" >/dev/null; done
.venv/bin/python -m mlx_lm.lora --model models/qlora --train --data data --iters ${ITERS:-600} --batch-size 4 --num-layers 16 \
  --learning-rate 1e-4 --mask-prompt --grad-checkpoint --adapter-path adapter --steps-per-report 20 --steps-per-eval 100 --save-every 200 \
  --max-seq-length 3072 --seed 7 > train.log 2>&1 || { echo TRAIN_FAIL >> train.log; exit 1; }
.venv/bin/python merge_lora.py models/gemma-4-E2B-it adapter merged > merge.log 2>&1 || exit 1
printf "FROM $HOME/kehi-train/merged\n" > merged/Modelfile
(cd merged && $O create klili-e2b-forms -q int4 -f Modelfile > ../create.log 2>&1) || exit 1
mkdir -p res
python3 run_twostage_v3.py klili-e2b-forms res/lora_short.jsonl eval_items.json 0 prompts_lora.json
python3 run_twostage_v3.py klili-e2b-forms res/lora_v3fs.jsonl eval_items.json 1
python3 $HOME/kehi-eval/run_eval.py klili-e2b-forms res/lora_qa.jsonl http://127.0.0.1:11434 jobs_qa.json
python3 run_twostage_v3.py klili-e2b-forms res/lora_dev.jsonl dev_items.json 0 prompts_lora.json
python3 run_twostage_v3.py gemma4:e2b-it-qat res/base_dev_v3fs.jsonl dev_items.json 1
python3 run_twostage_v3.py gemma4:e2b-it-qat res/base_dev_v3.jsonl dev_items.json 0
echo ALL_DONE >> train.log
