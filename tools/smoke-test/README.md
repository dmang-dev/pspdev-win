# Smoke-test fixture

The minimal PSP program from the top of the repo
[README](../../README.md#5-compile-hello-world), kept here byte-for-byte as a
CI fixture.

The **Build release bundles** workflow extracts the freshly-built toolchain zip
into a clean directory and runs `make` against these two files. If `EBOOT.PBP`
comes out, the bundle ships; if anything is missing (a host tool, a runtime
DLL, or one of `pspdebug`/`pspdisplay`/`pspge`/`pspctrl`), the run fails
*before* publishing. It proves the artifact is usable, not merely that the
build finished.

To run it yourself against an installed toolchain:

```bash
export PSPDEV=/path/to/pspdev          # the dir you extracted the bundle into
export PATH="$PSPDEV/bin:$PATH"
make                                    # produces EBOOT.PBP
```
