# Jetson AGX Thor Local LLM Stack

This is a starting point for a **local development PoC**, not a hardened production deployment.

## Components

- NVIDIA Jetson Thor-specific vLLM container
- RedHatAI Qwen3-8B W4A16 model
- LiteLLM API gateway
- Open WebUI
- OpenClaw
- Hermes Agent
- Optional Prometheus + cAdvisor + Grafana monitoring

## 0. Verify the host first

```bash
uname -m
cat /etc/nv_tegra_release
docker --version
docker compose version
sudo docker info
```

Use the NVIDIA JetPack/Jetson software stack provided for Thor. Do not replace CUDA or the vLLM image with an x86 image. NVIDIA's Jetson AI Lab specifically documents:
`ghcr.io/nvidia-ai-iot/vllm:latest-jetson-thor`

## 1. Prepare the model directory

The host path is `/home/llm_model`, mounted at the same path in the vLLM container.

```bash
sudo mkdir -p /home/llm_model
sudo chown -R "$USER":"$USER" /home/llm_model
./setup.sh
```

The setup script generates random secrets for all placeholders, adds newly introduced variables to an existing `.env`, and preserves already-generated values. Keep `LITELLM_SALT_KEY` stable: changing it later can make credentials stored in PostgreSQL unreadable.

Download the model using the Thor vLLM image so that the download environment matches the inference container:

```bash
docker compose run --rm --no-deps --entrypoint bash vllm -lc \
  'hf download RedHatAI/Qwen3-8B-quantized.w4a16 \
   --local-dir /home/llm_model/Qwen3-8B-quantized.w4a16'
```

If Hugging Face requires authentication, export `HF_TOKEN` and pass it to the one-off container, or authenticate inside the container. Do not commit the token.

Check that the directory contains `config.json`, tokenizer files, and model weight shards:

```bash
ls -lah /home/llm_model/Qwen3-8B-quantized.w4a16
```

The `.env` default `MODEL_DIR` points to this local directory. Do not use `MODEL_DIR` as a Hugging Face repo ID when using the local-directory configuration.

## 2. Start the stack

```bash
docker compose config
docker compose pull
docker compose up -d vllm
docker compose logs -f vllm
```

Wait until the model is loaded, then test it:

```bash
curl -s http://127.0.0.1:8000/v1/models \
  -H "Authorization: Bearer $(grep '^VLLM_API_KEY=' .env | cut -d= -f2-)"
```

Test chat completion:

```bash
VLLM_KEY="$(grep '^VLLM_API_KEY=' .env | cut -d= -f2-)"
curl http://127.0.0.1:8000/v1/chat/completions \
  -H "Authorization: Bearer ${VLLM_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3-8b",
    "messages": [{"role":"user","content":"Say hello in one sentence."}],
    "max_tokens": 80
  }'
```

Then start PostgreSQL, the API gateway, and the UI:

```bash
docker compose config
docker compose up -d postgres litellm open-webui
docker compose logs -f litellm
```

LiteLLM Admin UI login:
- URL: http://127.0.0.1:4000/ui
- Username: value of `UI_USERNAME` in `.env` (default `admin`)
- Password: value of `UI_PASSWORD` in `.env`

Other endpoints:
- Open WebUI: http://127.0.0.1:3000
- LiteLLM API: http://127.0.0.1:4000
- vLLM API: http://127.0.0.1:8000

PostgreSQL data persists in the Docker volume `litellm-db-data`. Do not run `docker compose down -v` unless you intend to delete the database and other named volumes. Ports are bound to localhost by default.

## 3. OpenClaw and Hermes

Start them after vLLM and LiteLLM are working:

```bash
docker compose up -d openclaw hermes
docker compose logs -f openclaw
docker compose logs -f hermes
```

- OpenClaw UI/gateway: http://127.0.0.1:18789
- Hermes gateway API: http://127.0.0.1:8642
- Hermes dashboard: http://127.0.0.1:9119

OpenClaw config and workspace are persisted under `./config/openclaw` and `./data/openclaw/workspace`. Hermes state is persisted under `./config/hermes`.

If an agent reports an unknown provider/model, first inspect logs and verify that the config schema matches the installed version. Agent projects evolve quickly; do not assume a config file from another release will remain valid.

## 4. Monitoring (optional)

```bash
docker compose --profile monitoring up -d
```

- Prometheus: http://127.0.0.1:9090
- cAdvisor: http://127.0.0.1:8088
- Grafana: http://127.0.0.1:3001

Prometheus scrapes vLLM `/metrics` and cAdvisor container metrics. This does **not** provide full Jetson GPU/temperature/power telemetry. For those, use host `tegrastats` (for example `sudo tegrastats --interval 1000`) or add a Jetson-specific exporter after verifying its compatibility.

## 5. Useful commands

```bash
docker compose ps
docker compose logs -f vllm
docker compose logs -f litellm
docker compose logs -f open-webui
docker compose logs -f openclaw
docker compose logs -f hermes
docker compose down
```

## Tuning notes

- Start with `--gpu-memory-utilization 0.75` and `--max-model-len 8192`; increase only after baseline stability.
- `qwen3_xml` is intended for Qwen3-style tool calls. If vLLM reports that this parser is unavailable in the bundled build, check the parser list supported by that exact vLLM image before changing it.
- Tool-call quality is model- and template-dependent. Benchmark real OpenClaw/Hermes tasks; a model responding in chat does not prove its tool calls are correct.
- The stack is configured for local experimentation. Do not expose ports publicly or give agents access to company credentials, production databases, or the Docker socket.
