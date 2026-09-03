# Vatio CLI

[Vatio](https://vatio.ai) is a platform for building and running AI agents.
This CLI deploys and manages Vatio workspaces from your terminal.

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/urcalab/vatio-cli/main/install.sh | bash
```

Installs `vatio` into `~/.local/bin/`. Requires only `curl`, `tar`, and
Ruby >= 2.6 on your `PATH`.

## Usage

```bash
vatio init                    # creates .vatio/config.json + device code login
vatio new workspace my-client
cd my-client
vatio push                    # uploads preview
vatio publish                 # promotes to live
```

Run `vatio help` for the full list of commands, or see
[vatio.ai/docs](https://vatio.ai/docs).

## License

Proprietary software of Urcalab, distributed solely to install and use
the Vatio CLI against [vatio.ai](https://vatio.ai). See
[`LICENSE.txt`](LICENSE.txt).
