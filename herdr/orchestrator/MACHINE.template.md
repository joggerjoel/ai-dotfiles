# Machine Context Template

Use this template to create a localized `MACHINE.md` on each machine in your fleet.
This file provides context to agents running on this machine so they don't stop to ask environmental, path, or convention questions.

---

## 1. Machine Identification
- **Machine Name / Hostname**: `[e.g., macbook-pro-m3, mac-studio-build-01, linux-gpu-node]`
- **Role in Fleet**: `[e.g., Frontend & Local Testing, Heavy Compiles & Docker, CUDA / Model Inference]`
- **Operating System**: `[e.g., macOS Sonoma (Apple Silicon), Ubuntu 24.04 LTS]`
- **Primary Shell**: `[e.g., /bin/zsh, /bin/bash]`

## 2. Local Runtimes & Toolchains
- **Node.js**: `[e.g., v22.x via nvm / fnm / brew]`
- **Package Manager**: `[e.g., bun (preferred), pnpm, npm]`
- **Python**: `[e.g., 3.11.x via pyenv / uv]`
- **Rust / Go / Java**: `[e.g., rustc 1.80, go 1.23]`
- **Container Engine**: `[e.g., Docker Desktop, OrbStack, Podman, None]`

## 3. Local Infrastructure & Services
- **Databases**: `[e.g., PostgreSQL running locally on port 5432, Redis on 6379, or SQLite only]`
- **Cloud / API Credentials**: `[e.g., Loaded via ~/.env or 1Password CLI; do not ask user for keys]`
- **Tailscale IP / Hostname**: `[e.g., 100.x.y.z / my-mac.tailnet-xyz.ts.net]`

## 4. Path & Workspace Standards
- **Primary Workspace Root**: `[e.g., ~/projects or ~/code]`
- **Scratch / Temp Directory**: `[e.g., /tmp or ~/scratch]`

## 5. Autonomy Directives (Rules for the Agent)
1. **Never ask permission for standard dev actions**: You are pre-approved to install npm/pip dependencies, run builds, execute tests, create files, and format code.
2. **Never ask "Should I proceed to the next task?"**: Always proceed automatically until all items in `TODO.md` are marked complete.
3. **Preferred Package Manager**: Always use the preferred package manager specified above. Do not switch between `npm` and `yarn` arbitrarily.
4. **Test Before Done**: Never declare a task complete (`- [x]`) without running the relevant test suite and confirming exit code 0.
5. **Handling Ambiguity**: If two implementations are equally valid, choose the one that matches existing project patterns rather than pausing for human input.
