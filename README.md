# space-on-kind
Run SPACE locally on a KinD cluster

[SPACE](https://github.com/perplexityai/SPACE) (Sandboxed Platform for Agentic Code Execution) runs code in isolated Firecracker microVMs behind an HTTP API.

This repo is for **macOS** users. SPACE needs an x86_64 Linux host with KVM, which a Mac can't provide, so you run SPACE on a Linux host and drive it from your Mac over ssh.

## Quick start

1. Read [SETUP.md](SETUP.md): what the Linux host needs, where to get one, and why the Mac can't be the host.
2. `scripts/install.sh --space-host <host>` installs the Mac tools, checks the host's prerequisites, then installs SPACE on the host and brings it up on KinD.
3. `scripts/tunnel.sh <host>` forwards SPACE's API, data plane, UI and Tilt UI to `127.0.0.1` on your Mac. `scripts/tunnel.sh <host> --status` checks that each one answers.
4. Look around: the UI at <http://127.0.0.1:3000> (`root@local` / `password`), the API at `http://127.0.0.1:8080`, and Tilt at <http://127.0.0.1:10350>. [SETUP.md](SETUP.md#4-look-around) walks through each with screenshots.

Every script is idempotent: rerun it any time.

## SPACE docs

Getting started:

- [Introduction](https://github.com/perplexityai/SPACE/blob/main/docs/introduction.md): templates, sandboxes, and how the pieces fit
- [Install and configure locally](https://github.com/perplexityai/SPACE/blob/main/docs/installation.md): prerequisites, KinD deployment, and authentication
- [Your first sandbox](https://github.com/perplexityai/SPACE/blob/main/docs/first-sandbox.md): create a sandbox, run a command, read its output, delete it
- [Troubleshooting](https://github.com/perplexityai/SPACE/blob/main/docs/troubleshooting.md)

Using the API:

- [Using the API](https://github.com/perplexityai/SPACE/blob/main/docs/using-api.md)
- [API reference](https://github.com/perplexityai/SPACE/blob/main/docs/api/index.md)
- [E2B Compatibility Wrapper](https://github.com/perplexityai/SPACE/blob/main/docs/ecw.md): point an existing E2B client at SPACE
- [Native template startup](https://github.com/perplexityai/SPACE/blob/main/docs/native-template-runtime.md)

Running SPACE:

- [Running SPACE](https://github.com/perplexityai/SPACE/blob/main/docs/running-space.md)
- [Configuration reference](https://github.com/perplexityai/SPACE/blob/main/docs/configuration.md)
- [Observability](https://github.com/perplexityai/SPACE/blob/main/docs/observability.md)
- [Warm pools](https://github.com/perplexityai/SPACE/blob/main/docs/warm-pools.md)
- [Base snapshots](https://github.com/perplexityai/SPACE/blob/main/docs/base-snapshots.md)

Under the hood:

- [Architecture](https://github.com/perplexityai/SPACE/blob/main/docs/architecture.md)
- [DeepWiki: perplexityai/SPACE](https://deepwiki.com/perplexityai/SPACE): AI-generated walkthrough of the codebase (control plane, node plane, guest runtime, and more)
