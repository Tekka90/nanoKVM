# ANSSI declaration documents (French)

Four PDFs for the French encryption declaration of the SSH-enabled version of the app (Citadel, since removed from the shipped app): commercial brochure, technical datasheet, user manual, administrator guide.

```
/opt/homebrew/bin/python3.14 -m venv build/venv-docs && build/venv-docs/bin/pip install reportlab
build/venv-docs/bin/python docs/anssi/generate.py
```

Publisher details, version, price and date are set at the top of `generate.py`; edit and regenerate when they change. The algorithm list comes from the Citadel / swift-nio-ssh source, not from a captured handshake; check it against the version you actually ship.
