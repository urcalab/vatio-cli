# Vatio CLI

CLI to deploy and manage [Vatio](https://vatio.ai) workspaces, the AI agent
platform.

Depends only on Ruby's standard library (>= 2.6) — no gems, no Bundler.
Runs with whatever Ruby you already have installed (including macOS's
system Ruby).

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/urcalab/vatio-cli/main/install.sh | bash
```

Downloads the latest release, installs it into `~/.vatio-cli/`, and links
`vatio` into `~/.local/bin/`. Requires no `git`, `gem`, or `brew` — just
`curl`, `tar`, and Ruby >= 2.6 on your `PATH`.

To pin a specific version: `VATIO_CLI_VERSION=v0.2.0 curl ... | bash`.

### Manual (clone the repo)

```bash
git clone https://github.com/urcalab/vatio-cli.git
cd vatio-cli
./bin/vatio version
```

Add `bin/` to your `PATH`, or symlink `bin/vatio` into a directory already
on your `PATH`.

## Usage

```bash
vatio init                    # creates .vatio/config.json + device code login
vatio new workspace my-client
cd my-client
vatio push                    # uploads preview
vatio publish                 # promotes to live
```

Run `vatio help` for the full list of commands.

## Documentation

[vatio.ai/docs](https://vatio.ai/docs)

## License

Proprietary software of Urcalab, distributed solely to install and use
the Vatio CLI against the [vatio.ai](https://vatio.ai) platform. See
[`LICENSE.txt`](LICENSE.txt).
