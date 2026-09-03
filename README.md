# Vatio CLI

CLI para desplegar y administrar workspaces de [Vatio](https://vatio.ai), la
plataforma de agentes de IA.

Solo depende de la librería estándar de Ruby (>= 3.2) — sin gems, sin Bundler.

## Instalación

### Homebrew (macOS/Linux)

```bash
brew install urcalab/vatio/vatio
```

### Manual

```bash
git clone https://github.com/urcalab/vatio-cli.git
cd vatio-cli
./bin/vatio version
```

Agrega `bin/` al `PATH`, o enlaza `bin/vatio` a algún directorio ya en tu `PATH`.

## Uso

```bash
vatio init                    # crea .vatio/config.json + login por device code
vatio new workspace my-client
cd my-client
vatio push                    # sube preview
vatio publish                 # promueve a live
```

Corre `vatio help` para el listado completo de comandos.

## Documentación

[vatio.ai/docs](https://vatio.ai/docs)

## Desarrollo

Este repo es un espejo publicado de `tools/vatio/` en el monolito
`urcalab/vatio` (privado). Los cambios se desarrollan ahí y se sincronizan
aquí en cada release.

```bash
ruby tools/vatio/test/cli_dx_test.rb
```
