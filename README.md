# Vatio CLI

CLI para desplegar y administrar workspaces de [Vatio](https://vatio.ai), la
plataforma de agentes de IA.

Solo depende de la librería estándar de Ruby (>= 2.6) — sin gems, sin Bundler.
Corre con el Ruby que ya tengas instalado (incluido el Ruby de sistema de
macOS).

## Instalación

```bash
curl -fsSL https://raw.githubusercontent.com/urcalab/vatio-cli/main/install.sh | bash
```

Descarga el último release, lo instala en `~/.vatio-cli/` y enlaza
`vatio` en `~/.local/bin/`. No requiere `git`, `gem` ni `brew` — solo
`curl`, `tar`, y Ruby >= 2.6 en el `PATH`.

Para fijar una versión específica: `VATIO_CLI_VERSION=v0.2.0 curl ... | bash`.

### Manual (clonar el repo)

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

## Licencia

Software propietario de Urcalab, distribuido solo para instalar y usar
el Vatio CLI contra la plataforma [vatio.ai](https://vatio.ai). Ver
[`LICENSE.txt`](LICENSE.txt).
